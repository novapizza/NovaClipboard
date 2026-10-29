import AppKit
import Carbon.HIToolbox
import Combine
import SwiftData
import SwiftUI
import os

private let appLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let settings = AppSettings.shared
    private var statusItem: NSStatusItem?
    /// Shown on right-click (or Control-click) only; a left click opens the history panel.
    private var statusMenu: NSMenu?
    private var modelContainer: ModelContainer?
    private var historyStore: HistoryStore?
    private var clipboardMonitor: ClipboardMonitor?
    private var screenshotWatcher: ScreenshotWatcher?
    private let hotKeyManager = HotKeyManager()
    private let anchorResolver = PanelAnchorResolver()
    private let pasteEngine = PasteEngine()
    private var panelController: PanelController?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var retentionTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var permissionMonitorTimer: Timer?
    private var accessibilityMenuItem: NSMenuItem?
    private let updateController = UpdateController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLogger.info("NovaClipboard launching, phase-2 build")
        if isAnotherInstanceRunning() {
            appLogger.error("Another NovaClipboard instance is already running; quitting")
            NSApp.terminate(nil)
            return
        }
        setupModelContainer()
        setupStatusItem()
        setupPanelController()
        setupClipboardMonitor()
        setupScreenshotWatcher()
        setupSettingsBindings()
        applyHotKey()
        applyQuickPasteHotKeys()
        applyHistoryLimit()
        startRetentionSweep()
        startPermissionMonitor()

        // Only auto-present the welcome window on the genuine first launch.
        // If Accessibility is revoked or invalidated later (e.g. signature change after rebuild
        // or auto-update), surface it via the menu-bar warning icon plus the conditional
        // "Accessibility Permission" menu item instead of popping a modal each launch.
        if !settings.hasOnboarded {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        screenshotWatcher?.stop()
        hotKeyManager.unregister()
        retentionTimer?.invalidate()
        permissionMonitorTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupModelContainer() {
        let schema = Schema([ClipboardItem.self])
        let migrated = HistoryStoreLocation.migrateLegacyStoreIfNeeded()
        do {
            let container: ModelContainer
            do {
                container = try Self.makeContainer(schema: schema)
                // Free the old shared store only once the copy opened, and before anything
                // writes to the new one, so the item counts can still be compared.
                if migrated, let opened = try? container.mainContext.fetchCount(FetchDescriptor<ClipboardItem>()) {
                    HistoryStoreLocation.retireLegacyStoreIfSafe(openedItemCount: opened)
                }
            } catch where migrated {
                // The shared default.store may hold another app's schema; start fresh
                // rather than refusing to launch.
                appLogger.error("Copied legacy store did not open, starting empty: \(String(describing: error), privacy: .public)")
                HistoryStoreLocation.removeStore()
                container = try Self.makeContainer(schema: schema)
            }
            modelContainer = container
            historyStore = HistoryStore(context: container.mainContext, limit: settings.maxItems)
        } catch {
            appLogger.error("Failed to create ModelContainer: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(localized: "NovaClipboard cannot start")
            alert.informativeText = String(localized: "The clipboard database could not be opened.\n\n\(error.localizedDescription)\n\nThe app will now quit.")
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private static func makeContainer(schema: Schema) throws -> ModelContainer {
        let config = ModelConfiguration(schema: schema, url: HistoryStoreLocation.url)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Two copies writing one SQLite store can corrupt it (e.g. relaunching from Spotlight
    /// while an older copy still runs in the menu bar), so a second launch quits.
    private func isAnotherInstanceRunning() -> Bool {
        // Unit tests run inside the app (TEST_HOST) and must not quit when the installed app is open.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let bundleID = Bundle.main.bundleIdentifier else { return false }
        let current = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            updateStatusIcon(button: button)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(title: String(localized: "Show History"), action: #selector(togglePanel), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(title: String(localized: "Settings"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(
            title: String(localized: "Check for Updates"),
            action: #selector(UpdateController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updateController
        menu.addItem(updateItem)

        let diagnosticsItem = NSMenuItem(
            title: String(localized: "Export Diagnostics"),
            action: #selector(exportDiagnostics),
            keyEquivalent: ""
        )
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)

        let permissionItem = NSMenuItem(
            title: String(localized: "Accessibility Permission"),
            action: #selector(openAccessibilityPermission),
            keyEquivalent: ""
        )
        permissionItem.target = self
        permissionItem.isHidden = AXIsProcessTrusted()
        menu.addItem(permissionItem)
        accessibilityMenuItem = permissionItem

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: String(localized: "Clear All"), action: #selector(clearAll), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // macOS 27 auto-adds symbols to some items (e.g. a gear for Settings); hide them so
        // every action in this menu looks the same.
        if #available(macOS 27.0, *) {
            for menuItem in menu.items {
                menuItem.preferredImageVisibility = .hidden
            }
        }
        statusMenu = menu

        statusItem = item
    }

    private func updateStatusIcon(button: NSStatusBarButton) {
        let trusted = AXIsProcessTrusted()
        let symbolName = trusted ? "doc.on.clipboard" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "NovaClipboard")
        image?.isTemplate = trusted
        button.image = image
        accessibilityMenuItem?.isHidden = trusted
        panelController?.presentation.isAccessibilityTrusted = trusted
    }

    private func setupPanelController() {
        guard let modelContainer, let historyStore else { return }
        panelController = PanelController(
            modelContainer: modelContainer,
            historyStore: historyStore,
            anchorResolver: anchorResolver,
            settings: settings,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onOpenAccessibility: { [weak self] in self?.openAccessibilityPermission() },
            onPaste: { [weak self] items in
                guard let self else { return }
                let target = self.panelController?.frontmostAppBeforeShow
                appLogger.info("AppDelegate.onPaste fired, target=\(target?.bundleIdentifier ?? "nil", privacy: .public)")
                self.pasteEngine.paste(
                    items: items,
                    toApp: target,
                    restoreClipboard: self.settings.restoreClipboardAfterPaste
                )
            }
        )
    }

    private func setupClipboardMonitor() {
        let monitor = ClipboardMonitor()
        monitor.onNewItem = { [weak self] item in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Filter by privacy blocklist
                if let src = item.sourceBundleID,
                   self.settings.blocklistBundleIDs.contains(src) {
                    appLogger.info("Skipping item from blocked bundle: \(src, privacy: .public)")
                    ImageStore.deleteFile(at: item.imagePath)
                    return
                }
                self.historyStore?.insert(item)
            }
        }
        monitor.start()
        clipboardMonitor = monitor
    }

    private func setupScreenshotWatcher() {
        let watcher = ScreenshotWatcher()
        watcher.onScreenshot = { [weak self] url in
            MainActor.assumeIsolated {
                self?.ingestScreenshot(at: url)
            }
        }
        screenshotWatcher = watcher
        if settings.captureScreenshots {
            watcher.start()
        }
    }

    private func ingestScreenshot(at url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            appLogger.error("Could not read screenshot data at \(url.path, privacy: .public)")
            return
        }

        // Cap by the same MB limit users set for clipboard images.
        let limitBytes = settings.maxImageMB * 1_024 * 1_024
        guard data.count <= limitBytes else {
            appLogger.info("Skipping screenshot, exceeds maxImageMB limit")
            return
        }

        // Normalize to PNG (screenshots are PNG by default, but be defensive).
        let pngData: Data
        if let rep = NSBitmapImageRep(data: data),
           let normalized = rep.representation(using: .png, properties: [:]) {
            pngData = normalized
        } else {
            pngData = data
        }

        let id = UUID()
        let inline = pngData.count < ImageStore.inlineLimitBytes
        let path = inline ? nil : ImageStore.write(data: pngData, id: id)

        let sizeKB = Double(pngData.count) / 1024.0
        let preview = sizeKB < 1024
            ? String(format: String(localized: "Screenshot · %.0f KB"), sizeKB)
            : String(format: String(localized: "Screenshot · %.1f MB"), sizeKB / 1024.0)

        let item = ClipboardItem(
            id: id,
            type: .image,
            preview: preview,
            imageBlob: inline ? pngData : nil,
            imagePath: path,
            sourceBundleID: "com.apple.screencapture",
            checksum: Checksum.sha256(pngData)
        )

        historyStore?.insert(item)
        appLogger.info("Inserted screenshot into history: \(url.lastPathComponent, privacy: .public)")

        // macOS's ⌘⇧3/4/5 write the screenshot to a file, never to the pasteboard, so ⌘V
        // can't paste what was just captured. Mirror it onto the clipboard here so the user
        // can paste immediately. `ClipboardMonitor` will re-detect this write, but dedup by
        // checksum collapses it back onto the row we just inserted.
        if settings.copyScreenshotToClipboard {
            copyImageToClipboard(pngData)
        }
    }

    /// Writes PNG (plus a TIFF fallback for legacy consumers) onto the general pasteboard.
    private func copyImageToClipboard(_ pngData: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: NSPasteboard.PasteboardType("public.png"))
        if let rep = NSBitmapImageRep(data: pngData),
           let tiff = rep.tiffRepresentation {
            pasteboard.setData(tiff, forType: NSPasteboard.PasteboardType("public.tiff"))
        }
    }

    private func setupSettingsBindings() {
        settings.$hotKey
            .dropFirst()
            .sink { [weak self] _ in self?.applyHotKey() }
            .store(in: &cancellables)

        settings.$maxItems
            .dropFirst()
            .sink { [weak self] _ in self?.applyHistoryLimit() }
            .store(in: &cancellables)

        settings.$retention
            .dropFirst()
            .sink { [weak self] _ in self?.runRetentionSweep() }
            .store(in: &cancellables)

        settings.$quickPasteEnabled
            .dropFirst()
            .sink { [weak self] _ in self?.applyQuickPasteHotKeys() }
            .store(in: &cancellables)

        settings.$quickPasteModifiers
            .dropFirst()
            .sink { [weak self] _ in self?.applyQuickPasteHotKeys() }
            .store(in: &cancellables)

        settings.$captureScreenshots
            .dropFirst()
            .sink { [weak self] enabled in
                if enabled {
                    self?.screenshotWatcher?.start()
                } else {
                    self?.screenshotWatcher?.stop()
                }
            }
            .store(in: &cancellables)
    }

    private func applyHotKey() {
        hotKeyManager.register(keyCombo: settings.hotKey) { [weak self] in
            self?.panelController?.toggle()
        }
    }

    private func applyQuickPasteHotKeys() {
        guard settings.quickPasteEnabled else {
            hotKeyManager.unregisterQuickPaste()
            return
        }
        hotKeyManager.registerQuickPaste(modifiers: settings.quickPasteModifiers) { [weak self] digit in
            self?.quickPaste(index: digit - 1)
        }
    }

    /// Paste the Nth most-recent history item directly, without opening the panel.
    /// `index` is 0-based (⌘⇧1 → index 0).
    private func quickPaste(index: Int) {
        guard let store = historyStore else { return }
        // The panel is normally closed when quick-pasting, so the focused app is the target.
        // If it happens to be open, use the app captured before it stole focus and hide it.
        let target: NSRunningApplication?
        if panelController?.isVisible == true {
            target = panelController?.frontmostAppBeforeShow
            panelController?.hide()
        } else {
            target = NSWorkspace.shared.frontmostApplication
        }
        let items = store.fetchAll(limit: index + 1)
        guard items.indices.contains(index) else { return }
        appLogger.info("quickPaste index=\(index, privacy: .public)")
        pasteEngine.paste(
            item: items[index],
            toApp: target,
            restoreClipboard: settings.restoreClipboardAfterPaste
        )
    }

    private func applyHistoryLimit() {
        historyStore?.limit = settings.maxItems
        historyStore?.evictOverflowIfNeeded()
    }

    private func startRetentionSweep() {
        runRetentionSweep()
        // Re-run every hour for retention enforcement.
        let timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runRetentionSweep() }
        }
        retentionTimer = timer
    }

    private func runRetentionSweep() {
        guard let cutoff = settings.retention.seconds,
              let store = historyStore else { return }
        let threshold = Date().addingTimeInterval(-cutoff)
        let items = store.fetchAll()
        for item in items where !item.isPinned && item.createdAt < threshold {
            store.delete(item)
        }
    }

    private func startPermissionMonitor() {
        // Poll in both directions: the grant can disappear mid-session (revoked in System
        // Settings, or invalidated by a signature change after rebuild/auto-update), and the
        // warning icon + "Accessibility Permission" menu item are the only surfaces for it
        // now that onboarding no longer re-prompts after first launch.
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.statusItem?.button else { return }
                self.updateStatusIcon(button: button)
            }
        }
        permissionMonitorTimer = timer
    }

    // MARK: - Menu actions

    /// "Show History" from the right-click menu: open under the icon, like a left click.
    @objc private func togglePanel() {
        guard let button = statusItem?.button, let rect = statusItemScreenRect(button) else {
            panelController?.toggle()
            return
        }
        panelController?.toggle(source: .statusItem(rect))
    }

    private func statusItemScreenRect(_ button: NSStatusBarButton) -> CGRect? {
        guard let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let statusItem else { return }
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            panelController?.hide()
            // Attach the menu only for this click so left clicks keep reaching this action.
            statusItem.menu = statusMenu
            sender.performClick(nil)
            statusItem.menu = nil
            return
        }
        guard let rect = statusItemScreenRect(sender) else { return }
        panelController?.toggle(source: .statusItem(rect))
    }

    @objc private func openSettings() {
        if let win = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsView(settings: settings))
        let win = NSWindow(contentViewController: host)
        win.title = String(localized: "NovaClipboard Settings")
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = SettingsWindowDelegate.shared
        settingsWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Writes a report to the Desktop and reveals it, so users can attach it to a bug report.
    @objc private func exportDiagnostics() {
        let sections = DiagnosticsExporter.Sections(
            store: historyStore?.diagnosticsSummary ?? "historyStore=nil",
            monitor: clipboardMonitor?.diagnosticsSummary ?? "clipboardMonitor=nil",
            screenshots: (screenshotWatcher?.diagnosticsSummary ?? "screenshotWatcher=nil")
                + " captureScreenshots=\(settings.captureScreenshots)"
        )
        do {
            let url = try DiagnosticsExporter.export(sections)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            appLogger.error("Export diagnostics failed: \(String(describing: error), privacy: .public)")
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func clearAll() {
        historyStore?.clearAll(keepPinned: true)
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(clearAll) {
            guard let historyStore else { return false }
            return historyStore.hasClearableItems
        }
        return true
    }

    @objc private func openAccessibilityPermission() {
        showOnboarding()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        if let win = onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: PermissionsView { [weak self] in
            self?.completeOnboarding()
        })
        let win = NSWindow(contentViewController: host)
        win.title = String(localized: "Welcome")
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        onboardingWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func completeOnboarding() {
        settings.hasOnboarded = true
        onboardingWindow?.close()
        onboardingWindow = nil
        if let button = statusItem?.button {
            updateStatusIcon(button: button)
        }
    }
}

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowDelegate()
    // No-op delegate kept around so the window remains valid while hidden.
}
