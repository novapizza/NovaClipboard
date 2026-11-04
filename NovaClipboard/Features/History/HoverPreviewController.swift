import AppKit
import ImageIO
import SwiftUI

/// Shows a card with an item's full content beside the history panel once the mouse has
/// rested on a row for `AppSettings.hoverPreviewDelay` — a lighter alternative to Space /
/// Quick Look for mouse users.
///
/// The card is its own window so it can sit outside the panel without covering the list.
/// It never takes key focus or mouse events: keystrokes keep going to the history panel, and
/// the card can't trip the panel's hide-on-resign-key. Any key press, click or scroll hides
/// it, so it never lingers over what the user is doing.
@MainActor
final class HoverPreviewController {
    static let cardWidth: CGFloat = 320
    /// Gap between the panel and the card.
    private static let gap: CGFloat = 8
    /// Moving between rows reports "no row" for a moment (exit before enter, or the spacing
    /// between rows); waiting this long before hiding keeps the card from flickering.
    private static let hideGrace: TimeInterval = 0.15

    /// The history panel the card sits beside.
    weak var hostWindow: NSWindow?
    /// True while something else owns the preview (Quick Look is open).
    var isSuppressed: () -> Bool = { false }
    /// What pasting the item would produce, when paste transforms change it.
    var transformResult: (ClipboardItem) -> PasteTransformer.Result? = { _ in nil }

    private let settings = AppSettings.shared
    private var window: NSPanel?
    private var hostingView: NSHostingView<HoverCardView>?
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var eventMonitor: Any?

    init() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.hide() }
            return event
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Called whenever the row under the mouse changes; nil when it left the rows.
    func hoverChanged(to item: ClipboardItem?) {
        showTimer?.invalidate()
        showTimer = nil

        guard let item else {
            guard hideTimer == nil, isVisible else { return }
            hideTimer = Timer.scheduledTimer(withTimeInterval: Self.hideGrace, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
            return
        }
        hideTimer?.invalidate()
        hideTimer = nil

        guard let delay = settings.hoverPreviewDelay.seconds, !isSuppressed() else {
            hide()
            return
        }
        // Once a card is up, moving to another row swaps it at once, like tooltips do.
        if isVisible {
            show(item)
            return
        }
        showTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show(item) }
        }
    }

    func hide() {
        showTimer?.invalidate()
        showTimer = nil
        hideTimer?.invalidate()
        hideTimer = nil
        window?.orderOut(nil)
    }

    // MARK: - Window

    private func show(_ item: ClipboardItem) {
        guard !item.isDeleted, item.modelContext != nil,
              let host = hostWindow, host.isVisible, !isSuppressed() else {
            hide()
            return
        }
        let window = self.window ?? makeWindow()
        guard let hostingView else { return }
        hostingView.rootView = HoverCardView(item: item, transform: transformResult(item))
        let size = hostingView.fittingSize
        window.setContentSize(size)
        window.setFrameOrigin(origin(for: size, beside: host))
        window.orderFrontRegardless()
    }

    /// Beside the panel on whichever side has room (right first), top edge near the pointer
    /// so the card lines up with the hovered row, kept on the panel's screen.
    private func origin(for size: CGSize, beside host: NSWindow) -> CGPoint {
        let panel = host.frame
        let visible = (host.screen ?? NSScreen.main)?.visibleFrame ?? panel

        var x = panel.maxX + Self.gap
        if x + size.width > visible.maxX {
            x = panel.minX - Self.gap - size.width
        }
        x = max(visible.minX, min(x, visible.maxX - size.width))

        let top = min(NSEvent.mouseLocation.y + 24, visible.maxY)
        let y = max(visible.minY, top - size.height)
        return CGPoint(x: x, y: y)
    }

    private func makeWindow() -> NSPanel {
        let hosting = NSHostingView(rootView: HoverCardView(item: nil, transform: nil))
        let panel = HoverCardWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: Self.cardWidth, height: 100)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        // Above the `.floating` history panel.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let radius = PanelController.cornerRadius
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.wantsLayer = true
            glass.layer?.cornerRadius = radius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            glass.contentView = hosting
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = radius
            effect.layer?.masksToBounds = true
            hosting.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            panel.contentView = effect
        }
        window = panel
        hostingView = hosting
        return panel
    }
}

private final class HoverCardWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Card

struct HoverCardView: View {
    let item: ClipboardItem?
    let transform: PasteTransformer.Result?

    /// Text beyond this is never shown (the card caps its lines anyway); it keeps layout
    /// cheap for huge clipboard text.
    private static let textLimit = 4000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item {
                content(for: item)
                if let transform {
                    transformSection(transform)
                }
                Divider()
                footer(for: item)
            }
        }
        .padding(12)
        .frame(width: HoverPreviewController.cardWidth, alignment: .leading)
    }

    @ViewBuilder
    private func content(for item: ClipboardItem) -> some View {
        switch item.type {
        case .text, .richText:
            let text = item.contentText ?? item.preview
            Text(String(text.prefix(Self.textLimit)))
                .font(item.type == .text ? .callout : .callout.monospaced())
                .lineLimit(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.textStats(text))
                .font(.caption)
                .foregroundStyle(.secondary)

        case .link:
            let url = item.contentText ?? item.preview
            Text(url)
                .font(.callout.monospaced())
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let host = URL(string: url)?.host() {
                Text(host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .image:
            HoverImageView(item: item)

        case .file:
            HoverFileList(urls: (item.fileURLs ?? []).compactMap { URL(string: $0) })
        }
    }

    private func transformSection(_ transform: PasteTransformer.Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Label(String(localized: "Pastes as"), systemImage: "wand.and.stars")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(String(transform.text.prefix(Self.textLimit)))
                .font(.callout.monospaced())
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "\(transform.appliedRules.joined(separator: ", ")) · ⌥↵ pastes the original"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func footer(for item: ClipboardItem) -> some View {
        HStack(spacing: 6) {
            if let app = SourceApp(bundleID: item.sourceBundleID) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 14, height: 14)
                Text(app.name)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private static func textStats(_ text: String) -> String {
        let characters = String(localized: "\(text.count) characters")
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        guard lines > 1 else { return characters }
        return characters + " · " + String(localized: "\(lines) lines")
    }
}

private struct SourceApp {
    let name: String
    let icon: NSImage

    init?(bundleID: String?) {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        icon = NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// The image scaled to fit the card, with its pixel size and file size. The pixel size comes
/// from the image header so the card's size is known before the image itself has loaded.
private struct HoverImageView: View {
    let item: ClipboardItem
    @State private var image: NSImage?

    private static let maxSize = CGSize(width: HoverPreviewController.cardWidth - 24, height: 240)

    var body: some View {
        let info = ImageInfo(item: item)
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image {
                    Image(nsImage: image).resizable()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: info.displaySize(fitting: Self.maxSize).width,
                   height: info.displaySize(fitting: Self.maxSize).height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(maxWidth: .infinity)

            Text(info.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: item.id) {
            let path = item.imagePath
            let blob = item.imageBlob
            let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                if let path { return NSImage(contentsOfFile: path) }
                return blob.flatMap { NSImage(data: $0) }
            }.value
            if !Task.isCancelled { image = loaded }
        }
    }
}

private struct ImageInfo {
    var pixelSize: CGSize?
    var byteCount: Int?

    init(item: ClipboardItem) {
        let source: CGImageSource?
        if let path = item.imagePath {
            source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
            byteCount = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        } else if let blob = item.imageBlob {
            source = CGImageSourceCreateWithData(blob as CFData, nil)
            byteCount = blob.count
        } else {
            source = nil
        }
        if let source,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0 {
            pixelSize = CGSize(width: width, height: height)
        }
    }

    func displaySize(fitting box: CGSize) -> CGSize {
        guard let pixelSize else { return CGSize(width: box.width, height: box.height / 2) }
        let scale = min(1, box.width / pixelSize.width, box.height / pixelSize.height)
        return CGSize(width: max(1, pixelSize.width * scale), height: max(1, pixelSize.height * scale))
    }

    var description: String {
        var parts: [String] = []
        if let pixelSize {
            parts.append("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
        }
        if let byteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

private struct HoverFileList: View {
    let urls: [URL]
    private static let maxShown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(urls.prefix(Self.maxShown), id: \.self) { url in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if urls.count > Self.maxShown {
                Text(String(localized: "+\(urls.count - Self.maxShown) more"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
