import SwiftUI

struct HistoryItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .lineLimit(2)
                    .font(.body)
                Text(Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        )
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch item.type {
        case .text, .richText: return "doc.text"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}
