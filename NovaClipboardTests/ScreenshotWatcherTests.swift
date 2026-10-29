import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import NovaClipboard

final class ScreenshotWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// A German system names captures "Bildschirmfoto …"; the EXIF comment still identifies them.
    func testLocalizedNameIsDetectedByExifComment() throws {
        let url = dir.appendingPathComponent("Bildschirmfoto 2026-10-28 um 20.45.21.png")
        try writePNG(to: url, userComment: "Screenshot")
        XCTAssertTrue(ScreenshotWatcher.isScreenshot(path: url.path))
    }

    func testEnglishNameIsDetected() throws {
        let url = dir.appendingPathComponent("Screenshot 2026-10-28 at 20.45.21.png")
        try writePNG(to: url, userComment: nil)
        XCTAssertTrue(ScreenshotWatcher.isScreenshot(path: url.path))
    }

    func testOtherImageIsIgnored() throws {
        let url = dir.appendingPathComponent("photo.png")
        try writePNG(to: url, userComment: nil)
        XCTAssertFalse(ScreenshotWatcher.isScreenshot(path: url.path))
    }

    private func writePNG(to url: URL, userComment: String?) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let image = try XCTUnwrap(rep.cgImage)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let userComment {
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: userComment]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
