import Foundation
import SQLite3
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

    /// Tables a store holding only `ClipboardItem` may contain: the entity table, Core Data's
    /// bookkeeping, and SwiftData's persistent-history tables.
    private static let ownTables: Set<String> = [
        "ZCLIPBOARDITEM", "Z_PRIMARYKEY", "Z_METADATA", "Z_MODELCACHE",
        "ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"
    ]
    /// Entity names in `Z_PRIMARYKEY`: ours plus the persistent-history entities.
    private static let ownEntities: Set<String> = ["ClipboardItem", "CHANGE", "TRANSACTION", "TRANSACTIONSTRING"]

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

    /// Core Data keeps `@Attribute(.externalStorage)` blobs in `.<store name>_SUPPORT` beside
    /// the store; rows reference them by file name, so the folder must travel with the store.
    private static func supportDirectory(for store: URL) -> URL {
        let name = store.deletingPathExtension().lastPathComponent
        return store.deletingLastPathComponent().appendingPathComponent(".\(name)_SUPPORT", isDirectory: true)
    }

    // MARK: - Migration

    /// Copies the shared `default.store` into the app's own folder on the first launch after
    /// the move. Copies rather than moves; `retireLegacyStoreIfSafe` removes the original
    /// only after the copy has been verified.
    /// - Returns: true when a legacy store was copied.
    @discardableResult
    static func migrateLegacyStoreIfNeeded(from legacyURL: URL = legacyURL, to target: URL = url) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path),
              fm.fileExists(atPath: legacyURL.path) else { return false }

        do {
            for suffix in sidecarSuffixes {
                let source = URL(fileURLWithPath: legacyURL.path + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(at: source, to: URL(fileURLWithPath: target.path + suffix))
            }
            let legacySupport = supportDirectory(for: legacyURL)
            if fm.fileExists(atPath: legacySupport.path) {
                try fm.copyItem(at: legacySupport, to: supportDirectory(for: target))
            }
            locationLogger.info("Copied legacy history store to \(target.path, privacy: .public)")
            return true
        } catch {
            locationLogger.error("Could not copy legacy history store: \(String(describing: error), privacy: .public)")
            removeStore(at: target)
            return false
        }
    }

    /// Deletes the store at `url` with its sidecar files and external-storage folder.
    static func removeStore(at store: URL = url) {
        for suffix in sidecarSuffixes {
            try? FileManager.default.removeItem(atPath: store.path + suffix)
        }
        try? FileManager.default.removeItem(at: supportDirectory(for: store))
    }

    // MARK: - Retiring the legacy store

    /// Moves the legacy `default.store` to the Trash once its copy is known to be complete.
    /// Call it only right after `migrateLegacyStoreIfNeeded` copied the store this launch and
    /// the new store opened, before anything writes to the new store.
    ///
    /// Every check must pass, otherwise the legacy store is left alone:
    /// 1. It holds nothing but NovaClipboard's tables and entities — another unsandboxed
    ///    SwiftData app may share the file, and its data is not ours to delete.
    /// 2. The copy passes SQLite's `quick_check`.
    /// 3. Legacy and copy hold the same number of items, and that matches what the opened
    ///    container reports (`openedItemCount`).
    /// 4. Every external-storage blob made it into the copy's support folder.
    /// The files go to the Trash rather than being deleted, so the user can still recover them.
    /// - Returns: true when the legacy store was moved away.
    @discardableResult
    static func retireLegacyStoreIfSafe(
        openedItemCount: Int,
        legacy: URL = legacyURL,
        copy: URL = url,
        discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> Bool {
        guard isOnlyClipboardHistory(legacy) else {
            locationLogger.info("Keeping legacy store: it holds data that isn't NovaClipboard's")
            return false
        }
        guard quickCheck(copy) else {
            locationLogger.error("Keeping legacy store: the copy failed quick_check")
            return false
        }
        guard let legacyCount = itemCount(legacy), let copyCount = itemCount(copy),
              legacyCount == copyCount, copyCount == openedItemCount else {
            locationLogger.error("Keeping legacy store: item counts differ (legacy=\(itemCount(legacy) ?? -1, privacy: .public) copy=\(itemCount(copy) ?? -1, privacy: .public) opened=\(openedItemCount, privacy: .public))")
            return false
        }
        let legacyBlobs = externalBlobNames(for: legacy)
        guard legacyBlobs.isSubset(of: externalBlobNames(for: copy)) else {
            locationLogger.error("Keeping legacy store: external blobs are missing from the copy")
            return false
        }

        // The main file goes first: if it can't be moved nothing has changed. Once it's gone
        // the sidecars and blob folder are orphans, so a failure there is only logged.
        do {
            try discard(legacy)
        } catch {
            locationLogger.error("Could not move legacy store to the Trash: \(String(describing: error), privacy: .public)")
            return false
        }
        var trashed = [legacy.lastPathComponent]
        let leftovers = ["-wal", "-shm"].map { URL(fileURLWithPath: legacy.path + $0) } + [supportDirectory(for: legacy)]
        for target in leftovers where FileManager.default.fileExists(atPath: target.path) {
            do {
                try discard(target)
                trashed.append(target.lastPathComponent)
            } catch {
                locationLogger.error("Could not move \(target.path, privacy: .public) to the Trash: \(String(describing: error), privacy: .public)")
            }
        }
        locationLogger.info("Moved legacy store to the Trash (\(legacyCount, privacy: .public) items verified): \(trashed.joined(separator: ", "), privacy: .public)")
        return true
    }

    private static func isOnlyClipboardHistory(_ store: URL) -> Bool {
        guard let tables = query(store, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"),
              let entities = query(store, "SELECT Z_NAME FROM Z_PRIMARYKEY") else { return false }
        return Set(tables).isSubset(of: ownTables)
            && Set(entities).isSubset(of: ownEntities)
            && entities.contains("ClipboardItem")
    }

    private static func quickCheck(_ store: URL) -> Bool {
        query(store, "PRAGMA quick_check") == ["ok"]
    }

    private static func itemCount(_ store: URL) -> Int? {
        query(store, "SELECT COUNT(*) FROM ZCLIPBOARDITEM")?.first.flatMap { Int($0) }
    }

    private static func externalBlobNames(for store: URL) -> Set<String> {
        let dir = supportDirectory(for: store).appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
        return Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    /// Runs a read-only query and returns the first column of each row, or nil on any error.
    private static func query(_ store: URL, _ sql: String) -> [String]? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }

        var rows: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
            case SQLITE_DONE:
                return rows
            default:
                return nil
            }
        }
    }
}
