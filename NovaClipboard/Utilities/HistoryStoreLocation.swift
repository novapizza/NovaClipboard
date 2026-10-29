import Foundation
import os

private let locationLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "HistoryStoreLocation")

/// Where the SwiftData history database lives.
///
/// The app isn't sandboxed, so SwiftData's default `ModelConfiguration` resolves to the
/// shared `~/Library/Application Support/default.store` — the same file every other
/// unsandboxed SwiftData app with a default configuration uses. The history now lives in
/// the app's own folder next to `ImageStore`'s images.
enum HistoryStoreLocation {
    /// SQLite keeps its write-ahead log and shared memory beside the main file.
    private static let sidecarSuffixes = ["", "-wal", "-shm"]

    static var url: URL {
        let dir = applicationSupportDirectory.appendingPathComponent("NovaClipboard", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("History.store")
    }

    static var legacyURL: URL {
        applicationSupportDirectory.appendingPathComponent("default.store")
    }

    private static var applicationSupportDirectory: URL {
        let fm = FileManager.default
        return (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    /// Copies the shared `default.store` into the app's own folder on the first launch after
    /// the move. Copies rather than moves: another app may own that file too.
    /// - Returns: true when a legacy store was copied.
    @discardableResult
    static func migrateLegacyStoreIfNeeded() -> Bool {
        let fm = FileManager.default
        let target = url
        guard !fm.fileExists(atPath: target.path),
              fm.fileExists(atPath: legacyURL.path) else { return false }

        do {
            for suffix in sidecarSuffixes {
                let source = URL(fileURLWithPath: legacyURL.path + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(at: source, to: URL(fileURLWithPath: target.path + suffix))
            }
            locationLogger.info("Copied legacy history store to \(target.path, privacy: .public)")
            return true
        } catch {
            locationLogger.error("Could not copy legacy history store: \(String(describing: error), privacy: .public)")
            removeStore()
            return false
        }
    }

    /// Deletes the store at `url` with its sidecar files.
    static func removeStore() {
        for suffix in sidecarSuffixes {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
