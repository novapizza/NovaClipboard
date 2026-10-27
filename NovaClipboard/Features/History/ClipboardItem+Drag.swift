import AppKit
import UniformTypeIdentifiers

extension ClipboardItem {
    /// Payload for dragging a history row out of the panel. Drags use their own
    /// pasteboard, so `NSPasteboard.general` (and therefore history order) is untouched.
    func dragItemProvider() -> NSItemProvider {
        switch type {
        case .text, .richText:
            return NSItemProvider(object: (contentText ?? preview) as NSString)

        case .link:
            let text = contentText ?? preview
            let provider = NSItemProvider(object: text as NSString)
            // Offer the URL too so browsers/Finder get a link, while chat boxes keep the text.
            if let url = URL(string: text) {
                provider.registerObject(url as NSURL, visibility: .all)
            }
            return provider

        case .image:
            let provider = NSItemProvider()
            guard let png = imageData() else { return provider }
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                completion(png, nil)
                return nil
            }
            // A file representation lets Finder and upload-style drop targets accept the image.
            provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { [imagePath, id] completion in
                if let imagePath {
                    completion(URL(fileURLWithPath: imagePath), false, nil)
                    return nil
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaClipboard-\(id.uuidString).png")
                do {
                    try png.write(to: url, options: .atomic)
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
                return nil
            }
            provider.suggestedName = "Image"
            return provider

        case .file:
            // SwiftUI `onDrag` carries a single provider, so a multi-file item drags its first file.
            guard let first = fileURLs?.compactMap({ URL(string: $0) }).first,
                  let provider = NSItemProvider(contentsOf: first) else {
                return NSItemProvider(object: preview as NSString)
            }
            return provider
        }
    }

    /// Stored PNG bytes, inline or spilled to disk by `ImageStore`.
    private func imageData() -> Data? {
        if let imageBlob { return imageBlob }
        if let imagePath { return try? Data(contentsOf: URL(fileURLWithPath: imagePath)) }
        return nil
    }
}
