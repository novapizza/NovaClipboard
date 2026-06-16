import AppKit
import SwiftData
import SwiftUI
import os

private let panelLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "PanelController")

@MainActor
final class PanelController {
    static let panelSize = CGSize(width: 380, height: 480)

    private let modelContainer: ModelContainer
    private let historyStore: HistoryStore
    private let anchorResolver: PanelAnchorResolver
    private let settings: AppSettings
    private let onPaste: (ClipboardItem) -> Void
    private var panel: NSPanel?
    private var capturedApp: NSRunningApplication?

    init(
        modelContainer: ModelContainer,
        historyStore: HistoryStore,
        anchorResolver: PanelAnchorResolver,
        settings: AppSettings,
        onPaste: @escaping (ClipboardItem) -> Void
    ) {
        self.modelContainer = modelContainer
        self.historyStore = historyStore
        self.anchorResolver = anchorResolver
        self.settings = settings
        self.onPaste = onPaste
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    var frontmostAppBeforeShow: NSRunningApplication? { capturedApp }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        capturedApp = NSWorkspace.shared.frontmostApplication

        let panel = panel ?? makePanel()
        self.panel = panel

        anchorResolver.fixedOrigin = settings.fixedPanelOrigin
        let anchor = anchorResolver.resolve(preference: settings.panelPosition)
        let screen = currentScreen(for: anchor)
        let origin = anchor.panelOrigin(panelSize: PanelController.panelSize, screen: screen)
        panel.setFrameOrigin(origin)

        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func currentScreen(for anchor: PanelAnchor) -> NSScreen? {
        let point: CGPoint
        switch anchor {
        case .caret(let r), .focusedElement(let r):
            point = CGPoint(x: r.midX, y: r.midY)
        case .mouse(let p), .fixed(let p):
            point = p
        }
        return NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    private func makePanel() -> NSPanel {
        let contentView = HistoryPanelView(
            store: historyStore,
            onPaste: { [weak self] item in
                guard let self else { return }
                panelLogger.info("PanelController.onPaste from row click/enter")
                self.hide()
                self.onPaste(item)
            },
            onDismiss: { [weak self] in self?.hide() }
        )
        .modelContainer(modelContainer)

        let hosting = NSHostingController(rootView: contentView)
        hosting.view.frame = NSRect(origin: .zero, size: PanelController.panelSize)

        let panel = HistoryPanel(
            contentRect: NSRect(origin: .zero, size: PanelController.panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Key-window behavior is governed by `HistoryPanel.canBecomeKey` below;
        // setting `becomesKeyOnlyIfNeeded` here conflicts with `.nonactivatingPanel`.
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 10
        panel.contentView?.layer?.masksToBounds = true

        panel.onResignKey = { [weak self] in
            // Skip hide while a modal sheet (e.g. confirmationDialog) owns focus,
            // otherwise the dialog loses its parent and the UI breaks.
            if NSApp.modalWindow != nil { return }
            self?.hide()
        }
        return panel
    }
}

private final class HistoryPanel: NSPanel {
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
