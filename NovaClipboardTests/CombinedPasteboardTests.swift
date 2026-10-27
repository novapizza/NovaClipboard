import XCTest
import AppKit
import SwiftData
@testable import NovaClipboard

@MainActor
final class CombinedPasteboardTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema([ClipboardItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    private func insert(_ items: ClipboardItem...) -> [ClipboardItem] {
        items.forEach { container.mainContext.insert($0) }
        return items
    }

    func testTextOnlyJoinsWithNewlines() {
        let items = insert(.text("alpha"), .link("https://example.com"))
        let result = ClipboardItem.combinedPasteboardItems(items)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].string(forType: .string), "alpha\nhttps://example.com")
        XCTAssertNil(result[0].string(forType: .fileURL))
    }

    func testTextAndImageMixIsOneRichTextItemInSelectionOrder() throws {
        let items = insert(.text("before <b>"), .image(data: pngData(), inline: true), .text("after"))
        let result = ClipboardItem.combinedPasteboardItems(items)

        XCTAssertEqual(result.count, 1)
        let item = result[0]
        XCTAssertNil(item.string(forType: .fileURL), "file URLs make Google Docs drop the text")
        XCTAssertEqual(item.string(forType: .string), "before <b>\nafter")
        XCTAssertNotNil(item.data(forType: .rtfd))

        let html = try XCTUnwrap(item.string(forType: .html))
        let before = try XCTUnwrap(html.range(of: "before &lt;b&gt;"))
        let image = try XCTUnwrap(html.range(of: "<img src=\"data:image/png;base64,"))
        let after = try XCTUnwrap(html.range(of: "after"))
        XCTAssertLessThan(before.lowerBound, image.lowerBound)
        XCTAssertLessThan(image.lowerBound, after.lowerBound)
    }

    func testMixWithPlainFileKeepsFileURLs() {
        let items = insert(.text("note"), .file(urls: ["file:///tmp/a.zip"]))
        let result = ClipboardItem.combinedPasteboardItems(items)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].string(forType: .fileURL), "file:///tmp/a.zip")
        XCTAssertEqual(result[0].string(forType: .string), "note")
    }

    func testPayloadIsMarkedTransient() {
        let items = insert(.text("a"), .text("b"))
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        XCTAssertNotNil(ClipboardItem.combinedPasteboardItems(items).first?.data(forType: transient))
        XCTAssertNil(ClipboardItem.combinedPasteboardItems(items, markTransient: false).first?.data(forType: transient))
    }
}
