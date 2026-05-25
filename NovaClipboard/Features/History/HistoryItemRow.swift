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
        HStack(alignment: .center, spacing: 10) {
            leadingVisual
                .frame(width: 36, height: 36)
                .liquidGlass(.regular, in: .roundedRect(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .lineLimit(2)
                    .font(item.type == .text ? .body : .body.monospaced())
                Text(Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)

            HStack(spacing: 4) {
                pinButton
                deleteButton
            }

            if let quickPasteIndex, quickPasteIndex < 9 {
                Text("⌘\(quickPasteIndex + 1)")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .liquidGlass(.regular, in: .capsule)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .liquidGlass(.tinted(.accentColor), in: .roundedRect(cornerRadius: 12))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Press return to paste")
    }

    @ViewBuilder
    private var pinButton: some View {
        if let onTogglePin {
            let shouldShow = item.isPinned || isHovered || isSelected
            Button(action: onTogglePin) {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.isPinned ? .orange : .secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background {
                if item.isPinned || isHovered {
                    Circle().fill(.clear).liquidGlass(.regular, in: .circle)
                }
            }
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background {
                if isHovered {
                    Circle().fill(.clear).liquidGlass(.regular, in: .circle)
                }
            }
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
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
