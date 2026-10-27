import SwiftUI
import SwiftData
import AppKit
import Carbon.HIToolbox

struct HistoryPanelView: View {
    /// Cap on unpinned rows hydrated into the panel. Bigger histories still live in the
    /// database; the panel just never renders more than this many recents at once.
    private static let recentFetchLimit = 200

    @Query private var pinnedItems: [ClipboardItem]
    @Query private var recentItems: [ClipboardItem]

    @State private var selectedID: PersistentIdentifier?
    /// Set when the pending `selectedID` change came from mouse hover. The hovered
    /// row is already on screen, so scrolling it to center would only slide a new
    /// row under the cursor and chain into runaway auto-scroll.
    @State private var selectionFromHover: Bool = false
    @State private var showClearAllConfirm: Bool = false

    @ObservedObject private var settings = AppSettings.shared

    /// Modifier symbol prefix for quick-paste badges, mirroring the Settings combo.
    /// Empty when quick-paste is disabled, which also hides the badges.
    private var quickPasteSymbols: String {
        settings.quickPasteEnabled ? KeyCombo.modifierSymbols(settings.quickPasteModifiers) : ""
    }

    let store: HistoryStore
    let onPaste: (ClipboardItem) -> Void
    let onDismiss: () -> Void
    @ObservedObject var presentation: PanelPresentation
    let onOpenSettings: () -> Void
    let onOpenAccessibility: () -> Void

    init(
        store: HistoryStore,
        onPaste: @escaping (ClipboardItem) -> Void,
        onDismiss: @escaping () -> Void,
        presentation: PanelPresentation,
        onOpenSettings: @escaping () -> Void,
        onOpenAccessibility: @escaping () -> Void
    ) {
        self.store = store
        self.onPaste = onPaste
        self.onDismiss = onDismiss
        self.presentation = presentation
        self.onOpenSettings = onOpenSettings
        self.onOpenAccessibility = onOpenAccessibility

        let pinnedDescriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.isPinned },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        _pinnedItems = Query(pinnedDescriptor)

        var recentDescriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { !$0.isPinned },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        recentDescriptor.fetchLimit = HistoryPanelView.recentFetchLimit
        _recentItems = Query(recentDescriptor)
    }

    var body: some View {
        ZStack {
            panelBackground
                .ignoresSafeArea()

            VStack(spacing: 10) {
                headerBar

                if !presentation.isAccessibilityTrusted {
                    accessibilityBanner
                }

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
        .onAppear { ensureSelection() }
        .onChange(of: visibleIDs) { _, _ in ensureSelection() }
    }

    private var panelBackground: some View {
        LiquidGlassBackdrop(colors: [
            Color.accentColor.opacity(0.18),
            Color.purple.opacity(0.10),
            Color.blue.opacity(0.12)
        ])
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Clipboard")
                .font(.headline)
            Spacer()
            Button {
                showClearAllConfirm = true
            } label: {
                Label("Clear All", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.liquidGlass())
            .help("Clear All")
            .disabled(recentItems.isEmpty)
            .opacity(recentItems.isEmpty ? 0.5 : 1)
            // Settings stands in for the status-item menu that a left click no longer opens.
            if presentation.openedFromStatusItem {
                Button(action: onOpenSettings) {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.liquidGlass())
                .help("Settings")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .liquidGlass(.regular, in: .capsule)
        .confirmationDialog(
            "Clear all clipboard history?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { store.clearAll(keepPinned: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned items will be kept.")
        }
    }

    /// Without Accessibility, ⌘V synthesis silently fails, so warn before the user picks an
    /// item. Clicking does the same as the "Accessibility Permission" menu item.
    private var accessibilityBanner: some View {
        Button(action: onOpenAccessibility) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Accessibility permission required")
                        .font(.subheadline.weight(.semibold))
                    Text("Pasting won't work until access is granted. Click to fix.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .liquidGlassContent(.tinted(.orange), in: .roundedRect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Accessibility Permission")
        .accessibilityLabel("Accessibility permission required. Open setup.")
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .padding(14)
                .liquidGlassContent(.regular, in: .circle)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    let pinnedCount = pinnedItems.count
                    ForEach(Array(visibleItems.enumerated()), id: \.element.persistentModelID) { idx, item in
                        if pinnedCount > 0 && idx == pinnedCount && !recentItems.isEmpty {
                            sectionHeader(String(localized: "Recent"))
                        }
                        row(for: item, quickIdx: idx)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedID) { _, newValue in
                if selectionFromHover {
                    selectionFromHover = false
                    return
                }
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

    private func shortcutChip(_ key: String, _ label: LocalizedStringKey) -> some View {
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
        // Wrap in a `.plain`-styled Button (rather than `.onTapGesture`) so the
        // nested pin/delete buttons take unambiguous priority on their hit-test
        // rects — SwiftUI's gesture arbitration favors the inner Button.
        Button {
            onPaste(item)
        } label: {
            HistoryItemRow(
                item: item,
                isSelected: item.persistentModelID == selectedID,
                quickPasteIndex: quickIdx,
                quickPasteSymbols: quickPasteSymbols,
                onTogglePin: { store.togglePin(item) },
                onDelete: { store.delete(item) }
            )
        }
        .buttonStyle(.plain)
        .onDrag { item.dragItemProvider() }
        .id(item.persistentModelID)
        .onHover { hovering in
            // Only flag real changes: re-hovering the selected row fires no
            // `onChange`, so a stale flag would swallow the next keyboard scroll.
            if hovering && selectedID != item.persistentModelID {
                selectionFromHover = true
                selectedID = item.persistentModelID
            }
        }
    }

    // MARK: - Items

    private var visibleItems: [ClipboardItem] {
        pinnedItems + recentItems
    }

    /// Stable identity for `.onChange` so we don't re-fire on every body
    /// re-evaluation just because `visibleItems` is recomputed.
    private var visibleIDs: [PersistentIdentifier] {
        visibleItems.map(\.persistentModelID)
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
            onTogglePin: togglePinSelected,
            onDelete: deleteSelected,
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

    private func togglePinSelected() {
        guard let item = currentItem() else { return }
        store.togglePin(item)
    }

    private func deleteSelected() {
        guard let item = currentItem() else { return }
        store.delete(item)
    }

    private func currentItem() -> ClipboardItem? {
        guard let selectedID else { return nil }
        return visibleItems.first(where: { $0.persistentModelID == selectedID })
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

        // Quick paste — match the modifier combo configured in Settings (default ⌥⌘)
        // so the in-panel shortcut stays in sync with the global quick-paste hotkey.
        let settings = AppSettings.shared
        let quickPasteMods = KeyCombo.cocoaModifiers(from: settings.quickPasteModifiers)
        if settings.quickPasteEnabled, !quickPasteMods.isEmpty, mods == quickPasteMods,
           let digit = Self.digit(forKeyCode: event.keyCode) {
            actions.onQuickPaste(digit - 1)
            return
        }

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

    /// Maps a top-row number key's virtual keycode to its digit (1–9), layout-independent
    /// so quick-paste works regardless of which modifiers (e.g. ⇧) are in the combo.
    private static func digit(forKeyCode keyCode: UInt16) -> Int? {
        switch Int(keyCode) {
        case kVK_ANSI_1: return 1
        case kVK_ANSI_2: return 2
        case kVK_ANSI_3: return 3
        case kVK_ANSI_4: return 4
        case kVK_ANSI_5: return 5
        case kVK_ANSI_6: return 6
        case kVK_ANSI_7: return 7
        case kVK_ANSI_8: return 8
        case kVK_ANSI_9: return 9
        default: return nil
        }
    }
}
