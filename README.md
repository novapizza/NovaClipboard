# NovaClipboard

A native macOS menu-bar clipboard manager. Press a hotkey, pick from your recent copies, paste into the active app — no Dock icon, no servers, all data stays on your Mac.

## Features

- Menu-bar app (no Dock entry, `LSUIElement`).
- Global hotkey to summon a history panel anchored next to your caret, the mouse, or a fixed position.
- Captures **text, rich text, links, images, and file references** from `NSPasteboard`.
- **Auto-captures screenshots from disk** — `⌘⇧3/4/5` files written to `~/Desktop` (or your configured screenshot location) flow into history via FSEvents, even when nothing lands on the clipboard.
- Optional "skip macOS preview thumbnail" toggle so screenshots land on disk immediately (toggles `com.apple.screencapture show-thumbnail`).
- Pinning, `⌘1..⌘9` quick paste, and hover-reveal row actions (pin / delete).
- Status-bar menu: Show History, Settings, Clear All (keep pinned), Quit.
- Settings for hotkey, panel position, history limits, image-size cap, retention (Forever / 7d / 30d), launch-at-login, blocked apps, screenshot capture.
- Privacy: app source blocklist (1Password, LastPass, Bitwarden, Keychain Access pre-seeded) and concealed-type UTI filter — items marked `org.nspasteboard.ConcealedType` are skipped.
- Pasteboard restore: previous clipboard contents are restored shortly after a paste so your in-progress copy is preserved.
- Dedup by SHA-256 checksum; large image blobs (≥ 1 MB) spill to disk under the app container.

## Default hotkey

`⌘ ⇧ V` — configurable in Settings → General.

In the panel:
- `↑` / `↓` move selection
- `↵` paste the selected item
- `⌘1..⌘9` quick-paste the first nine rows (pinned first, then recent)
- `⌘P` toggle pin on the selected item
- `⌫` delete the selected item
- `Esc` or click outside dismisses the panel

## Build & run from Xcode

Requirements:
- macOS 14 Sonoma or newer
- Xcode 15+ (Swift 5.10, SwiftUI, SwiftData)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (the Xcode project is generated from `project.yml`)
- An Apple ID signed into Xcode (Personal Team is fine — no paid Developer Program needed)

Steps:
1. Run `xcodegen generate` after pulling, or any time you add/remove Swift files.
2. Open `NovaClipboard.xcodeproj` in Xcode.
3. Select the `NovaClipboard` scheme, target "My Mac".
4. `⌘R` to build and run. The clipboard icon should appear in the menu bar.

`⌘U` runs the unit and integration tests (`NovaClipboardTests`).

For a quick command-line build without code signing:

```
xcodebuild -project NovaClipboard.xcodeproj -scheme NovaClipboard -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

> **Keep the same signing team across rebuilds.** macOS ties Accessibility permission to the code signature. Switching teams (or removing/adding the cert) invalidates the grant and you will need to re-enable it.

## Granting Accessibility permission

The app needs Accessibility to (1) simulate `⌘V` into the active app, and (2) read caret bounds for panel placement.

1. On first launch, an onboarding window opens. Click **Open System Settings**.
2. In **Privacy & Security → Accessibility**, enable the toggle for `NovaClipboard.app`.
3. If you previously granted permission to an older build, remove that entry first, then add the freshly built `.app` (Xcode → Product → Show Build Folder in Finder).
4. Relaunch the app. The onboarding window closes automatically once the permission flips on.

If the menu-bar icon turns into a warning triangle, the permission was revoked — clicking the menu still works, but caret detection and paste will fall back gracefully. The icon is re-checked every 3 seconds and flips back once permission is restored.

## Launch at login

Enabled by default on first run via `SMAppService`. The OS-level state is synced to match the toggle so the UI never lies about whether the login item is registered. Disable it in Settings → General if you'd rather start the app manually.

## Data storage

- SwiftData store: `~/Library/Containers/io.haunc.NovaClipboard/Data/Library/Application Support/`
- Large image blobs (≥ 1 MB) are written as files under the same container, alongside the database.
- Nothing leaves the machine. The app has no `com.apple.security.network.client` entitlement (favicons aside — see below).

To reset everything: quit NovaClipboard, delete the container above, and relaunch.

## Project layout

```
NovaClipboard/
  App/            NSApplicationDelegate, scene wiring
  Models/         SwiftData @Model types, AppSettings, KeyCombo
  Services/       ClipboardMonitor, ScreenshotWatcher, HotKeyManager,
                  PasteEngine, PanelController, PanelAnchorResolver, HistoryStore
  Features/       History panel (rows + panel view), Settings tabs, Onboarding
  Utilities/      Checksum, ImageStore, FaviconCache, LaunchAtLogin,
                  ScreenshotPreviewPreference
  Resources/      Info.plist, Assets.xcassets
NovaClipboardTests/   XCTest target
.docs/                PRD, Spec, Plan
project.yml           XcodeGen spec
```
