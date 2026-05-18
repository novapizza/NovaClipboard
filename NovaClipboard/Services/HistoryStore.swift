import Foundation
import SwiftData

@MainActor
final class HistoryStore {
    static let defaultLimit = 500

    private let context: ModelContext
    private let limit: Int

    init(context: ModelContext, limit: Int = HistoryStore.defaultLimit) {
        self.context = context
        self.limit = limit
    }

    @discardableResult
    func insert(_ item: ClipboardItem) -> ClipboardItem {
        if let mostRecent = fetchMostRecent(), mostRecent.checksum == item.checksum {
            mostRecent.createdAt = Date()
            try? context.save()
            return mostRecent
        }

        context.insert(item)
        evictOverflowIfNeeded()
        try? context.save()
        return item
    }

    func delete(_ item: ClipboardItem) {
        context.delete(item)
        try? context.save()
    }

    func clearAll(keepPinned: Bool = true) {
        let predicate: Predicate<ClipboardItem>? = keepPinned
            ? #Predicate { !$0.isPinned }
            : nil
        let descriptor = FetchDescriptor<ClipboardItem>(predicate: predicate)
        let items = (try? context.fetch(descriptor)) ?? []
        for item in items {
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

    private func fetchMostRecent() -> ClipboardItem? {
        var descriptor = FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
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
            context.delete(item)
        }
    }
}
