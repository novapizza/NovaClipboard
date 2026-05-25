import SwiftUI
import SwiftData
import AppKit
import Combine

enum HistoryFilter: Hashable, Identifiable {
    case all
    case type(ItemType)
    case pinned

    var id: String {
        switch self {
        case .all: return "all"
        case .pinned: return "pinned"
        case .type(let t): return "type-\(t.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .all: return "All"
        case .pinned: return "Pinned"
        case .type(.text), .type(.richText): return "Text"
        case .type(.image): return "Image"
        case .type(.link): return "Link"
        case .type(.file): return "File"
        }
    }

    static let bar: [HistoryFilter] = [
        .all,
        .type(.text),
        .type(.image),
        .type(.link),
        .pinned
    ]
}

struct HistoryPanelView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var allItems: [ClipboardItem]

    @State private var selectedID: PersistentIdentifier?
    @State private var query: String = ""
    @State private var debouncedQuery: String = ""
    @State private var filter: HistoryFilter = .all
    @State private var searchFocused: Bool = false
    @State private var debounceTask: Task<Void, Never>?
    @State private var showClearAllConfirm: Bool = false

    let onPaste: (ClipboardItem) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            panelBackground
                .ignoresSafeArea()

            VStack(spacing: 10) {
                headerBar

                if visibleItems.isEmpty {
                    emptyState
                } else {
                    listBody
                }

                statusBar
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .frame(width: 380, height: 480)
        .background(KeyHandlerView(actions: keyActions))
        .onAppear {
            debouncedQuery = query
            ensureSelection()
        }
        .onChange(of: query) { _, newValue in
            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                debouncedQuery = newValue
            }
        }
        .onChange(of: visibleItems) { _, _ in ensureSelection() }
        .onChange(of: filter) { _, _ in ensureSelection() }
    }

    private var panelBackground: some View {
        ZStack {
            // Soft tinted gradient backdrop so Liquid Glass has something
            // colorful to refract. On macOS 14/15 this is still the visual
            // floor under the .ultraThinMaterial fallback.
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.18),
                    Color.purple.opacity(0.10),
                    Color.blue.opacity(0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Clipboard")
                .font(.headline)
            Spacer()
            Button {
                showClearAllConfirm = true
            } label: {
                Label("Clear", systemImage: "trash")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.liquidGlass())
            .disabled(visibleItems.isEmpty)
            .opacity(visibleItems.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .liquidGlass(.regular, in: .capsule)
        .confirmationDialog(
            "Clear all clipboard history?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { clearAllNonPinned() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned items will be kept.")
        }
    }

    private func clearAllNonPinned() {
        let toDelete = allItems.filter { !$0.isPinned }
        for item in toDelete {
            ImageStore.deleteFile(at: item.imagePath)
            ImageThumbnailCache.shared.invalidate(id: item.id)
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            if query.isEmpty {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .liquidGlass(.regular, in: .circle)
                    .padding(.bottom, 4)
                Text("Nothing here")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("You'll see your clipboard history here once you've copied something.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            } else {
                Text("No matches")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    let pinnedCount = pinnedItems.count
                    ForEach(Array(visibleItems.enumerated()), id: \.element.persistentModelID) { idx, item in
                        if shouldShowPinnedSection && pinnedCount > 0 && idx == pinnedCount && !recentItems.isEmpty {
                            sectionHeader("Recent")
                        }
                        row(for: item, quickIdx: idx)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.linear(duration: 0.08)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            shortcutChip("↑↓", "Select")
            shortcutChip("↵", "Paste")
            shortcutChip("⌘P", "Pin")
            shortcutChip("⌫", "Delete")
            Spacer()
            Text("\(visibleItems.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .liquidGlass(.regular, in: .capsule)
                .accessibilityLabel("\(visibleItems.count) items")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .liquidGlass(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
    }

    private func shortcutChip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func row(for item: ClipboardItem, quickIdx: Int?) -> some View {
        HistoryItemRow(
            item: item,
            isSelected: item.persistentModelID == selectedID,
            quickPasteIndex: quickIdx,
            onTogglePin: { togglePin(for: item) },
            onDelete: { delete(item) }
        )
        .id(item.persistentModelID)
        .contentShape(Rectangle())
        .onTapGesture { onPaste(item) }
        .onHover { hovering in
            if hovering { selectedID = item.persistentModelID }
        }
    }

    // MARK: - Filtering

    private var shouldShowPinnedSection: Bool {
        // Only show as a separate "Pinned" section when not already filtering by pinned.
        if case .pinned = filter { return false }
        return true
    }

    private var filteredItems: [ClipboardItem] {
        let q = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return allItems.filter { item in
            // Type / pinned filter
            switch filter {
            case .all: break
            case .pinned where !item.isPinned: return false
            case .pinned: break
            case .type(let t):
                if t == .text {
                    if item.type != .text && item.type != .richText { return false }
                } else if item.type != t { return false }
            }
            // Query filter
            if !q.isEmpty {
                if !item.preview.localizedCaseInsensitiveContains(q) { return false }
            }
            return true
        }
    }

    private var pinnedItems: [ClipboardItem] {
        filteredItems.filter { $0.isPinned }
    }

    private var recentItems: [ClipboardItem] {
        if case .pinned = filter { return [] }
        return filteredItems.filter { !$0.isPinned }
    }

    private var visibleItems: [ClipboardItem] {
        if case .pinned = filter {
            return pinnedItems
        }
        // pinned first (when visible), then recent — matches displayed order
        return shouldShowPinnedSection ? (pinnedItems + recentItems) : filteredItems
    }

    private func ensureSelection() {
        if selectedID == nil || !visibleItems.contains(where: { $0.persistentModelID == selectedID }) {
            selectedID = visibleItems.first?.persistentModelID
        }
    }

    // MARK: - Key actions

    private var keyActions: KeyActions {
        KeyActions(
            onMoveUp: { moveSelection(by: -1) },
            onMoveDown: { moveSelection(by: 1) },
            onConfirm: confirmSelection,
            onCancel: onDismiss,
            onTogglePin: togglePin,
            onDelete: deleteSelected,
            onFocusSearch: { searchFocused = true },
            onQuickPaste: quickPaste
        )
    }

    private func moveSelection(by delta: Int) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        let currentIdx = items.firstIndex(where: { $0.persistentModelID == selectedID }) ?? 0
        let next = max(0, min(items.count - 1, currentIdx + delta))
        selectedID = items[next].persistentModelID
    }

    private func confirmSelection() {
        guard let item = currentItem() else { return }
        onPaste(item)
    }

    private func quickPaste(index: Int) {
        // index is 0..8 (⌘1..⌘9). Maps to the visible row in order (pinned first, then recent).
        let items = visibleItems
        guard index < items.count else { return }
        onPaste(items[index])
    }

    private func togglePin() {
        guard let item = currentItem() else { return }
        togglePin(for: item)
    }

    private func togglePin(for item: ClipboardItem) {
        item.isPinned.toggle()
        try? modelContext.save()
    }

    private func deleteSelected() {
        guard let item = currentItem() else { return }
        delete(item)
    }

    private func delete(_ item: ClipboardItem) {
        ImageStore.deleteFile(at: item.imagePath)
        ImageThumbnailCache.shared.invalidate(id: item.id)
        modelContext.delete(item)
        try? modelContext.save()
    }

    private func currentItem() -> ClipboardItem? {
        guard let selectedID else { return nil }
        return visibleItems.first(where: { $0.persistentModelID == selectedID })
    }
}

// MARK: - Search bar

private struct SearchBar: View {
    @Binding var query: String
    @Binding var isFocused: Bool
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .accessibilityLabel("Search clipboard history")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
        )
        .onChange(of: isFocused) { _, newValue in
            if newValue { fieldFocused = true; isFocused = false }
        }
    }
}

// MARK: - Filter chips

private struct FilterChipsBar: View {
    @Binding var filter: HistoryFilter

    var body: some View {
        HStack(spacing: 6) {
            ForEach(HistoryFilter.bar) { f in
                Chip(title: f.title, selected: f == filter) { filter = f }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct Chip: View {
    let title: String
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(selected ? Color.accentColor : Color.secondary.opacity(0.15))
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter: \(title)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Key handler

struct KeyActions {
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void
    var onTogglePin: () -> Void
    var onDelete: () -> Void
    var onFocusSearch: () -> Void
    var onQuickPaste: (Int) -> Void
}

private struct KeyHandlerView: NSViewRepresentable {
    var actions: KeyActions

    func makeNSView(context: Context) -> NSView {
        let view = KeyCaptureView()
        view.actions = actions
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyCaptureView else { return }
        view.actions = actions
    }
}

private final class KeyCaptureView: NSView {
    var actions: KeyActions?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let actions else { super.keyDown(with: event); return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command)

        // ⌘1..⌘9 quick paste
        if cmd, mods.subtracting(.command).isEmpty,
           let chars = event.charactersIgnoringModifiers,
           let digit = chars.first?.wholeNumberValue,
           digit >= 1, digit <= 9 {
            actions.onQuickPaste(digit - 1)
            return
        }

        // TEMP: ⌘F focus search disabled while the search bar is hidden.
        // if cmd, event.charactersIgnoringModifiers == "f" {
        //     actions.onFocusSearch()
        //     return
        // }

        // ⌘P toggle pin
        if cmd, event.charactersIgnoringModifiers == "p" {
            actions.onTogglePin()
            return
        }

        switch Int(event.keyCode) {
        case 126: actions.onMoveUp()
        case 125: actions.onMoveDown()
        case 36, 76: actions.onConfirm()
        case 53: actions.onCancel()
        case 51: // delete/backspace
            actions.onDelete()
        default: super.keyDown(with: event)
        }
    }
}
