import Foundation
import SwiftData

enum ItemType: String, Codable {
    case text
    case link
    case image
    case file
    case richText
}

@Model
final class ClipboardItem {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var typeRaw: String
    var preview: String
    var contentText: String?
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
        sourceBundleID: String? = nil,
        isPinned: Bool = false,
        checksum: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.typeRaw = type.rawValue
        self.preview = preview
        self.contentText = contentText
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
}
