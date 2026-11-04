import AppKit
import QuickLookUI
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
    /// Bumped on every show so the long-lived view can reset per-show state.
    @Published var showCount: Int = 0
    /// The app the panel will paste into, for previewing app-specific paste transforms.
    @Published var targetBundleID: String?
}

@MainActor
final class PanelController {
    static let panelSize = CGSize(width: 380, height: 480)
    static let cornerRadius: CGFloat = 10

    /// A status-item click lands after the panel already hid itself on resign-key;
    /// clicks within this window of a hide are treated as "close", not "reopen".
    private static let reopenSuppressInterval: TimeInterval = 0.3

    private let modelContainer: ModelContainer
    private let historyStore: HistoryStore
    private let anchorResolver: PanelAnchorResolver
    private let settings: AppSettings
    private let onPaste: ([ClipboardItem], Bool) -> Void
    private let onOpenSettings: () -> Void
    private let onOpenAccessibility: () -> Void
    private var panel: NSPanel?
    /// Retained here when the hosting view is embedded in an `NSGlassEffectView`
    /// instead of being the panel's `contentViewController`.
    private var hostingController: NSViewController?
    private var capturedApp: NSRunningApplication?
    private var lastHiddenAt: Date = .distantPast
    private let previewController = ItemPreviewController()
    private let hoverPreview = HoverPreviewController()
    private let transformPreview = PasteTransformPreview()

    let presentation = PanelPresentation()

    init(
        modelContainer: ModelContainer,
        historyStore: HistoryStore,
        anchorResolver: PanelAnchorResolver,
        settings: AppSettings,
        onOpenSettings: @escaping () -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onPaste: @escaping ([ClipboardItem], Bool) -> Void
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
        presentation.showCount += 1
        presentation.targetBundleID = capturedApp?.bundleIdentifier

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
        // A borderless, transparent window's shadow is traced from its pixels when it
        // first draws; if that happens before the glass renders, the shadow keeps a
        // square outline around the rounded corners. Re-trace once content is up.
        DispatchQueue.main.async { [weak panel] in panel?.invalidateShadow() }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        hoverPreview.hide()
        previewController.close()
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
            onPaste: { [weak self] items, original in
                guard let self else { return }
                panelLogger.info("PanelController.onPaste from row click/enter, count=\(items.count, privacy: .public), original=\(original, privacy: .public)")
                self.hide()
                self.onPaste(items, original)
            },
            // Esc closes an open Quick Look first, like Finder.
            onDismiss: { [weak self] in
                guard let self else { return }
                if self.previewController.isVisible {
                    self.previewController.close()
                } else {
                    self.hide()
                }
            },
            onTogglePreview: { [weak self] item in
                self?.hoverPreview.hide()
                self?.previewController.toggle(item: item)
            },
            onSelectionChanged: { [weak self] item in self?.previewController.selectionChanged(to: item) },
            onHoverChanged: { [weak self] item in self?.hoverPreview.hoverChanged(to: item) },
            presentation: presentation,
            transformPreview: transformPreview,
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
        panel.previewController = previewController
        previewController.hostWindow = panel
        hoverPreview.hostWindow = panel
        hoverPreview.isSuppressed = { [weak self] in self?.previewController.isVisible ?? false }
        hoverPreview.transformResult = { [weak self] item in
            guard let self else { return nil }
            return self.transformPreview.result(
                for: item, rules: self.settings.pasteTransforms, targetBundleID: self.presentation.targetBundleID
            )
        }
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
        if #available(macOS 26.0, *) {
            // System glass behind the whole panel, so it follows the user's Liquid Glass
            // appearance (transparency/tint) like menus and popovers do.
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: PanelController.panelSize))
            glass.cornerRadius = PanelController.cornerRadius
            glass.wantsLayer = true
            glass.layer?.cornerRadius = PanelController.cornerRadius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            glass.contentView = hosting.view
            panel.contentView = glass
            hostingController = hosting
        } else {
            panel.contentViewController = hosting
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.cornerRadius = PanelController.cornerRadius
            panel.contentView?.layer?.masksToBounds = true
        }

        panel.onResignKey = { [weak self] in
            // Skip hide while a dialog owns focus, otherwise the dialog loses its
            // parent and the UI breaks. confirmationDialog is a window-attached sheet
            // (never sets NSApp.modalWindow), so check attachedSheet as well.
            if NSApp.modalWindow != nil || self?.panel?.attachedSheet != nil { return }
            guard self?.previewController.isVisible == true else {
                self?.hide()
                return
            }
            // With Quick Look open, key may only be moving to the preview (opening it, or a
            // click on its full-screen button); `ItemPreviewController` hands it back. The new
            // key window is known once this resign finishes, so decide then.
            DispatchQueue.main.async {
                guard let self, let panel = self.panel, panel.isVisible, !panel.isKeyWindow,
                      !self.previewController.isHoldingKeyTemporarily else { return }
                self.hide()
            }
        }
        return panel
    }

}

private final class HistoryPanel: NSPanel {
    var onResignKey: (() -> Void)?
    weak var previewController: ItemPreviewController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    // MARK: Quick Look panel control (responder-chain protocol)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        previewController != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        previewController?.beginControl(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        previewController?.endControl(panel)
    }
}
