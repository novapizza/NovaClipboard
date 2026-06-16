import AppKit
import Foundation
import os

private let imageStoreLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "ImageStore")

enum ImageStore {
    /// Aligned with SwiftData's own external-storage spill threshold (~128 KB) so the
    /// `@Attribute(.externalStorage)` on `imageBlob` doesn't silently duplicate the
    /// disk-spill that our `imagePath` tier already performs for larger images.
    static let inlineLimitBytes = 128 * 1_024

    static var imagesDirectory: URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("NovaClipboard/Images", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Persists image data to disk as a PNG file when the blob exceeds `inlineLimitBytes`.
    /// Returns the on-disk path if a file was written; otherwise nil (callers keep it inline).
    @discardableResult
    static func write(data: Data, id: UUID) -> String? {
        guard data.count >= inlineLimitBytes else { return nil }
        let url = imagesDirectory.appendingPathComponent("\(id.uuidString).png")
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            imageStoreLogger.error("Failed to write image: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func loadImage(blob: Data?, path: String?) -> NSImage? {
        if let blob, let img = NSImage(data: blob) { return img }
        if let path, let img = NSImage(contentsOfFile: path) { return img }
        return nil
    }

    static func deleteFile(at path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}

@MainActor
final class ImageThumbnailCache {
    static let shared = ImageThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private static let thumbnailSize = CGSize(width: 128, height: 128)

    private init() {
        cache.countLimit = 200
    }

    /// Synchronous cache hit. Returns nil on miss — callers should follow up with `loadThumbnail`.
    func cached(for item: ClipboardItem) -> NSImage? {
        cache.object(forKey: item.id.uuidString as NSString)
    }

    /// Loads & rasterizes the thumbnail off the main thread on a cache miss, then memoizes it.
    func loadThumbnail(for item: ClipboardItem) async -> NSImage? {
        let key = item.id.uuidString as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let blob = item.imageBlob
        let path = item.imagePath
        let size = ImageThumbnailCache.thumbnailSize
        let rendered = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let image = ImageStore.loadImage(blob: blob, path: path) else { return nil }
            return ImageThumbnailCache.makeThumbnail(image: image, size: size)
        }.value

        if let rendered {
            cache.setObject(rendered, forKey: key)
        }
        return rendered
    }

    func invalidate(id: UUID) {
        cache.removeObject(forKey: id.uuidString as NSString)
    }

    /// Rasterizes into an offscreen `NSBitmapImageRep` instead of relying on `lockFocus` so
    /// this can run off the main thread and survives `lockFocus`'s deprecation in macOS 15+.
    nonisolated static func makeThumbnail(image: NSImage, size: CGSize) -> NSImage {
        let original = image.size
        guard original.width > 0, original.height > 0 else { return image }
        let scale = min(size.width / original.width, size.height / original.height, 1.0)
        let target = CGSize(width: original.width * scale, height: original.height * scale)

        let pixelsWide = Int(target.width.rounded())
        let pixelsHigh = Int(target.height.rounded())
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 32
              ) else { return image }
        rep.size = target

        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            image.draw(in: NSRect(origin: .zero, size: target),
                       from: NSRect(origin: .zero, size: original),
                       operation: .copy,
                       fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
        }

        let thumb = NSImage(size: target)
        thumb.addRepresentation(rep)
        return thumb
    }
}
