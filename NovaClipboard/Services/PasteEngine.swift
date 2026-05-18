import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "io.creativeforce.NovaClipboard", category: "PasteEngine")

final class PasteEngine {
    func paste(item: ClipboardItem, toApp app: NSRunningApplication?) {
        logger.info("paste() called for item type=\(item.type.rawValue, privacy: .public), targetApp=\(app?.bundleIdentifier ?? "nil", privacy: .public)")

        guard let contentText = item.contentText else {
            logger.error("paste() aborted: contentText is nil")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(contentText, forType: .string)
        logger.info("paste() clipboard set with \(contentText.count) chars")

        let trusted = AXIsProcessTrusted()
        logger.info("paste() AXIsProcessTrusted=\(trusted, privacy: .public)")

        guard ensureAccessibilityTrusted() else {
            logger.error("paste() aborted: missing Accessibility permission")
            return
        }

        activate(app: app)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            logger.info("paste() posting Cmd+V to frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", privacy: .public)")
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
            alert.messageText = "Cần quyền Accessibility"
            alert.informativeText = """
            NovaClipboard cần quyền Accessibility để tự động dán nội dung vào app đang mở.

            1. Mở System Settings → Privacy & Security → Accessibility
            2. Xóa entry NovaClipboard cũ (nếu có), bấm dấu + để add lại đường dẫn .app mới
            3. Bật toggle, sau đó Quit & relaunch NovaClipboard
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Mở System Settings")
            alert.addButton(withTitle: "Để sau")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        return false
    }
}
