import AppKit
import QuickLookUI
import os

private let previewLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "ItemPreviewController")

/// Space-bar Quick Look for history rows, like selecting a file in Finder and pressing Space.
/// Images and videos get the native viewer (with its full-screen button), text and links are
/// written to a temporary `.txt` so the whole content is readable, and other files (zip, …)
/// show Quick Look's icon card with the full file name.
///
/// `HistoryPanel` takes panel control through the responder chain and hands it this object
/// as data source; the history panel stays key so ↑↓ keep moving the selection.
///
/// The history panel is a non-activating panel, so NovaClipboard is never the active app and
/// only that panel can take keystrokes while another app is frontmost. Quick Look's panel
/// can't: whenever it becomes key (on open, or when clicked), keyboard input falls through to
/// the frontmost app and Space types into the user's document instead of closing the preview.
/// So key focus is handed straight back to `hostWindow` — after the mouse is released, so a
/// click on Quick Look's own controls (full screen, …) still completes.
@MainActor
final class ItemPreviewController: NSObject {
    private var previewItems: [PreviewItem] = []
    private var currentItemID: UUID?
    private var keyReturnTimer: Timer?

    /// The history panel, which keeps key focus while the preview is open.
    weak var hostWindow: NSWindow?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(previewWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
    }

    private static var tempDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaClipboard-Preview", isDirectory: true)
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func toggle(item: ClipboardItem) {
        if isVisible {
            close()
            return
        }
        load(item)
        guard !previewItems.isEmpty else { return }
        let panel = QLPreviewPanel.shared()!
        // `orderFront` rather than `makeKeyAndOrderFront`: the history panel keeps key focus,
        // so arrow keys still drive its selection and resign-key doesn't dismiss it.
        panel.orderFront(nil)
        panel.reloadData()
    }

    /// Follows keyboard selection changes while the preview is open.
    func selectionChanged(to item: ClipboardItem?) {
        guard isVisible, let item, item.id != currentItemID else { return }
        load(item)
        guard !previewItems.isEmpty else { close(); return }
        QLPreviewPanel.shared().reloadData()
    }

    func close() {
        cancelKeyReturn()
        if isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        previewItems = []
        currentItemID = nil
        try? FileManager.default.removeItem(at: Self.tempDirectory)
    }

    /// True when Quick Look holds key focus the history panel will take back once the mouse
    /// is released, i.e. focus hasn't actually left NovaClipboard.
    var isHoldingKeyTemporarily: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isKeyWindow
    }

    // MARK: - Key focus

    @objc private func previewWindowDidBecomeKey(_ note: Notification) {
        guard note.object is QLPreviewPanel, isVisible else { return }
        previewLogger.debug("Quick Look became key; returning key focus to the history panel")
        returnKeyToHost()
    }

    private func returnKeyToHost() {
        cancelKeyReturn()
        // Taking key mid-click would cut off the click on Quick Look's controls; wait for the
        // release. Polled because a control's tracking loop swallows the mouse-up event.
        guard NSEvent.pressedMouseButtons == 0 else {
            keyReturnTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard NSEvent.pressedMouseButtons == 0 else { return }
                    self?.returnKeyToHost()
                }
            }
            return
        }
        guard isVisible, let host = hostWindow, host.isVisible else { return }
        host.makeKey()
    }

    private func cancelKeyReturn() {
        keyReturnTimer?.invalidate()
        keyReturnTimer = nil
    }

    // MARK: - Panel control (called by `HistoryPanel`)

    func beginControl(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        // Sit above the `.floating` history panel.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    }

    func endControl(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: - Items

    private func load(_ item: ClipboardItem) {
        currentItemID = item.id
        previewItems = makePreviewItems(for: item)
    }

    private func makePreviewItems(for item: ClipboardItem) -> [PreviewItem] {
        switch item.type {
        case .image:
            if let imagePath = item.imagePath {
                return [PreviewItem(url: URL(fileURLWithPath: imagePath), title: item.preview)]
            }
            guard let blob = item.imageBlob,
                  let url = writeTemp(blob, name: "\(item.id.uuidString).png") else { return [] }
            return [PreviewItem(url: url, title: item.preview)]

        case .file:
            return (item.fileURLs ?? [])
                .compactMap { URL(string: $0) }
                .map { PreviewItem(url: $0, title: nil) }

        case .text, .richText, .link:
            let text = item.contentText ?? item.preview
            // A UTF-8 BOM keeps Quick Look from guessing a legacy encoding for non-ASCII text.
            let data = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
            guard let url = writeTemp(data, name: "\(item.id.uuidString).txt") else { return [] }
            let title = item.type == .link ? String(localized: "Link") : String(localized: "Text")
            return [PreviewItem(url: url, title: title)]
        }
    }

    private func writeTemp(_ data: Data, name: String) -> URL? {
        let dir = Self.tempDirectory
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            previewLogger.error("Failed to write preview file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

extension ItemPreviewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewItems.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewItems[index] }
    }

    /// Should Quick Look still receive a key press (focus not yet returned), hand it to the
    /// history panel so Space, Esc and ↑↓ behave the same as when that panel is key.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        return MainActor.assumeIsolated {
            guard let host = hostWindow, host.isVisible else { return false }
            host.makeKey()
            host.sendEvent(event)
            return true
        }
    }
}

private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL!
    let previewItemTitle: String!

    init(url: URL, title: String?) {
        self.previewItemURL = url
        self.previewItemTitle = title
    }
}
