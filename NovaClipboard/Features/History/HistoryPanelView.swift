import SwiftUI
import SwiftData

struct HistoryPanelView: View {
    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var items: [ClipboardItem]
    @State private var selectedID: PersistentIdentifier?

    let onPaste: (ClipboardItem) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            HistoryItemRow(item: item, isSelected: item.persistentModelID == selectedID)
                                .id(item.persistentModelID)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onPaste(item)
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: selectedID) { _, newValue in
                    guard let newValue else { return }
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }

            Divider()
            HStack(spacing: 12) {
                Text("↑↓ chọn")
                Text("↵ dán")
                Text("Esc đóng")
                Spacer()
                Text("\(items.count)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: 380, height: 480)
        .background(KeyHandlerView(
            onMoveUp: { moveSelection(by: -1) },
            onMoveDown: { moveSelection(by: 1) },
            onConfirm: { confirmSelection() },
            onCancel: { onDismiss() }
        ))
        .onAppear { selectedID = items.first?.persistentModelID }
        .onChange(of: items) { _, newItems in
            if selectedID == nil || !newItems.contains(where: { $0.persistentModelID == selectedID }) {
                selectedID = newItems.first?.persistentModelID
            }
        }
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let currentIdx = items.firstIndex(where: { $0.persistentModelID == selectedID }) ?? 0
        let next = max(0, min(items.count - 1, currentIdx + delta))
        selectedID = items[next].persistentModelID
    }

    private func confirmSelection() {
        guard let selectedID,
              let item = items.first(where: { $0.persistentModelID == selectedID }) else { return }
        onPaste(item)
    }
}

private struct KeyHandlerView: NSViewRepresentable {
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCaptureView()
        view.onMoveUp = onMoveUp
        view.onMoveDown = onMoveDown
        view.onConfirm = onConfirm
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyCaptureView else { return }
        view.onMoveUp = onMoveUp
        view.onMoveDown = onMoveDown
        view.onConfirm = onConfirm
        view.onCancel = onCancel
    }
}

private final class KeyCaptureView: NSView {
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 126: onMoveUp?()
        case 125: onMoveDown?()
        case 36, 76: onConfirm?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }
}
