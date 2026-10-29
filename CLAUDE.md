# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & test

The Xcode project is generated from `project.yml` by **XcodeGen** — do not edit `NovaClipboard.xcodeproj` by hand. After adding/removing/renaming Swift files or changing build settings, regenerate:

```
xcodegen generate
```

Command-line build (no signing required):

```
xcodebuild -project NovaClipboard.xcodeproj -scheme NovaClipboard -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Run tests (the `NovaClipboardTests` target is linked into the app via `BUNDLE_LOADER`/`TEST_HOST`, so the app must build first):

```
xcodebuild -project NovaClipboard.xcodeproj -scheme NovaClipboard -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

Single test (Xcode test identifier `Target/Class/method`):

```
xcodebuild -project NovaClipboard.xcodeproj -scheme NovaClipboard -configuration Debug \
  -only-testing:NovaClipboardTests/HistoryStoreTests/testInsertDedupesByChecksum \
  CODE_SIGNING_ALLOWED=NO test
```

Re-signing caveat: macOS ties the Accessibility grant to the code signature, so switching signing teams between runs invalidates the permission and the menu-bar icon will fall back to the warning triangle until re-granted.

## Architecture

NovaClipboard is a single-target macOS 14+ menu-bar app (`LSUIElement: true`, no Dock icon). It is **not sandboxed** — there are no entitlements files and the app reads `~/Desktop` directly to ingest screenshots. SwiftData is the persistence layer; the store lives at `~/Library/Application Support/NovaClipboard/History.store` (`Utilities/HistoryStoreLocation.swift`), next to `ImageStore`'s `Images/`. Never fall back to the default `ModelConfiguration`: unsandboxed, it resolves to the shared `~/Library/Application Support/default.store` that any other SwiftData app can also open. Older builds used that file, and the first launch copies it over (`migrateLegacyStoreIfNeeded`, including the `.default_SUPPORT` external-blob folder), then `retireLegacyStoreIfSafe` moves the old store to the Trash — only if it holds nothing but NovaClipboard's tables/entities, the copy passes `quick_check`, item counts match across legacy, copy and the opened container, and every external blob was copied. Keep all of those checks; the file may belong to another app. A second launched instance quits immediately (`isAnotherInstanceRunning`) so two processes never write the same store. `HistoryStore` logs SwiftData errors and rolls back a failed save instead of swallowing it with `try?`. The status menu's **Export Diagnostics** item (`Utilities/DiagnosticsExporter.swift`) writes a `.txt` report to the Desktop — store/monitor/watcher state plus this process's own `OSLogStore` entries since launch — so it must be run *before* the user restarts the app. Log pasteboard types and source apps, never clipboard contents, so that report stays safe to share.

Bundle ID: `io.haunc.NovaClipboard`. Logging uses `os.Logger` with that subsystem and a per-file category.

### Composition root

`AppDelegate` (in `App/AppDelegate.swift`) is the only place where services are wired together. It owns the `ModelContainer`, `HistoryStore`, `ClipboardMonitor`, `ScreenshotWatcher`, `HotKeyManager`, `PanelController`, `PasteEngine`, and the retention/permission timers. Most of the app is `@MainActor`; cross-thread callbacks from monitors use `MainActor.assumeIsolated` to hop back to the main context before touching SwiftData.

`AppSettings.shared` (an `ObservableObject`) is observed via Combine `$` publishers in `setupSettingsBindings()` — changes to `hotKey`, `maxItems`, `retention`, and `captureScreenshots` flow through `.dropFirst().sink` to re-register the hotkey, resize history, run a retention sweep, or start/stop the screenshot watcher. **Do not call settings-applying methods directly from the UI** — mutate `AppSettings` and let the bindings react.

### Input pipelines

Two independent producers feed `HistoryStore.insert(_:)`:

1. **`ClipboardMonitor`** polls `NSPasteboard.general.changeCount` every 300ms. It bails on any "concealed" UTI (`org.nspasteboard.ConcealedType`, 1Password, LastPass — see the `concealedUTIs` set in `Services/ClipboardMonitor.swift`). Reads are prioritized **file URL → text → image → link**: spreadsheets put a rendered picture of the cells beside the text, so text beats an image, but a bare link (what a browser's "Copy Image" carries) does not; TIFF is converted to PNG on ingest so storage is uniform. URL detection is a tight heuristic (`isLikelyURL`) restricted to `http/https/ftp/mailto`.
2. **`ScreenshotWatcher`** uses FSEvents on the configured screenshot directory so `⌘⇧3/4/5` files land in history even when the screenshot didn't hit the pasteboard (e.g., when macOS's preview thumbnail is suppressed). Screenshot ingestion is in `AppDelegate.ingestScreenshot(at:)`, not in the watcher. `ScreenshotWatcher.isScreenshot` must not rely on the filename alone (macOS localizes it, e.g. "Bildschirmfoto …", and Spotlight rarely has indexed a new file yet); the language-independent check is the EXIF UserComment `Screenshot` that `screencapture` writes into every file.

`AppDelegate` filters by `settings.blocklistBundleIDs` *before* calling `historyStore.insert`. Anything written to `imagePath` for a blocked source is deleted there — the watcher/monitor write image files eagerly so the store can detect dedup, and rejected items must clean up.

### Storage & dedup

`ClipboardItem` (`@Model`, `Models/ClipboardItem.swift`) is the only SwiftData entity. Image bytes follow a two-tier scheme: blobs < `ImageStore.inlineLimitBytes` (128 KB) are stored inline via `@Attribute(.externalStorage) imageBlob`; larger ones spill to `imagePath` files written by `ImageStore`. **Both paths must stay in sync** — when an item is deleted, evicted, or dedup'd, call `ImageStore.deleteFile(at: item.imagePath)` and `ImageThumbnailCache.shared.invalidate(id:)`. `HistoryStore` does this in `delete`, `clearAll`, `evictOverflowIfNeeded`, and the dedup branch of `insert`.

Dedup is by SHA-256 over the content (text string, file-URL list joined by `\n`, or raw image bytes — see `Checksum.sha256` callers). The window is `HistoryStore.dedupWindow` — `max(50, limit)` most-recent items, so dedup covers the whole retained history; matches refresh `createdAt` instead of inserting a row. Pinned items are exempt from history-limit eviction (`evictOverflowIfNeeded` filters `!isPinned`) and from `clearAll(keepPinned: true)` and retention sweeps.

### Paste flow

`PasteEngine.paste(item:toApp:restoreClipboard:)` is the load-bearing path and the trickiest piece to modify:

1. **Snapshot** the current pasteboard via `PasteboardSnapshot` (captures every `NSPasteboardItem` with all declared types) — only when `restoreClipboard` is true.
2. Clear and rewrite the pasteboard with the history item's payload (text/image/file URLs).
3. Require `AXIsProcessTrusted()` — if missing, raise the Accessibility alert and abort.
4. Activate the target app (`PanelController.frontmostAppBeforeShow`, captured at `show()` before the panel stole focus).
5. After 80 ms, synthesize ⌘V via `CGEvent` on `.cghidEventTap`.
6. If restoring, after `PasteEngine.restoreDelay` (500 ms), restore the original pasteboard snapshot.

**Multi-select:** ⇧-click / ⇧↑↓ in the panel builds an ordered `multiSelection`; ↵ (or clicking a picked row) calls `paste(items:)`, which writes `ClipboardItem.combinedPasteboardItems` — text/links joined by `\n`, images/files as file URLs — for a single ⌘V. That payload is tagged `org.nspasteboard.TransientType`, which `ClipboardMonitor` skips, so the combination isn't recorded as a new history item. A text + image mix (no plain files) is instead one rich-text item (HTML with data-URI images, RTFD, plain text) so editors like Google Docs keep both. Dragging a picked row drags the whole selection.

`restoreClipboard` comes from `settings.restoreClipboardAfterPaste`, which is **off by default**: the pasted item stays on the clipboard so a second ⌘V elsewhere pastes the same item (what users of other clipboard managers expect). When the user turns it on, the restore lets them keep their in-progress copy — if you change the timing or skip the snapshot in that mode you break that contract. See Spec §3.3 in `.docs/spec.md` (step 5 is optional).

### Panel & hotkey

`HotKeyManager` registers a Carbon hotkey from `settings.hotKey` (`KeyCombo`). The handler calls `PanelController.toggle()`. A **left click** on the menu-bar icon calls `toggle(source: .statusItem(rect))` instead: the panel anchors under the icon and `PanelPresentation.openedFromStatusItem` adds a Settings icon button to the header (next to Clear). A **right/Control click** shows the classic `NSMenu` (`statusMenu`, attached only for that click). Because clicking the icon makes the open panel resign key and hide first, `toggle` ignores status-item clicks within `reopenSuppressInterval` of a hide. Rows can also be dragged out (`ClipboardItem.dragItemProvider()`); drags use their own pasteboard and don't touch history. **Space** toggles Quick Look for the selected row via `ItemPreviewController` (`HistoryPanel` takes `QLPreviewPanel` control through the responder chain): text/links are previewed from a temp `.txt`, inline images from a temp `.png`; Esc closes the preview before the panel, and `hide()` always closes it. `PanelController` builds an `NSPanel`, captures `NSWorkspace.shared.frontmostApplication` **before** showing (so paste can restore focus), and uses `PanelAnchorResolver` to position the panel at the caret (via AX APIs), mouse, or a fixed origin per `settings.panelPosition`. The panel hosts a SwiftUI `HistoryPanelView` through `NSHostingController`.

`HotKeyManager` also owns the **quick-paste** slots: digit keys 1–9 (`registerQuickPaste`) share a single Carbon event handler with the panel hotkey, dispatched by `EventHotKeyID.id` (panel is id `1`; quick-paste slots are `quickPasteBaseID + digit`). Quick-paste bypasses the panel entirely — `AppDelegate.quickPaste(index:)` fetches the Nth most-recent item and calls `pasteEngine.paste` directly against the frontmost app. Toggled by `settings.quickPasteEnabled` with a configurable modifier mask (`settings.quickPasteModifiers`, default ⌘⇧); both flow through `applyQuickPasteHotKeys()` via the settings bindings, not direct calls.

### Permissions

Accessibility is required for both ⌘V synthesis and caret detection. `AppDelegate.startPermissionMonitor` polls `AXIsProcessTrusted()` every 3 s and swaps the status-item SF Symbol (`doc.on.clipboard` ↔ `exclamationmark.triangle`). The onboarding window auto-shows only on the genuine first launch (`!settings.hasOnboarded`); a later revocation is surfaced by the warning icon, the conditional "Accessibility Permission" menu item, and an orange banner at the top of the history panel (`PanelPresentation.isAccessibilityTrusted`, refreshed on each `show` and by the same poll) that opens the same onboarding window.

Launch-at-login uses `SMAppService` via `Utilities/LaunchAtLogin.swift`; on first run the OS-level state is synced to match the in-app toggle so the UI cannot lie.

### Updates & localization

Auto-updates use **Sparkle** (SwiftPM dependency in `project.yml`). `Services/UpdateController.shared` wraps a single `SPUStandardUpdaterController`; the feed URL, EdDSA public key (`SUPublicEDKey`), and `SUEnableAutomaticChecks` live in `Info.plist`. CI overrides `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` from the git tag at archive time — local builds ship as `0.0.0-dev`.

The app is localized **en + vi** (`CFBundleLocalizations` in `Info.plist`). Strings live in a single `Resources/Localizable.xcstrings` String Catalog; use `String(localized:)` (already used in ~5 files) for new user-facing text so Xcode auto-extracts the key into the catalog.

### UI design layer

`Design/LiquidGlass.swift` provides the shared look: `.liquidGlass(...)` / `.liquidGlassContainer(...)` view modifiers and `LiquidGlassButtonStyle`. It uses the native SwiftUI `.glassEffect`/`Glass` APIs when available and falls back to a hand-rolled material background on older systems — prefer these helpers over ad-hoc backgrounds when styling panel/settings UI.

## Project layout

- `App/` — `NovaClipboardApp` (SwiftUI `@main`) and `AppDelegate` (the composition root).
- `Models/` — `ClipboardItem` (`@Model`), `AppSettings` (`UserDefaults`-backed `ObservableObject`), `KeyCombo`.
- `Services/` — pipelines and singletons listed above.
- `Features/` — SwiftUI views: `History/` (panel + row), `Settings/`, `Onboarding/`.
- `Design/` — `LiquidGlass` shared view modifiers and button style.
- `Utilities/` — `Checksum`, `ImageStore`, `HistoryStoreLocation`, `DiagnosticsExporter`, `FaviconCache`, `LaunchAtLogin`, `ScreenshotPreviewPreference`.
- `Resources/Info.plist` — note `LSUIElement: true`; the plist is hand-edited (`GENERATE_INFOPLIST_FILE: NO`). Also holds Sparkle (`SUFeedURL`, `SUPublicEDKey`) and `CFBundleLocalizations`.
- `Resources/Localizable.xcstrings` — String Catalog for en/vi UI strings.
- `.docs/` — `prd.md`, `spec.md`, `plan.md` define the product contract and section numbers referenced from code comments.
- `project.yml` — single source of truth for the Xcode project.
