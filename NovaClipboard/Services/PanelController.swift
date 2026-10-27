import AppKit
import SwiftData
import SwiftUI
import os

private let panelLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "PanelController")

/// Where a panel show request came from. Opening from the menu-bar icon anchors the
/// panel under the icon and adds a Settings button to the header.
enum PanelSource {
    case hotKey
    case statusItem(CGRect)
}

/// Observable state the long-lived `HistoryPanelView` reads; the view is built once in
/// `makePanel()`, so per-show changes have to flow through here.
@MainActor
final class PanelPresentation: ObservableObject {
    @Published var openedFromStatusItem: Bool = false
    /// Drives the "Accessibility permission required" banner. Refreshed on every show and
    /// by AppDelegate's 3 s permission poll.
    @Published var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
}

@MainActor
final class PanelController {
    static let panelSize = CGSize(width: 380, height: 480)

    /// A status-item click lands after the panel already hid itself on resign-key;
    /// clicks within this window of a hide are treated as "close", not "reopen".
    private static let reopenSuppressInterval: TimeInterval = 0.3

    private let modelContainer: ModelContainer
    private let historyStore: HistoryStore
    private let anchorResolver: PanelAnchorResolver
    private let settings: AppSettings
    private let onPaste: (ClipboardItem) -> Void
    private let onOpenSettings: () -> Void
    private let onOpenAccessibility: () -> Void
    private var panel: NSPanel?
    private var capturedApp: NSRunningApplication?
    private var lastHiddenAt: Date = .distantPast

    let presentation = PanelPresentation()

    init(
        modelContainer: ModelContainer,
        historyStore: HistoryStore,
        anchorResolver: PanelAnchorResolver,
        settings: AppSettings,
        onOpenSettings: @escaping () -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onPaste: @escaping (ClipboardItem) -> Void
    ) {
        self.modelContainer = modelContainer
        self.historyStore = historyStore
        self.anchorResolver = anchorResolver
        self.settings = settings
        self.onOpenSettings = onOpenSettings
        self.onOpenAccessibility = onOpenAccessibility
        self.onPaste = onPaste
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    var frontmostAppBeforeShow: NSRunningApplication? { capturedApp }

    func toggle(source: PanelSource = .hotKey) {
        if isVisible {
            hide()
            return
        }
        if case .statusItem = source,
           Date().timeIntervalSince(lastHiddenAt) < PanelController.reopenSuppressInterval {
            return
        }
        show(source: source)
    }

    func show(source: PanelSource = .hotKey) {
        capturedApp = NSWorkspace.shared.frontmostApplication

        let panel = panel ?? makePanel()
        self.panel = panel

        presentation.isAccessibilityTrusted = AXIsProcessTrusted()

        let anchor: PanelAnchor
        switch source {
        case .hotKey:
            anchorResolver.fixedOrigin = settings.fixedPanelOrigin
            anchor = anchorResolver.resolve(preference: settings.panelPosition)
            presentation.openedFromStatusItem = false
        case .statusItem(let rect):
            anchor = .statusItem(rect)
            presentation.openedFromStatusItem = true
        }

        let screen = currentScreen(for: anchor)
        let origin = anchor.panelOrigin(panelSize: PanelController.panelSize, screen: screen)
        panel.setFrameOrigin(origin)

        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        lastHiddenAt = Date()
    }

    private func currentScreen(for anchor: PanelAnchor) -> NSScreen? {
        let point: CGPoint
        switch anchor {
        case .caret(let r), .focusedElement(let r):
            point = CGPoint(x: r.midX, y: r.midY)
        case .mouse(let p), .fixed(let p):
            point = p
        case .statusItem(let r):
            point = CGPoint(x: r.midX, y: r.midY)
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
            onDismiss: { [weak self] in self?.hide() },
            presentation: presentation,
            // Settings activates the app; leave the `.floating` panel first so it
            // doesn't sit on top of the settings window.
            onOpenSettings: { [weak self] in
                self?.hide()
                self?.onOpenSettings()
            },
            onOpenAccessibility: { [weak self] in
                self?.hide()
                self?.onOpenAccessibility()
            }
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
            // Skip hide while a dialog owns focus, otherwise the dialog loses its
            // parent and the UI breaks. confirmationDialog is a window-attached sheet
            // (never sets NSApp.modalWindow), so check attachedSheet as well.
            if NSApp.modalWindow != nil || self?.panel?.attachedSheet != nil { return }
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
