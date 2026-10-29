import XCTest
import AppKit
@testable import NovaClipboard

final class ClipboardMonitorTests: XCTestCase {
    func testDetectsTextChange() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let monitor = ClipboardMonitor(pasteboard: pasteboard, pollInterval: 0.05)
        let exp = expectation(description: "onNewItem fires")
        monitor.onNewItem = { item in
            XCTAssertEqual(item.contentText, "monitor-payload")
            exp.fulfill()
        }
        monitor.start()
        defer { monitor.stop() }

        pasteboard.clearContents()
        pasteboard.setString("monitor-payload", forType: .string)

        wait(for: [exp], timeout: 2.0)
    }

    func testSkipsConcealedUTI() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let monitor = ClipboardMonitor(pasteboard: pasteboard, pollInterval: 0.05)
        var fired = 0
        monitor.onNewItem = { _ in fired += 1 }
        monitor.start()
        defer { monitor.stop() }

        pasteboard.clearContents()
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let item = NSPasteboardItem()
        item.setString("secret-payload", forType: .string)
        item.setString("1", forType: concealed)
        pasteboard.writeObjects([item])

        // Give the monitor a couple of poll intervals.
        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(fired, 0, "concealed UTI should suppress capture")
    }

    /// Spreadsheets put a rendered picture of the cells next to their text.
    func testPrefersTextOverImage() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let monitor = ClipboardMonitor(pasteboard: pasteboard, pollInterval: 0.05)
        var received: [ClipboardItem] = []
        monitor.onNewItem = { received.append($0) }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Self.pngData(), forType: NSPasteboard.PasteboardType("public.png"))
        item.setString("cell value", forType: .string)
        pasteboard.writeObjects([item])
        monitor.pollNow()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.type, .text)
        XCTAssertEqual(received.first?.contentText, "cell value")
    }

    /// A browser's "Copy Image" can carry the image URL as text; the image wins.
    func testPrefersImageOverLink() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let monitor = ClipboardMonitor(pasteboard: pasteboard, pollInterval: 0.05)
        let exp = expectation(description: "onNewItem fires")
        monitor.onNewItem = { item in
            XCTAssertEqual(item.type, .image)
            exp.fulfill()
        }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Self.pngData(), forType: NSPasteboard.PasteboardType("public.png"))
        item.setString("https://example.com/photo.png", forType: .string)
        pasteboard.writeObjects([item])
        monitor.pollNow()

        wait(for: [exp], timeout: 2.0)
    }

    private static func pngData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    func testIgnoresSameContent() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("stable", forType: .string)

        let monitor = ClipboardMonitor(pasteboard: pasteboard, pollInterval: 0.05)
        var fired = 0
        monitor.onNewItem = { _ in fired += 1 }

        monitor.pollNow()
        monitor.pollNow()
        monitor.pollNow()
        XCTAssertEqual(fired, 0, "changeCount unchanged → should not fire")
    }
}
