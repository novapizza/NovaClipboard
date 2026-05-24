import AppKit
import Foundation
import os

private let imageStoreLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "ImageStore")

enum ImageStore {
    static let inlineLimitBytes = 1_024 * 1_024

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

    /// Persists image data — inline (< 1MB) or to disk as PNG file. Returns the on-disk path if a file was written.
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
    private let thumbnailSize = CGSize(width: 128, height: 128)

    private init() {
        cache.countLimit = 200
    }

    func thumbnail(for item: ClipboardItem) -> NSImage? {
        let key = item.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard item.isSafeToAccess,
              let image = ImageStore.loadImage(blob: item.imageBlob, path: item.imagePath) else {
            return nil
        }
        let thumb = makeThumbnail(image: image, size: thumbnailSize)
        cache.setObject(thumb, forKey: key)
        return thumb
    }

    func invalidate(id: UUID) {
        cache.removeObject(forKey: id.uuidString as NSString)
    }

    private func makeThumbnail(image: NSImage, size: CGSize) -> NSImage {
        let original = image.size
        guard original.width > 0, original.height > 0 else { return image }
        let scale = min(size.width / original.width, size.height / original.height, 1.0)
        let target = CGSize(width: original.width * scale, height: original.height * scale)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: target),
                   from: CGRect(origin: .zero, size: original),
                   operation: .copy,
                   fraction: 1.0)
        thumb.unlockFocus()
        return thumb
    }
}
