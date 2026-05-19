# NovaClipboard

A native macOS menu-bar clipboard manager. Press a hotkey, pick from your recent copies, paste into the active app — no dock icon, no servers, all data stays on your Mac.

> **v1 is local-only.** This repo currently builds and runs from Xcode for personal use. There is no signed distribution build, no notarization, no auto-updater, and no network calls. Distribution is planned as a separate phase.

## Features (v1)

- Menu-bar app (no Dock entry).
- Global hotkey to summon a history panel anchored next to your caret (or the mouse, in apps where Accessibility caret bounds are unreliable).
- Captures text, links, images, and file references from `NSPasteboard`.
- Search, type filters (Text / Image / Link), pinning, and `⌘1..⌘9` quick paste.
- Settings for hotkey, panel position, history limits, retention, blocked apps.
- Privacy: app source blocklist + concealed-type UTI filter — password managers and items marked `org.nspasteboard.ConcealedType` are skipped.
- Pasteboard restore: the previous clipboard contents are restored ~500ms after a paste so your in-progress copy is preserved.

## Default hotkey

`⌘ ⇧ V` — configurable in Settings → General.

In the panel:
- `↑` / `↓` move selection
- `↵` paste the selected item
- `⌘1..⌘9` quick-paste rows 1–9 of the Recent section
- `⌘F` focus search
- `⌘P` toggle pin
- `⌫` delete the selected item
- `Esc` or click outside dismisses the panel

## Build & run from Xcode

Requirements:
- macOS 13 Ventura or newer
- Xcode 15+ (Swift 5.10, SwiftUI, SwiftData)
- An Apple ID signed into Xcode (Personal Team is fine — no paid Developer Program needed)

Steps:
1. Open `NovaClipboard.xcodeproj` in Xcode.
2. Select the `NovaClipboard` scheme, target "My Mac".
3. `⌘R` to build and run. The clipboard icon should appear in the menu bar.

`⌘U` runs the unit and integration tests (`NovaClipboardTests`).

> **Keep the same signing team across rebuilds.** macOS ties Accessibility permission to the code signature. Switching teams (or removing/adding the cert) invalidates the grant and you will need to re-enable it.

## Granting Accessibility permission

The app needs Accessibility to (1) simulate `⌘V` into the active app, and (2) read caret bounds for panel placement.

1. On first launch, an onboarding window opens. Click **Open System Settings**.
2. In **Privacy & Security → Accessibility**, enable the toggle for `NovaClipboard.app`.
3. If you previously granted permission to an older build, remove that entry first, then add the freshly built `.app` (Xcode → Product → Show Build Folder in Finder).
4. Relaunch the app. The onboarding window closes automatically once the permission flips on.

If the menu-bar icon turns into a warning triangle, the permission was revoked — clicking the menu still works, but caret detection and paste will fall back gracefully.

## Data storage

- SwiftData store: `~/Library/Containers/io.creativeforce.NovaClipboard/Data/Library/Application Support/`
- Large image blobs (≥ 1 MB) are written as files under the same container, alongside the database.
- Nothing leaves the machine. The app has no `com.apple.security.network.client` entitlement.

To reset everything: quit NovaClipboard, delete the container above, and relaunch.

## Project layout

```
NovaClipboard/
  App/            NSApplicationDelegate, scene wiring
  Models/         SwiftData @Model types, AppSettings, KeyCombo
  Services/       ClipboardMonitor, HotKeyManager, PasteEngine,
                  PanelController, PanelAnchorResolver, HistoryStore
  Features/       History panel, Settings tabs, Onboarding
  Utilities/      Checksum, ImageStore, FaviconCache, LaunchAtLogin
NovaClipboardTests/   XCTest target
.docs/                PRD, Spec, Plan
```

## Status

See [`.docs/plan.md`](./.docs/plan.md) for the phased build plan and current checklist progress.
