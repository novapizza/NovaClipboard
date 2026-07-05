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

NovaClipboard is a single-target macOS 14+ menu-bar app (`LSUIElement: true`, no Dock icon). It is **not sandboxed** — there are no entitlements files and the app reads `~/Desktop` directly to ingest screenshots. SwiftData is the persistence layer; the store lives under `~/Library/Containers/io.haunc.NovaClipboard/Data/Library/Application Support/` despite the lack of sandboxing because `SMAppService`/SwiftData still scope to the bundle ID.

Bundle ID: `io.haunc.NovaClipboard`. Logging uses `os.Logger` with that subsystem and a per-file category.

### Composition root

`AppDelegate` (in `App/AppDelegate.swift`) is the only place where services are wired together. It owns the `ModelContainer`, `HistoryStore`, `ClipboardMonitor`, `ScreenshotWatcher`, `HotKeyManager`, `PanelController`, `PasteEngine`, and the retention/permission timers. Most of the app is `@MainActor`; cross-thread callbacks from monitors use `MainActor.assumeIsolated` to hop back to the main context before touching SwiftData.

`AppSettings.shared` (an `ObservableObject`) is observed via Combine `$` publishers in `setupSettingsBindings()` — changes to `hotKey`, `maxItems`, `retention`, and `captureScreenshots` flow through `.dropFirst().sink` to re-register the hotkey, resize history, run a retention sweep, or start/stop the screenshot watcher. **Do not call settings-applying methods directly from the UI** — mutate `AppSettings` and let the bindings react.

### Input pipelines

Two independent producers feed `HistoryStore.insert(_:)`:

1. **`ClipboardMonitor`** polls `NSPasteboard.general.changeCount` every 300ms. It bails on any "concealed" UTI (`org.nspasteboard.ConcealedType`, 1Password, LastPass — see the `concealedUTIs` set in `Services/ClipboardMonitor.swift`). Reads are prioritized **file URL → image → text/link**; TIFF is converted to PNG on ingest so storage is uniform. URL detection is a tight heuristic (`isLikelyURL`) restricted to `http/https/ftp/mailto`.
2. **`ScreenshotWatcher`** uses FSEvents on the configured screenshot directory so `⌘⇧3/4/5` files land in history even when the screenshot didn't hit the pasteboard (e.g., when macOS's preview thumbnail is suppressed). Screenshot ingestion is in `AppDelegate.ingestScreenshot(at:)`, not in the watcher.

`AppDelegate` filters by `settings.blocklistBundleIDs` *before* calling `historyStore.insert`. Anything written to `imagePath` for a blocked source is deleted there — the watcher/monitor write image files eagerly so the store can detect dedup, and rejected items must clean up.

### Storage & dedup

`ClipboardItem` (`@Model`, `Models/ClipboardItem.swift`) is the only SwiftData entity. Image bytes follow a two-tier scheme: blobs < `ImageStore.inlineLimitBytes` (128 KB) are stored inline via `@Attribute(.externalStorage) imageBlob`; larger ones spill to `imagePath` files written by `ImageStore`. **Both paths must stay in sync** — when an item is deleted, evicted, or dedup'd, call `ImageStore.deleteFile(at: item.imagePath)` and `ImageThumbnailCache.shared.invalidate(id:)`. `HistoryStore` does this in `delete`, `clearAll`, `evictOverflowIfNeeded`, and the dedup branch of `insert`.

Dedup is by SHA-256 over the content (text string, file-URL list joined by `\n`, or raw image bytes — see `Checksum.sha256` callers). The window is `HistoryStore.dedupWindow` — `max(50, limit)` most-recent items, so dedup covers the whole retained history; matches refresh `createdAt` instead of inserting a row. Pinned items are exempt from history-limit eviction (`evictOverflowIfNeeded` filters `!isPinned`) and from `clearAll(keepPinned: true)` and retention sweeps.

### Paste flow

`PasteEngine.paste(item:toApp:)` is the load-bearing path and the trickiest piece to modify:

1. **Snapshot** the current pasteboard via `PasteboardSnapshot` (captures every `NSPasteboardItem` with all declared types).
2. Clear and rewrite the pasteboard with the history item's payload (text/image/file URLs).
3. Require `AXIsProcessTrusted()` — if missing, raise the Accessibility alert and abort.
4. Activate the target app (`PanelController.frontmostAppBeforeShow`, captured at `show()` before the panel stole focus).
5. After 80 ms, synthesize ⌘V via `CGEvent` on `.cghidEventTap`.
6. After `PasteEngine.restoreDelay` (500 ms), restore the original pasteboard snapshot.

The restore is what lets users keep their in-progress copy. If you change the timing or skip the snapshot you will break that contract — see Spec §3.3 in `.docs/spec.md`.

### Panel & hotkey

`HotKeyManager` registers a Carbon hotkey from `settings.hotKey` (`KeyCombo`). The handler calls `PanelController.toggle()`. `PanelController` builds an `NSPanel`, captures `NSWorkspace.shared.frontmostApplication` **before** showing (so paste can restore focus), and uses `PanelAnchorResolver` to position the panel at the caret (via AX APIs), mouse, or a fixed origin per `settings.panelPosition`. The panel hosts a SwiftUI `HistoryPanelView` through `NSHostingController`.

### Permissions

Accessibility is required for both ⌘V synthesis and caret detection. `AppDelegate.startPermissionMonitor` polls `AXIsProcessTrusted()` every 3 s and swaps the status-item SF Symbol (`doc.on.clipboard` ↔ `exclamationmark.triangle`). The onboarding window auto-shows only on the genuine first launch (`!settings.hasOnboarded`); a later revocation is surfaced by the warning icon and the conditional "Accessibility Permission…" menu item.

Launch-at-login uses `SMAppService` via `Utilities/LaunchAtLogin.swift`; on first run the OS-level state is synced to match the in-app toggle so the UI cannot lie.

## Project layout

- `App/` — `NovaClipboardApp` (SwiftUI `@main`) and `AppDelegate` (the composition root).
- `Models/` — `ClipboardItem` (`@Model`), `AppSettings` (`UserDefaults`-backed `ObservableObject`), `KeyCombo`.
- `Services/` — pipelines and singletons listed above.
- `Features/` — SwiftUI views: `History/` (panel + row), `Settings/`, `Onboarding/`.
- `Utilities/` — `Checksum`, `ImageStore`, `FaviconCache`, `LaunchAtLogin`, `ScreenshotPreviewPreference`.
- `Resources/Info.plist` — note `LSUIElement: true`; the plist is hand-edited (`GENERATE_INFOPLIST_FILE: NO`).
- `.docs/` — `prd.md`, `spec.md`, `plan.md` define the product contract and section numbers referenced from code comments.
- `project.yml` — single source of truth for the Xcode project.
