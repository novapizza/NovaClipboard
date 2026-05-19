import SwiftUI
import AppKit

struct HistoryItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    var quickPasteIndex: Int?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leadingVisual
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                if item.isPinned {
                    HStack(spacing: 4) {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(item.preview)
                            .lineLimit(2)
                            .font(item.type == .text ? .body : .body.monospaced())
                    }
                } else {
                    Text(item.preview)
                        .lineLimit(2)
                        .font(item.type == .text ? .body : .body.monospaced())
                }

                Text(Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)

            if let quickPasteIndex, quickPasteIndex < 9 {
                Text("⌘\(quickPasteIndex + 1)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
                    )
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leadingVisual: some View {
        switch item.type {
        case .image:
            if let thumb = ImageThumbnailCache.shared.thumbnail(for: item) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                fallbackIcon
            }
        case .file:
            if let firstURL = item.fileURLs?.first,
               let url = URL(string: firstURL) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
            } else {
                fallbackIcon
            }
        case .link, .text, .richText:
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
    }

    private var iconName: String {
        switch item.type {
        case .text, .richText: return "doc.text"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}
