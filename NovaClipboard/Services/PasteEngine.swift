import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "io.creativeforce.NovaClipboard", category: "PasteEngine")

final class PasteEngine {
    func paste(item: ClipboardItem, toApp app: NSRunningApplication?) {
        logger.info("paste() called for item type=\(item.type.rawValue, privacy: .public), targetApp=\(app?.bundleIdentifier ?? "nil", privacy: .public)")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text, .richText, .link:
            guard let content = item.contentText else {
                logger.error("paste() aborted: contentText nil for text/link item")
                return
            }
            pasteboard.setString(content, forType: .string)

        case .image:
            guard let image = ImageStore.loadImage(blob: item.imageBlob, path: item.imagePath),
                  let tiff = image.tiffRepresentation else {
                logger.error("paste() aborted: image data missing")
                return
            }
            let pngType = NSPasteboard.PasteboardType("public.png")
            let tiffType = NSPasteboard.PasteboardType("public.tiff")
            pasteboard.setData(tiff, forType: tiffType)
            if let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                pasteboard.setData(png, forType: pngType)
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
