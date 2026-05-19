import Foundation
import SwiftData

@MainActor
final class HistoryStore {
    static let defaultLimit = 500

    private let context: ModelContext
    var limit: Int

    init(context: ModelContext, limit: Int = HistoryStore.defaultLimit) {
        self.context = context
        self.limit = limit
    }

    @discardableResult
    func insert(_ item: ClipboardItem) -> ClipboardItem {
        if let dup = findRecentDuplicate(checksum: item.checksum) {
            dup.createdAt = Date()
            // Free up the new item's external image file (it was written eagerly by Monitor).
            ImageStore.deleteFile(at: item.imagePath)
            try? context.save()
            return dup
        }

        context.insert(item)
        evictOverflowIfNeeded()
        try? context.save()
        return item
    }

    func delete(_ item: ClipboardItem) {
        ImageStore.deleteFile(at: item.imagePath)
        ImageThumbnailCache.shared.invalidate(id: item.id)
        context.delete(item)
        try? context.save()
    }

    func togglePin(_ item: ClipboardItem) {
        item.isPinned.toggle()
        try? context.save()
    }

    func clearAll(keepPinned: Bool = true) {
        let predicate: Predicate<ClipboardItem>? = keepPinned
            ? #Predicate { !$0.isPinned }
            : nil
        let descriptor = FetchDescriptor<ClipboardItem>(predicate: predicate)
        let items = (try? context.fetch(descriptor)) ?? []
        for item in items {
            ImageStore.deleteFile(at: item.imagePath)
            ImageThumbnailCache.shared.invalidate(id: item.id)
            context.delete(item)
        }
        try? context.save()
    }

    func fetchAll(limit: Int? = nil) -> [ClipboardItem] {
        var descriptor = FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        if let limit {
            descriptor.fetchLimit = limit
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    func search(query: String, type: ItemType? = nil, pinnedOnly: Bool = false) -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let typeRaw = type?.rawValue
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { item in
                (typeRaw == nil || item.typeRaw == typeRaw!) &&
                (!pinnedOnly || item.isPinned) &&
                (trimmed.isEmpty || item.preview.localizedStandardContains(trimmed))
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Dedup against the most-recent N items by checksum (Spec §3.2 / Plan Step 3.2).
    /// Re-copying an older item refreshes its `createdAt` rather than inserting a duplicate.
    private static let dedupWindow = 50

    private func findRecentDuplicate(checksum: String) -> ClipboardItem? {
        var descriptor = FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = HistoryStore.dedupWindow
        let recent = (try? context.fetch(descriptor)) ?? []
        return recent.first(where: { $0.checksum == checksum })
    }

    private func evictOverflowIfNeeded() {
        let countDescriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { !$0.isPinned }
        )
        let unpinnedCount = (try? context.fetchCount(countDescriptor)) ?? 0
        guard unpinnedCount > limit else { return }

        var overflowDescriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { !$0.isPinned },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        overflowDescriptor.fetchLimit = unpinnedCount - limit
        let overflow = (try? context.fetch(overflowDescriptor)) ?? []
        for item in overflow {
            ImageStore.deleteFile(at: item.imagePath)
            ImageThumbnailCache.shared.invalidate(id: item.id)
            context.delete(item)
        }
    }
}
