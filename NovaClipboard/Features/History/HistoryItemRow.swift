import SwiftUI
import AppKit

struct HistoryItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    var quickPasteIndex: Int?
    var onTogglePin: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovered: Bool = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        if !item.isSafeToAccess {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 10) {
                leadingVisual
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.preview)
                        .lineLimit(2)
                        .font(item.type == .text ? .body : .body.monospaced())
                }
                Spacer(minLength: 0)

                pinButton
                deleteButton

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
            .onHover { isHovered = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            .accessibilityHint("Press return to paste")
        }
    }

    @ViewBuilder
    private var pinButton: some View {
        if let onTogglePin {
            let shouldShow = item.isPinned || isHovered || isSelected
            Button(action: onTogglePin) {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .font(.caption)
                    .foregroundStyle(item.isPinned ? .orange : .secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(shouldShow ? 1 : 0)
            .accessibilityLabel(item.isPinned ? "Unpin item" : "Pin item")
            .help(item.isPinned ? "Unpin" : "Pin")
        }
    }

    @ViewBuilder
    private var deleteButton: some View {
        if let onDelete {
            let shouldShow = isHovered || isSelected
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(shouldShow ? 1 : 0)
            .accessibilityLabel("Delete item")
            .help("Delete")
        }
    }

    private var accessibilityDescription: String {
        let relative = Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date())
        let pin = item.isPinned ? "Pinned. " : ""
        let kind: String
        switch item.type {
        case .text, .richText: kind = "Text"
        case .link: kind = "Link"
        case .image: kind = "Image"
        case .file: kind = "File"
        }
        return "\(pin)\(kind). \(item.preview). Copied \(relative)."
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
        case .link:
            LinkIconView(urlString: item.contentText ?? item.preview)
        case .text, .richText:
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

private struct LinkIconView: View {
    let urlString: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "link")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
        }
        .task(id: urlString) {
            if let cached = FaviconCache.shared.cached(for: urlString) {
                image = cached
                return
            }
            let fetched = await FaviconCache.shared.favicon(for: urlString)
            if !Task.isCancelled {
                image = fetched
            }
        }
    }
}
