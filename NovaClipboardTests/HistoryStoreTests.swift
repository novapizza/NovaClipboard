import XCTest
import SwiftData
@testable import NovaClipboard

@MainActor
final class HistoryStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        let schema = Schema([ClipboardItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        store = HistoryStore(context: container.mainContext, limit: 500)
    }

    override func tearDown() {
        store = nil
        container = nil
        super.tearDown()
    }

    func testInsertThree() {
        store.insert(ClipboardItem.text("alpha"))
        store.insert(ClipboardItem.text("beta"))
        store.insert(ClipboardItem.text("gamma"))
        XCTAssertEqual(store.fetchAll().count, 3)
    }

    func testDedupUpdatesCreatedAt() {
        let first = store.insert(ClipboardItem.text("same"))
        let firstDate = first.createdAt
        Thread.sleep(forTimeInterval: 0.02)
        let second = store.insert(ClipboardItem.text("same"))
        XCTAssertEqual(store.fetchAll().count, 1)
        XCTAssertGreaterThan(second.createdAt, firstDate)
        XCTAssertEqual(first.id, second.id)
    }

    func testLimitEvictsOldest() {
        let limited = HistoryStore(context: container.mainContext, limit: 10)
        for i in 0..<15 {
            limited.insert(ClipboardItem.text("item-\(i)"))
        }
        let all = limited.fetchAll()
        XCTAssertEqual(all.count, 10)
        XCTAssertTrue(all.contains(where: { $0.preview == "item-14" }))
        XCTAssertFalse(all.contains(where: { $0.preview == "item-0" }))
    }

    func testClearAllRemovesEverythingByDefault() {
        store.insert(ClipboardItem.text("a"))
        store.insert(ClipboardItem.text("b"))
        store.insert(ClipboardItem.text("c"))
        store.clearAll(keepPinned: false)
        XCTAssertEqual(store.fetchAll().count, 0)
    }

    func testClearAllKeepsPinned() {
        store.insert(ClipboardItem.text("regular"))
        let pinned = store.insert(ClipboardItem.text("important"))
        pinned.isPinned = true
        try? container.mainContext.save()
        store.clearAll(keepPinned: true)
        let remaining = store.fetchAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.preview, "important")
    }
}
