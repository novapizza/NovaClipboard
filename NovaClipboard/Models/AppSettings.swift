import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import SwiftUI

enum RetentionPolicy: String, Codable, CaseIterable, Identifiable {
    case forever
    case days7
    case days30

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forever: return "Forever"
        case .days7: return "7 days"
        case .days30: return "30 days"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .forever: return nil
        case .days7: return 60 * 60 * 24 * 7
        case .days30: return 60 * 60 * 24 * 30
        }
    }
}

/// Single source-of-truth for user preferences. Backed by UserDefaults.
/// Published via Combine so SwiftUI views can observe; AppDelegate also subscribes to side-effects.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Password managers and keychain UIs preloaded on first launch (Spec §7.1).
    static let defaultBlocklistBundleIDs: [String] = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess"
    ]

    private let defaults: UserDefaults

    @Published var hotKey: KeyCombo {
        didSet { persistHotKey(hotKey) }
    }

    @Published var panelPosition: PanelPositionPreference {
        didSet { defaults.set(panelPosition.rawValue, forKey: Key.panelPosition.rawValue) }
    }

    @Published var fixedPanelOrigin: CGPoint {
        didSet {
            defaults.set(fixedPanelOrigin.x, forKey: Key.fixedX.rawValue)
            defaults.set(fixedPanelOrigin.y, forKey: Key.fixedY.rawValue)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin.rawValue)
            LaunchAtLogin.set(enabled: launchAtLogin)
        }
    }

    @Published var maxItems: Int {
        didSet { defaults.set(maxItems, forKey: Key.maxItems.rawValue) }
    }

    @Published var maxImageMB: Int {
        didSet { defaults.set(maxImageMB, forKey: Key.maxImageMB.rawValue) }
    }

    @Published var retention: RetentionPolicy {
        didSet { defaults.set(retention.rawValue, forKey: Key.retention.rawValue) }
    }

    @Published var ignorePasswordFields: Bool {
        didSet { defaults.set(ignorePasswordFields, forKey: Key.ignorePasswordFields.rawValue) }
    }

    @Published var captureScreenshots: Bool {
        didSet {
            defaults.set(captureScreenshots, forKey: Key.captureScreenshots.rawValue)
            // OS-level screenshot preview override is owned by NovaClipboard only while
            // both capture and our preview toggle are enabled. Release it when capture is
            // turned off, but never touch the key when the toggle is off — the user may
            // have set `com.apple.screencapture show-thumbnail` themselves.
            if disableScreenshotPreview {
                ScreenshotPreviewPreference.setDisabled(captureScreenshots)
            }
        }
    }

    /// When true, suppresses macOS' floating screenshot preview so the file lands on disk
    /// immediately. Backed by our own UserDefaults key and mirrored into
    /// `com.apple.screencapture show-thumbnail` (only while `captureScreenshots` is on).
    @Published var disableScreenshotPreview: Bool {
        didSet {
            defaults.set(disableScreenshotPreview, forKey: Key.disableScreenshotPreview.rawValue)
            if captureScreenshots {
                ScreenshotPreviewPreference.setDisabled(disableScreenshotPreview)
            }
        }
    }

    @Published var blocklistBundleIDs: [String] {
        didSet { defaults.set(blocklistBundleIDs, forKey: Key.blocklistBundleIDs.rawValue) }
    }

    @Published var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Key.hasOnboarded.rawValue) }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.hotKey = AppSettings.loadHotKey(defaults: defaults) ?? .defaultShowPanel
        self.panelPosition = (defaults.string(forKey: Key.panelPosition.rawValue)
            .flatMap(PanelPositionPreference.init(rawValue:))) ?? .atCaret
        self.fixedPanelOrigin = CGPoint(
            x: defaults.object(forKey: Key.fixedX.rawValue) as? CGFloat ?? 200,
            y: defaults.object(forKey: Key.fixedY.rawValue) as? CGFloat ?? 200
        )
        let storedLaunchAtLogin = defaults.object(forKey: Key.launchAtLogin.rawValue) as? Bool
        self.launchAtLogin = storedLaunchAtLogin ?? true
        self.maxItems = (defaults.object(forKey: Key.maxItems.rawValue) as? Int) ?? 50
        self.maxImageMB = (defaults.object(forKey: Key.maxImageMB.rawValue) as? Int) ?? 4
        self.retention = (defaults.string(forKey: Key.retention.rawValue)
            .flatMap(RetentionPolicy.init(rawValue:))) ?? .forever
        self.ignorePasswordFields = (defaults.object(forKey: Key.ignorePasswordFields.rawValue) as? Bool) ?? true
        self.captureScreenshots = (defaults.object(forKey: Key.captureScreenshots.rawValue) as? Bool) ?? true
        // Pick up the existing system value on first launch so the toggle reflects reality.
        self.disableScreenshotPreview = (defaults.object(forKey: Key.disableScreenshotPreview.rawValue) as? Bool)
            ?? ScreenshotPreviewPreference.isThumbnailDisabled()
        if let saved = defaults.array(forKey: Key.blocklistBundleIDs.rawValue) as? [String] {
            self.blocklistBundleIDs = saved
        } else {
            self.blocklistBundleIDs = AppSettings.defaultBlocklistBundleIDs
            defaults.set(AppSettings.defaultBlocklistBundleIDs, forKey: Key.blocklistBundleIDs.rawValue)
        }
        self.hasOnboarded = defaults.bool(forKey: Key.hasOnboarded.rawValue)

        // First launch: persist default-true and register the login item so
        // the OS-level state matches the UI (didSet doesn't fire during init).
        if storedLaunchAtLogin == nil {
            defaults.set(true, forKey: Key.launchAtLogin.rawValue)
            LaunchAtLogin.set(enabled: true)
        }
    }

    private func persistHotKey(_ combo: KeyCombo) {
        defaults.set(Int(combo.keyCode), forKey: Key.hotKeyCode.rawValue)
        defaults.set(Int(combo.modifiers), forKey: Key.hotKeyMods.rawValue)
    }

    private static func loadHotKey(defaults: UserDefaults) -> KeyCombo? {
        guard defaults.object(forKey: Key.hotKeyCode.rawValue) != nil,
              defaults.object(forKey: Key.hotKeyMods.rawValue) != nil else { return nil }
        let code = UInt32(defaults.integer(forKey: Key.hotKeyCode.rawValue))
        let mods = UInt32(defaults.integer(forKey: Key.hotKeyMods.rawValue))
        return KeyCombo(keyCode: code, modifiers: mods)
    }

    private enum Key: String {
        case hotKeyCode
        case hotKeyMods
        case panelPosition
        case fixedX
        case fixedY
        case launchAtLogin
        case maxItems
        case maxImageMB
        case retention
        case ignorePasswordFields
        case captureScreenshots
        case disableScreenshotPreview
        case blocklistBundleIDs
        case hasOnboarded
    }
}
