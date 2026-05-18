import XCTest
@testable import NovaClipboard

final class ChecksumTests: XCTestCase {
    func testStableForSameInput() {
        let a = Checksum.sha256("hello world")
        let b = Checksum.sha256("hello world")
        XCTAssertEqual(a, b)
    }

    func testDiffersForDifferentInput() {
        let a = Checksum.sha256("hello")
        let b = Checksum.sha256("Hello")
        XCTAssertNotEqual(a, b)
    }

    func testKnownVector() {
        XCTAssertEqual(
            Checksum.sha256(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }
}
