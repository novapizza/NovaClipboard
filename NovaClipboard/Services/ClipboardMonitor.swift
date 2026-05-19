import AppKit
import Foundation
import os

private let monitorLogger = Logger(subsystem: "io.creativeforce.NovaClipboard", category: "ClipboardMonitor")

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
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Priority: file URL > image > text/link
        if let fileItem = readFileURLs(bundleID: bundleID) {
            onNewItem?(fileItem)
            return
        }
        if let imageItem = readImage(bundleID: bundleID) {
            onNewItem?(imageItem)
            return
        }
        if let textItem = readText(bundleID: bundleID) {
            onNewItem?(textItem)
            return
        }
    }

    private func readFileURLs(bundleID: String?) -> ClipboardItem? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        var urls: [String] = []
        for item in items {
            if let str = item.string(forType: .fileURL),
               let url = URL(string: str), url.isFileURL {
                urls.append(url.absoluteString)
            }
        }
        guard !urls.isEmpty else { return nil }
        return ClipboardItem.file(urls: urls, sourceBundleID: bundleID)
    }

    private func readImage(bundleID: String?) -> ClipboardItem? {
        let pngType = NSPasteboard.PasteboardType("public.png")
        let tiffType = NSPasteboard.PasteboardType("public.tiff")

        var data: Data?
        if let png = pasteboard.data(forType: pngType) {
            data = png
        } else if let tiff = pasteboard.data(forType: tiffType) {
            // Convert TIFF → PNG for consistent storage
            if let rep = NSBitmapImageRep(data: tiff) {
                data = rep.representation(using: .png, properties: [:])
            }
        }

        guard let data else { return nil }
        let id = UUID()
        let inline = data.count < ImageStore.inlineLimitBytes
        let path = inline ? nil : ImageStore.write(data: data, id: id)

        let sizeKB = Double(data.count) / 1024.0
        let preview = sizeKB < 1024
            ? String(format: "Image · %.0f KB", sizeKB)
            : String(format: "Image · %.1f MB", sizeKB / 1024.0)

        return ClipboardItem(
            id: id,
            type: .image,
            preview: preview,
            imageBlob: inline ? data : nil,
            imagePath: path,
            sourceBundleID: bundleID,
            checksum: Checksum.sha256(data)
        )
    }

    private func readText(bundleID: String?) -> ClipboardItem? {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        if Self.isLikelyURL(text) {
            return ClipboardItem.link(text, sourceBundleID: bundleID)
        }
        return ClipboardItem.text(text, sourceBundleID: bundleID)
    }

    private static func isLikelyURL(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 4096, !trimmed.contains(" ") else { return false }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp", "mailto"].contains(scheme) {
            return true
        }
        return false
    }
}
