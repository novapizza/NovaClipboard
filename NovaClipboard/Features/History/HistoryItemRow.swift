import SwiftUI
import AppKit
import QuickLookThumbnailing

struct HistoryItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    /// Position in the ⇧ multi-selection (0-based); shown as a numbered badge.
    var multiSelectIndex: Int? = nil
    var quickPasteIndex: Int?
    /// Modifier symbol prefix for the quick-paste badge (e.g. `⌥⌘`). When nil/empty the badge is hidden.
    var quickPasteSymbols: String? = nil
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
                .liquidGlassContent(.regular, in: .roundedRect(cornerRadius: 9))
                .overlay(alignment: .topLeading) { multiSelectBadge }

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

            if let quickPasteIndex, quickPasteIndex < 9,
               let quickPasteSymbols, !quickPasteSymbols.isEmpty {
                Text("\(quickPasteSymbols)\(quickPasteIndex + 1)")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .liquidGlassContent(.regular, in: .capsule)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background {
            if multiSelectIndex != nil {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(isSelected ? 0.22 : 0.12))
                    )
            } else if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .liquidGlassContent(.tinted(.accentColor), in: .roundedRect(cornerRadius: 12))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isSelected)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: multiSelectIndex)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected || multiSelectIndex != nil ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Press return to paste")
    }

    @ViewBuilder
    private var multiSelectBadge: some View {
        if let multiSelectIndex {
            Text("\(multiSelectIndex + 1)")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
                .frame(minWidth: 18, minHeight: 18)
                .padding(.horizontal, multiSelectIndex >= 9 ? 3 : 0)
                .background(Capsule().fill(Color.accentColor))
                .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .offset(x: -6, y: -6)
                .transition(.scale.combined(with: .opacity))
        }
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
                    Circle().fill(.clear).liquidGlassContent(.regular, in: .circle)
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
                    Circle().fill(.clear).liquidGlassContent(.regular, in: .circle)
                }
            }
            .opacity(shouldShow ? 1 : 0)
            .accessibilityLabel("Delete item")
            .help("Delete")
        }
    }

    private var accessibilityDescription: String {
        let relative = Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date())
        let pin = item.isPinned ? String(localized: "Pinned. ") : ""
        let kind: String
        switch item.type {
        case .text, .richText: kind = String(localized: "Text")
        case .link: kind = String(localized: "Link")
        case .image: kind = String(localized: "Image")
        case .file: kind = String(localized: "File")
        }
        let picked = multiSelectIndex.map { String(localized: "Selected \($0 + 1). ") } ?? ""
        return picked + String(localized: "\(pin)\(kind). \(item.preview). Copied \(relative).")
    }

    @ViewBuilder
    private var leadingVisual: some View {
        switch item.type {
        case .image:
            ThumbnailView(item: item, fallback: fallbackIcon)
        case .file:
            if let firstURL = item.fileURLs?.first,
               let url = URL(string: firstURL) {
                FileThumbnailView(url: url)
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

/// Async-loading thumbnail that avoids blocking the main thread during scroll on cache miss.
private struct ThumbnailView<Fallback: View>: View {
    let item: ClipboardItem
    let fallback: Fallback
    @State private var thumb: NSImage?

    var body: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                fallback
            }
        }
        .task(id: item.id) {
            if let cached = ImageThumbnailCache.shared.cached(for: item) {
                thumb = cached
                return
            }
            let loaded = await ImageThumbnailCache.shared.loadThumbnail(for: item)
            if !Task.isCancelled {
                thumb = loaded
            }
        }
    }
}

/// Content thumbnail for a copied file (images incl. HEIC, videos, PDFs…) via Quick Look,
/// like Finder. Falls back to the file-type icon when Quick Look has no thumbnail.
private struct FileThumbnailView: View {
    let url: URL
    @State private var thumb: NSImage?

    private static let cache = NSCache<NSURL, NSImage>()
    private static let side: CGFloat = 36

    var body: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
            }
        }
        .task(id: url) {
            if let cached = Self.cache.object(forKey: url as NSURL) {
                thumb = cached
                return
            }
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: Self.side, height: Self.side),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                representationTypes: .thumbnail
            )
            guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
                  !Task.isCancelled else { return }
            Self.cache.setObject(rep.nsImage, forKey: url as NSURL)
            thumb = rep.nsImage
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
