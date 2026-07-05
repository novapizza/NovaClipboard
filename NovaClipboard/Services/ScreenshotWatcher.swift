import AppKit
import CoreServices
import Foundation
import os

private let screenshotLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "ScreenshotWatcher")

/// Watches the user's configured screenshot directory (default `~/Desktop`) via FSEvents
/// and reports new screenshot files. Clipboard-only screenshots (⌃⌘⇧3/4) are already
/// covered by `ClipboardMonitor`.
final class ScreenshotWatcher {
    /// Soft cap on the dedup set. The watcher rarely stops on long-lived menu-bar sessions, so
    /// without a cap this set would grow forever. When we hit the cap we drop the entire set —
    /// the only consequence is that re-detecting an *existing* screenshot file becomes
    /// possible again, which is vanishingly unlikely (FSEvents fires per-create, not per-poll).
    private static let maxSeenPaths = 1000

    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private var startTime: Date = .distantFuture
    private var seenPaths: Set<String> = []

    /// Fires on the main thread with the screenshot file URL.
    var onScreenshot: ((URL) -> Void)?

    func start() {
        stop()
        let path = Self.screenshotDirectory()
        guard FileManager.default.fileExists(atPath: path) else {
            screenshotLogger.error("Screenshot directory does not exist: \(path, privacy: .public)")
            return
        }

        let pathsToWatch = [path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<ScreenshotWatcher>.fromOpaque(info).takeUnretainedValue()
            // `kFSEventStreamCreateFlagUseCFTypes` makes `eventPaths` a CFArrayRef; bridge it
            // safely through Unmanaged instead of `unsafeBitCast`.
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let paths = (cfPaths as NSArray).compactMap { $0 as? String }
            for i in 0..<numEvents where i < paths.count {
                let flagsVal = eventFlags[i]
                let isCreate = (flagsVal & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
                let isRenamed = (flagsVal & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
                let isModified = (flagsVal & UInt32(kFSEventStreamEventFlagItemModified)) != 0
                guard isCreate || isRenamed || isModified else { continue }
                watcher.consider(path: paths[i])
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else {
            screenshotLogger.error("Failed to create FSEventStream for \(path, privacy: .public)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)

        self.stream = stream
        self.watchedPath = path
        self.startTime = Date()
        screenshotLogger.info("ScreenshotWatcher started on \(path, privacy: .public)")
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        seenPaths.removeAll()
        watchedPath = nil
    }

    private func consider(path: String) {
        guard !seenPaths.contains(path) else { return }
        let ext = (path as NSString).pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic", "heif", "tiff", "pdf"].contains(ext) else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }

        if let created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date,
           created < startTime.addingTimeInterval(-2) {
            recordSeen(path)
            return
        }

        guard isScreenshot(path: path) else { return }
        recordSeen(path)
        screenshotLogger.info("Detected screenshot: \(path, privacy: .public)")
        deliverWhenReadable(url: URL(fileURLWithPath: path), attempt: 0)
    }

    private func recordSeen(_ path: String) {
        if seenPaths.count >= ScreenshotWatcher.maxSeenPaths {
            seenPaths.removeAll(keepingCapacity: true)
        }
        seenPaths.insert(path)
    }

    private func isScreenshot(path: String) -> Bool {
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
           let raw = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) {
            if let n = raw as? NSNumber, n.boolValue {
                return true
            }
        }
        // Spotlight may not have indexed the new file yet — fall back to filename heuristic.
        let name = ((path as NSString).lastPathComponent).lowercased()
        // macOS default localized filenames begin with "screenshot" or older "screen shot".
        return name.hasPrefix("screenshot") || name.hasPrefix("screen shot")
    }

    /// FSEvents fires on `IT_CREATED` immediately; the file may still be growing.
    /// Poll briefly until the file is non-empty before handing off.
    private func deliverWhenReadable(url: URL, attempt: Int) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        if size > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.onScreenshot?(url)
            }
            return
        }
        if attempt >= 15 {
            screenshotLogger.error("Screenshot file never became readable: \(url.path, privacy: .public)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.deliverWhenReadable(url: url, attempt: attempt + 1)
        }
    }

    /// Resolve the screenshot save directory from `com.apple.screencapture` defaults,
    /// falling back to `~/Desktop`.
    static func screenshotDirectory() -> String {
        let fm = FileManager.default
        if let raw = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let expanded = (raw as NSString).expandingTildeInPath
            if fm.fileExists(atPath: expanded) {
                return expanded
            }
        }
        let desktops = fm.urls(for: .desktopDirectory, in: .userDomainMask)
        if let desktop = desktops.first {
            return desktop.path
        }
        return (NSString("~/Desktop").expandingTildeInPath as String)
    }
}
