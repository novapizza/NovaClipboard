import Foundation
import SwiftData

enum ItemType: String, Codable, CaseIterable, Identifiable {
    case text
    case link
    case image
    case file
    case richText

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        case .richText: return "Rich Text"
        }
    }
}

@Model
final class ClipboardItem {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var typeRaw: String
    var preview: String
    var contentText: String?
    @Attribute(.externalStorage) var imageBlob: Data?
    var imagePath: String?
    var fileURLs: [String]?
    var sourceBundleID: String?
    var isPinned: Bool
    var checksum: String

    var type: ItemType {
        get { ItemType(rawValue: typeRaw) ?? .text }
        set { typeRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        type: ItemType,
        preview: String,
        contentText: String? = nil,
        imageBlob: Data? = nil,
        imagePath: String? = nil,
        fileURLs: [String]? = nil,
        sourceBundleID: String? = nil,
        isPinned: Bool = false,
        checksum: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.typeRaw = type.rawValue
        self.preview = preview
        self.contentText = contentText
        self.imageBlob = imageBlob
        self.imagePath = imagePath
        self.fileURLs = fileURLs
        self.sourceBundleID = sourceBundleID
        self.isPinned = isPinned
        self.checksum = checksum
    }
}

extension ClipboardItem {
    static func text(_ string: String, sourceBundleID: String? = nil) -> ClipboardItem {
        let truncated = String(string.prefix(200))
        return ClipboardItem(
            type: .text,
            preview: truncated,
            contentText: string,
            sourceBundleID: sourceBundleID,
            checksum: Checksum.sha256(string)
        )
    }

    static func link(_ url: String, sourceBundleID: String? = nil) -> ClipboardItem {
        ClipboardItem(
            type: .link,
            preview: url,
            contentText: url,
            sourceBundleID: sourceBundleID,
            checksum: Checksum.sha256(url)
        )
    }

    static func image(
        data: Data,
        inline: Bool,
        imagePath: String? = nil,
        sourceBundleID: String? = nil
    ) -> ClipboardItem {
        let sizeKB = Double(data.count) / 1024.0
        let preview = sizeKB < 1024
            ? String(format: "Image · %.0f KB", sizeKB)
            : String(format: "Image · %.1f MB", sizeKB / 1024.0)
        return ClipboardItem(
            type: .image,
            preview: preview,
            imageBlob: inline ? data : nil,
            imagePath: inline ? nil : imagePath,
            sourceBundleID: sourceBundleID,
            checksum: Checksum.sha256(data)
        )
    }

    static func file(urls: [String], sourceBundleID: String? = nil) -> ClipboardItem {
        let preview: String
        if urls.count == 1, let first = urls.first {
            preview = (first as NSString).lastPathComponent.removingPercentEncoding ?? first
        } else {
            preview = "\(urls.count) files"
        }
        let payload = urls.joined(separator: "\n")
        return ClipboardItem(
            type: .file,
            preview: preview,
            contentText: payload,
            fileURLs: urls,
            sourceBundleID: sourceBundleID,
            checksum: Checksum.sha256(payload)
        )
    }
}

extension ClipboardItem {
    var isSafeToAccess: Bool {
        !isDeleted && modelContext != nil
    }

    var safeImageBlob: Data? {
        guard isSafeToAccess else { return nil }
        return imageBlob
    }

    var safeImagePath: String? {
        guard isSafeToAccess else { return nil }
        return imagePath
    }
}
