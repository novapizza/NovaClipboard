import AppKit
import Foundation

final class ClipboardMonitor {
    private let pasteboard: NSPasteboard
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int

    var onNewItem: ((ClipboardItem) -> Void)?

    init(pasteboard: NSPasteboard = .general, pollInterval: TimeInterval = 0.3) {
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func pollNow() {
        poll()
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        handleChange()
    }

    private func handleChange() {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            return
        }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let item = ClipboardItem.text(text, sourceBundleID: bundleID)
        onNewItem?(item)
    }
}
