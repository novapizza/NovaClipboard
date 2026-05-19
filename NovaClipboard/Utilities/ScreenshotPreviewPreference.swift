import Foundation
import os

private let prefLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "ScreenshotPreviewPreference")

/// Toggles the macOS screenshot preview thumbnail (the floating preview that delays
/// the file write to Desktop by ~5s). When disabled, `screencapture` writes the file
/// to disk immediately so our `ScreenshotWatcher` can pick it up.
///
/// Sets the `show-thumbnail` key under `com.apple.screencapture` and reloads
/// SystemUIServer so the screenshot daemon re-reads its preferences.
enum ScreenshotPreviewPreference {
    static let domain = "com.apple.screencapture"
    static let key = "show-thumbnail"

    /// `true` when the thumbnail has been explicitly disabled. macOS default (key unset) is "shown".
    static func isThumbnailDisabled() -> Bool {
        guard let defaults = UserDefaults(suiteName: domain) else { return false }
        guard defaults.object(forKey: key) != nil else { return false }
        return defaults.bool(forKey: key) == false
    }

    static func setDisabled(_ disabled: Bool) {
        guard let defaults = UserDefaults(suiteName: domain) else {
            prefLogger.error("Could not open com.apple.screencapture defaults")
            return
        }
        if disabled {
            defaults.set(false, forKey: key)
        } else {
            // Remove our override so macOS reverts to its built-in default (thumbnail shown).
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
        reloadScreenshotDaemon()
    }

    /// SystemUIServer hosts the screencapture preview agent. Killing it lets launchd
    /// respawn it with the fresh preference value.
    private static func reloadScreenshotDaemon() {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["SystemUIServer"]
        do {
            try task.run()
        } catch {
            prefLogger.error("Failed to reload SystemUIServer: \(error.localizedDescription, privacy: .public)")
        }
    }
}
