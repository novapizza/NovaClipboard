import Foundation
import os

private let prefLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "ScreenshotPreviewPreference")

/// Toggles the macOS screenshot preview thumbnail (the floating preview that delays
/// the file write to Desktop by ~5s). When disabled, `screencapture` writes the file
/// to disk immediately so our `ScreenshotWatcher` can pick it up.
///
/// Writes the `show-thumbnail` key under `com.apple.screencapture`. The new value
/// is picked up by the screencapture process on its next launch (each ⌘⇧3/4/5
/// invocation spawns a fresh process), so a daemon restart isn't required.
enum ScreenshotPreviewPreference {
    static let domain = "com.apple.screencapture"
    static let key = "show-thumbnail"

    /// `true` when the thumbnail has been explicitly disabled. macOS default (key unset) is "shown".
    static func isThumbnailDisabled() -> Bool {
        let appID = domain as CFString
        guard let value = CFPreferencesCopyAppValue(key as CFString, appID) else { return false }
        if let boolRef = value as? Bool {
            return boolRef == false
        }
        return false
    }

    static func setDisabled(_ disabled: Bool) {
        let appID = domain as CFString
        let keyRef = key as CFString
        if disabled {
            CFPreferencesSetAppValue(keyRef, kCFBooleanFalse, appID)
        } else {
            // Remove our override so macOS reverts to its built-in default (thumbnail shown).
            CFPreferencesSetAppValue(keyRef, nil, appID)
        }
        if !CFPreferencesAppSynchronize(appID) {
            prefLogger.error("Failed to synchronize com.apple.screencapture preferences")
        }
    }
}
