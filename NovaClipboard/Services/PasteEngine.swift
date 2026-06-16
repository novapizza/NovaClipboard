import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "io.haunc.NovaClipboard", category: "PasteEngine")

final class PasteEngine {
    /// How long to wait after Cmd+V before restoring the original pasteboard.
    /// Long enough for the foreground app to consume the data, short enough that
    /// the user's clipboard isn't visibly hijacked. Spec §3.3.
    static let restoreDelay: TimeInterval = 0.5

    func paste(item: ClipboardItem, toApp app: NSRunningApplication?) {
        logger.info("paste() called for item type=\(item.type.rawValue, privacy: .public), targetApp=\(app?.bundleIdentifier ?? "nil", privacy: .public)")

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(capturing: pasteboard)
        pasteboard.clearContents()

        switch item.type {
        case .text, .richText, .link:
            guard let content = item.contentText else {
                logger.error("paste() aborted: contentText nil for text/link item")
                return
            }
            pasteboard.setString(content, forType: .string)

        case .image:
            // ClipboardMonitor + screenshot ingestion normalize image bytes to PNG before storage,
            // so write the stored bytes verbatim — re-encoding through TIFF wastes CPU and can be
            // lossy for some PNG color profiles.
            let pngData: Data?
            if let blob = item.imageBlob {
                pngData = blob
            } else if let path = item.imagePath {
                pngData = try? Data(contentsOf: URL(fileURLWithPath: path))
            } else {
                pngData = nil
            }
            guard let pngData else {
                logger.error("paste() aborted: image data missing")
                return
            }
            let pngType = NSPasteboard.PasteboardType("public.png")
            pasteboard.setData(pngData, forType: pngType)
            // Derive TIFF as a fallback for legacy apps that only accept it.
            if let rep = NSBitmapImageRep(data: pngData),
               let tiff = rep.tiffRepresentation {
                let tiffType = NSPasteboard.PasteboardType("public.tiff")
                pasteboard.setData(tiff, forType: tiffType)
            }

        case .file:
            guard let strings = item.fileURLs, !strings.isEmpty else {
                logger.error("paste() aborted: file URLs empty")
                return
            }
            let urls = strings.compactMap { URL(string: $0) }
            if !urls.isEmpty {
                pasteboard.writeObjects(urls as [NSURL])
            }
        }

        guard ensureAccessibilityTrusted() else {
            logger.error("paste() aborted: missing Accessibility permission")
            return
        }

        activate(app: app)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            logger.info("paste() posting Cmd+V")
            self.simulateCommandV()

            DispatchQueue.main.asyncAfter(deadline: .now() + PasteEngine.restoreDelay) {
                logger.info("paste() restoring original pasteboard contents")
                snapshot.restore(to: pasteboard)
            }
        }
    }

    private func activate(app: NSRunningApplication?) {
        guard let app else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func simulateCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func ensureAccessibilityTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }

        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([prompt: kCFBooleanTrue] as CFDictionary)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Accessibility permission required"
            alert.informativeText = """
            NovaClipboard needs Accessibility permission to paste into the active app.

            1. Open System Settings → Privacy & Security → Accessibility
            2. Remove any old NovaClipboard entry, then add this .app
            3. Enable the toggle and relaunch NovaClipboard
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        return false
    }
}

/// Captures every pasteboard item with all of its declared types so it can be
/// rewritten verbatim later. Used by `PasteEngine` to restore the user's
/// pre-existing clipboard contents after simulating Cmd+V.
struct PasteboardSnapshot {
    /// Skip restoring any single representation larger than this to avoid holding a multi-megabyte
    /// copy of e.g. a 50MB image in RAM for the 500ms paste window. The user keeps text/URLs
    /// (the usual "I'm in the middle of pasting something" use case); huge media may be lost.
    static let maxBytesPerType = 4 * 1_024 * 1_024

    private struct Entry {
        let types: [NSPasteboard.PasteboardType]
        let data: [NSPasteboard.PasteboardType: Data]
    }
    private let entries: [Entry]

    init(capturing pasteboard: NSPasteboard) {
        let items = pasteboard.pasteboardItems ?? []
        self.entries = items.map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types {
                if let d = item.data(forType: t), d.count <= PasteboardSnapshot.maxBytesPerType {
                    data[t] = d
                }
            }
            return Entry(types: item.types, data: data)
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let rebuilt: [NSPasteboardItem] = entries.map { entry in
            let item = NSPasteboardItem()
            for t in entry.types {
                if let d = entry.data[t] {
                    item.setData(d, forType: t)
                }
            }
            return item
        }
        if !rebuilt.isEmpty {
            pasteboard.writeObjects(rebuilt)
        }
    }
}
