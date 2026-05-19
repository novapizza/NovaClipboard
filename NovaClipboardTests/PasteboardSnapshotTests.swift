import XCTest
import AppKit
@testable import NovaClipboard

final class PasteboardSnapshotTests: XCTestCase {
    func testRestoresStringContent() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }

        pb.clearContents()
        pb.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot(capturing: pb)

        pb.clearContents()
        pb.setString("paste-target", forType: .string)
        XCTAssertEqual(pb.string(forType: .string), "paste-target")

        snapshot.restore(to: pb)
        XCTAssertEqual(pb.string(forType: .string), "original")
    }

    func testPreservesMultipleTypes() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(Data([0xDE, 0xAD, 0xBE, 0xEF]),
                     forType: NSPasteboard.PasteboardType("public.custom"))
        pb.writeObjects([item])

        let snapshot = PasteboardSnapshot(capturing: pb)
        pb.clearContents()
        pb.setString("replaced", forType: .string)
        snapshot.restore(to: pb)

        XCTAssertEqual(pb.string(forType: .string), "hello")
        XCTAssertEqual(
            pb.data(forType: NSPasteboard.PasteboardType("public.custom")),
            Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
    }
}
