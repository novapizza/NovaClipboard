import AppKit
import UniformTypeIdentifiers

extension ClipboardItem {
    /// Dragging items for dragging a history row out of the panel. Drags use their own
    /// pasteboard, so `NSPasteboard.general` (and therefore history order) is untouched.
    ///
    /// Data is written eagerly as concrete types (real file URLs, plain strings) rather
    /// than through SwiftUI's `NSItemProvider` bridge: that bridge exports files as file
    /// promises and text lazily, which Finder/TextEdit accept but web inputs and upload
    /// fields in browsers do not.
    func draggingItems() -> [NSDraggingItem] {
        switch type {
        case .text, .richText:
            let item = NSPasteboardItem()
            item.setString(contentText ?? preview, forType: .string)
            return [Self.draggingItem(item, image: Self.textDragImage(preview))]

        case .link:
            let text = contentText ?? preview
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            // Offer the URL too so browsers/Finder get a link, while chat boxes keep the text.
            if let url = URL(string: text) {
                item.setString(url.absoluteString, forType: .URL)
            }
            return [Self.draggingItem(item, image: Self.textDragImage(text))]

        case .image:
            guard let url = imageFileURL() else { return [] }
            let image = ImageStore.loadImage(blob: imageBlob, path: imagePath)
                .map { ImageThumbnailCache.makeThumbnail(image: $0, size: Self.dragImageSize) }
                ?? NSWorkspace.shared.icon(forFile: url.path)
            return [Self.draggingItem(url as NSURL, image: image)]

        case .file:
            return (fileURLs ?? [])
                .compactMap { URL(string: $0) }
                .map { Self.draggingItem($0 as NSURL, image: NSWorkspace.shared.icon(forFile: $0.path)) }
        }
    }

    /// Dragging items for several selected rows, in selection order. Same payload as a
    /// multi-item paste (see `combinedPasteboardItems`).
    static func draggingItems(for items: [ClipboardItem]) -> [NSDraggingItem] {
        if items.count == 1 { return items[0].draggingItems() }
        let combined = combinedPasteboardItems(items, markTransient: false)
        return combined.map { pbItem in
            let image: NSImage
            if let urlString = pbItem.string(forType: .fileURL), let url = URL(string: urlString) {
                image = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                image = textDragImage(pbItem.string(forType: .string) ?? "")
            }
            return draggingItem(pbItem, image: image)
        }
    }

    /// A mixed text + image selection travels as rich text (no file URLs), so it may be
    /// moved like text; anything carrying file URLs stays copy-only.
    static func dragOperationMask(for items: [ClipboardItem]) -> NSDragOperation {
        if isRichTextMix(items) { return [.copy, .move, .generic] }
        return items.reduce([.copy, .move, .generic]) { $0.intersection($1.dragOperationMask) }
    }

    /// One pasteboard payload for several items: text/links joined by newlines, images and
    /// files as file URLs. In a mixed selection the text rides on the first file item, so
    /// text-only targets still get it. A text + image mix (no plain files) is instead one
    /// rich-text item, because targets like Google Docs take only the files when offered
    /// both. `markTransient` tags the payload so clipboard managers (including our own
    /// `ClipboardMonitor`) don't record the combination.
    static func combinedPasteboardItems(_ items: [ClipboardItem], markTransient: Bool = true) -> [NSPasteboardItem] {
        var result = isRichTextMix(items) ? [richTextPasteboardItem(items)] : fileAndTextPasteboardItems(items)
        if markTransient {
            result.first?.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        return result
    }

    private static func isRichTextMix(_ items: [ClipboardItem]) -> Bool {
        let types = Set(items.map(\.type))
        return types.contains(.image)
            && !types.contains(.file)
            && !types.isDisjoint(with: [.text, .richText, .link])
    }

    /// Text and images interleaved in selection order as HTML (images inlined as data
    /// URIs, for web editors), RTFD (images as attachments, for Pages/Notes/TextEdit),
    /// and plain text as a last resort.
    private static func richTextPasteboardItem(_ items: [ClipboardItem]) -> NSPasteboardItem {
        var html = ""
        let attributed = NSMutableAttributedString()
        var plain: [String] = []
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        for item in items {
            if !attributed.string.isEmpty {
                attributed.append(NSAttributedString(string: "\n"))
            }
            switch item.type {
            case .text, .richText, .link:
                let text = item.contentText ?? item.preview
                plain.append(text)
                let escaped = htmlEscaped(text).replacingOccurrences(of: "\n", with: "<br>")
                if item.type == .link {
                    html += "<p><a href=\"\(htmlEscaped(text))\">\(escaped)</a></p>"
                } else {
                    html += "<p>\(escaped)</p>"
                }
                var attributes: [NSAttributedString.Key: Any] = [.font: bodyFont]
                if item.type == .link, let url = URL(string: text) {
                    attributes[.link] = url
                }
                attributed.append(NSAttributedString(string: text, attributes: attributes))
            case .image:
                guard let png = item.imagePNGData() else { continue }
                html += "<p><img src=\"data:image/png;base64,\(png.base64EncodedString())\"></p>"
                let attachment = NSTextAttachment(data: png, ofType: UTType.png.identifier)
                attributed.append(NSAttributedString(attachment: attachment))
            case .file:
                continue
            }
        }

        let pbItem = NSPasteboardItem()
        pbItem.setString("<meta charset=\"utf-8\">" + html, forType: .html)
        if let rtfd = attributed.rtfd(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) {
            pbItem.setData(rtfd, forType: .rtfd)
        }
        pbItem.setString(plain.joined(separator: "\n"), forType: .string)
        return pbItem
    }

    private static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func fileAndTextPasteboardItems(_ items: [ClipboardItem]) -> [NSPasteboardItem] {
        let text = items
            .filter { [.text, .richText, .link].contains($0.type) }
            .map { $0.contentText ?? $0.preview }
            .joined(separator: "\n")
        let urls: [URL] = items.flatMap { item -> [URL] in
            switch item.type {
            case .image: return item.imageFileURL().map { [$0] } ?? []
            case .file: return (item.fileURLs ?? []).compactMap { URL(string: $0) }
            case .text, .richText, .link: return []
            }
        }

        var result = urls.map { url -> NSPasteboardItem in
            let pbItem = NSPasteboardItem()
            pbItem.setString(url.absoluteString, forType: .fileURL)
            return pbItem
        }
        if !text.isEmpty {
            if let first = result.first {
                first.setString(text, forType: .string)
            } else {
                let pbItem = NSPasteboardItem()
                pbItem.setString(text, forType: .string)
                result = [pbItem]
            }
        }
        return result
    }

    /// Text must allow `.move`: Chrome (Blink) drops into editable fields as a move unless
    /// ⌥ is held, and rejects the drop when the source doesn't offer it. Nothing is removed
    /// from history on a move. Files must only ever be copied: a "generic"/move drop onto
    /// Finder on the same volume would move the user's original file.
    var dragOperationMask: NSDragOperation {
        switch type {
        case .text, .richText, .link: return [.copy, .move, .generic]
        case .image, .file: return .copy
        }
    }

    private static let dragImageSize = CGSize(width: 64, height: 64)

    private static func draggingItem(_ writer: NSPasteboardWriting, image: NSImage) -> NSDraggingItem {
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(NSRect(origin: .zero, size: image.size), contents: image)
        return item
    }

    /// Spilled images already live on disk; inline ones are written to a temp PNG so the
    /// drop target receives a real file.
    /// Stored PNG bytes, inline or spilled to disk by `ImageStore`.
    func imagePNGData() -> Data? {
        if let imageBlob { return imageBlob }
        if let imagePath { return try? Data(contentsOf: URL(fileURLWithPath: imagePath)) }
        return nil
    }

    func imageFileURL() -> URL? {
        if let imagePath { return URL(fileURLWithPath: imagePath) }
        guard let imageBlob else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaClipboard-Drag", isDirectory: true)
        let url = dir.appendingPathComponent("\(String(localized: "Image")) \(id.uuidString.prefix(8)).png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try imageBlob.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func textDragImage(_ text: String) -> NSImage {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let string = NSAttributedString(
            string: String(line.prefix(40)),
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        )
        let padding: CGFloat = 8
        let textSize = string.size()
        let size = CGSize(width: ceil(textSize.width) + padding * 2, height: ceil(textSize.height) + padding)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            string.draw(at: CGPoint(x: padding, y: padding / 2))
            return true
        }
    }
}
