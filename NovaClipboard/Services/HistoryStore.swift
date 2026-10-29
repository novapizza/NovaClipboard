import Foundation
import SwiftData
import os

private let storeLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "HistoryStore")

@MainActor
final class HistoryStore {
    private let context: ModelContext
    var limit: Int

    init(context: ModelContext, limit: Int) {
        self.context = context
        self.limit = limit
    }

    @discardableResult
    func insert(_ item: ClipboardItem) -> ClipboardItem {
        if let dup = findRecentDuplicate(checksum: item.checksum) {
            dup.createdAt = Date()
            // Refresh source attribution to the most recent copy so blocklist /
            // analytics reflect where the content came from this time.
            dup.sourceBundleID = item.sourceBundleID
            // Free up the new item's external image file (it was written eagerly by Monitor).
            ImageStore.deleteFile(at: item.imagePath)
            save()
            return dup
        }

        context.insert(item)
        evictOverflowIfNeeded()
        save()
        return item
    }

    func delete(_ item: ClipboardItem) {
        ImageStore.deleteFile(at: item.imagePath)
        ImageThumbnailCache.shared.invalidate(id: item.id)
        context.delete(item)
        save()
    }

    func togglePin(_ item: ClipboardItem) {
        item.isPinned.toggle()
        save()
    }

    func clearAll(keepPinned: Bool = true) {
        let predicate: Predicate<ClipboardItem>? = keepPinned
            ? #Predicate { !$0.isPinned }
            : nil
        let descriptor = FetchDescriptor<ClipboardItem>(predicate: predicate)
        let items = fetch(descriptor)
        for item in items {
            ImageStore.deleteFile(at: item.imagePath)
            ImageThumbnailCache.shared.invalidate(id: item.id)
            context.delete(item)
        }
        save()
    }

    var isEmpty: Bool {
        let descriptor = FetchDescriptor<ClipboardItem>()
        let count = fetchCount(descriptor)
        return count == 0
    }

    var hasClearableItems: Bool {
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { !$0.isPinned }
        )
        let count = fetchCount(descriptor)
        return count > 0
    }

    func fetchAll(limit: Int? = nil) -> [ClipboardItem] {
        var descriptor = FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        if let limit {
            descriptor.fetchLimit = limit
        }
        return fetch(descriptor)
    }

    /// Dedup against the most-recent N items by checksum (Spec §3.2 / Plan Step 3.2).
    /// Re-copying an older item refreshes its `createdAt` rather than inserting a duplicate.
    /// Window grows with `limit` so the dedup window always covers the visible history.
    private static let minDedupWindow = 50
    private var dedupWindow: Int { max(HistoryStore.minDedupWindow, limit) }

    private func findRecentDuplicate(checksum: String) -> ClipboardItem? {
        var descriptor = FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = dedupWindow
        let recent = fetch(descriptor)
        return recent.first(where: { $0.checksum == checksum })
    }

    func evictOverflowIfNeeded() {
        let countDescriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { !$0.isPinned }
        )
        let unpinnedCount = fetchCount(countDescriptor)
        guard unpinnedCount > limit else { return }

        var overflowDescriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { !$0.isPinned },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        overflowDescriptor.fetchLimit = unpinnedCount - limit
        let overflow = fetch(overflowDescriptor)
        for item in overflow {
            ImageStore.deleteFile(at: item.imagePath)
            ImageThumbnailCache.shared.invalidate(id: item.id)
            context.delete(item)
        }
        save()
    }

    /// Probes the store for Export Diagnostics, reporting the error instead of hiding it.
    var diagnosticsSummary: String {
        do {
            let total = try context.fetchCount(FetchDescriptor<ClipboardItem>())
            var newest = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            newest.fetchLimit = 1
            let newestDate = try context.fetch(newest).first.map { ISO8601DateFormatter().string(from: $0.createdAt) } ?? "none"
            return "fetch=ok items=\(total) newestItemAt=\(newestDate) unsavedChanges=\(context.hasChanges)"
        } catch {
            return "fetch=FAILED error=\(String(describing: error))"
        }
    }

    // MARK: - Error-reporting wrappers
    //
    // SwiftData errors used to be swallowed with `try?`, which hid a store that had gone bad
    // under a running app: every fetch/save failed silently, so new copies never showed up.

    private func save() {
        do {
            try context.save()
        } catch {
            storeLogger.error("Save failed: \(String(describing: error), privacy: .public)")
            // Drop the unsaved changes so one bad save doesn't make every later save fail too.
            context.rollback()
        }
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            storeLogger.error("Fetch failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func fetchCount<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> Int {
        do {
            return try context.fetchCount(descriptor)
        } catch {
            storeLogger.error("Fetch count failed: \(String(describing: error), privacy: .public)")
            return 0
        }
    }
}
