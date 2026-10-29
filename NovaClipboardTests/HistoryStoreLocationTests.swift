import XCTest
import SwiftData
@testable import NovaClipboard

/// Stands in for another unsandboxed SwiftData app sharing `default.store`.
@Model
final class ForeignNote {
    var title: String
    init(title: String) { self.title = title }
}

@MainActor
final class HistoryStoreLocationTests: XCTestCase {
    private var dir: URL!
    private var legacy: URL { dir.appendingPathComponent("default.store") }
    private var copy: URL { dir.appendingPathComponent("NovaClipboard/History.store") }
    private var discarded: [String] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreLocationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        discarded = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testMigratesAndRetiresOwnLegacyStore() throws {
        try makeStore(at: legacy, items: 3)
        try addExternalBlob(named: "blob-1", to: legacy)

        XCTAssertTrue(HistoryStoreLocation.migrateLegacyStoreIfNeeded(from: legacy, to: copy))
        XCTAssertEqual(try openedCount(copy), 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalDataDir(for: copy).appendingPathComponent("blob-1").path))

        XCTAssertTrue(retire(opened: 3))
        XCTAssertEqual(discarded.first, "default.store", "the main file must go first")
        XCTAssertTrue(discarded.contains(".default_SUPPORT"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try openedCount(copy), 3, "the copy must be untouched")
    }

    func testKeepsLegacyStoreSharedWithAnotherApp() throws {
        try makeStore(at: legacy, items: 2, foreignNotes: 1)
        XCTAssertTrue(HistoryStoreLocation.migrateLegacyStoreIfNeeded(from: legacy, to: copy))

        XCTAssertFalse(retire(opened: 2))
        XCTAssertTrue(discarded.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testKeepsLegacyStoreWhenCountsDiffer() throws {
        try makeStore(at: legacy, items: 2)
        XCTAssertTrue(HistoryStoreLocation.migrateLegacyStoreIfNeeded(from: legacy, to: copy))

        XCTAssertFalse(retire(opened: 1))
        XCTAssertTrue(discarded.isEmpty)
    }

    func testKeepsLegacyStoreWhenBlobMissingFromCopy() throws {
        try makeStore(at: legacy, items: 1)
        XCTAssertTrue(HistoryStoreLocation.migrateLegacyStoreIfNeeded(from: legacy, to: copy))
        try addExternalBlob(named: "late-blob", to: legacy)

        XCTAssertFalse(retire(opened: 1))
        XCTAssertTrue(discarded.isEmpty)
    }

    func testKeepsLegacyStoreWhenCopyIsCorrupt() throws {
        try makeStore(at: legacy, items: 1)
        XCTAssertTrue(HistoryStoreLocation.migrateLegacyStoreIfNeeded(from: legacy, to: copy))
        HistoryStoreLocation.removeStore(at: copy)
        try Data("not a database".utf8).write(to: copy)

        XCTAssertFalse(retire(opened: 1))
        XCTAssertTrue(discarded.isEmpty)
    }

    func testFailureToTrashMainFileLeavesEverything() throws {
        try makeStore(at: legacy, items: 1)
        XCTAssertTrue(HistoryStoreLocation.migrateLegacyStoreIfNeeded(from: legacy, to: copy))

        let retired = HistoryStoreLocation.retireLegacyStoreIfSafe(
            openedItemCount: 1, legacy: legacy, copy: copy,
            discard: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        XCTAssertFalse(retired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testDoesNotMigrateOverExistingStore() throws {
        try makeStore(at: legacy, items: 1)
        try makeStore(at: copy, items: 5)
        XCTAssertFalse(HistoryStoreLocation.migrateLegacyStoreIfNeeded(from: legacy, to: copy))
        XCTAssertEqual(try openedCount(copy), 5)
    }

    // MARK: - Helpers

    @discardableResult
    private func retire(opened: Int) -> Bool {
        HistoryStoreLocation.retireLegacyStoreIfSafe(
            openedItemCount: opened, legacy: legacy, copy: copy,
            discard: { [self] url in
                discarded.append(url.lastPathComponent)
                try FileManager.default.removeItem(at: url)
            }
        )
    }

    private func makeStore(at url: URL, items: Int, foreignNotes: Int = 0) throws {
        let types: [any PersistentModel.Type] = foreignNotes > 0 ? [ClipboardItem.self, ForeignNote.self] : [ClipboardItem.self]
        let schema = Schema(types)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = ModelContext(container)
        for i in 0..<items { context.insert(ClipboardItem.text("item-\(i)")) }
        for i in 0..<foreignNotes { context.insert(ForeignNote(title: "note-\(i)")) }
        try context.save()
    }

    private func openedCount(_ url: URL) throws -> Int {
        let schema = Schema([ClipboardItem.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        return try ModelContext(container).fetchCount(FetchDescriptor<ClipboardItem>())
    }

    private func externalDataDir(for store: URL) -> URL {
        store.deletingLastPathComponent()
            .appendingPathComponent(".\(store.deletingPathExtension().lastPathComponent)_SUPPORT/_EXTERNAL_DATA", isDirectory: true)
    }

    private func addExternalBlob(named name: String, to store: URL) throws {
        let dir = externalDataDir(for: store)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent(name))
    }
}
