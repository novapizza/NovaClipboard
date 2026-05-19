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
