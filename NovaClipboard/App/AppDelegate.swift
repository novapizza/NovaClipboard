import AppKit
import Combine
import SwiftData
import SwiftUI
import os

private let appLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private var statusItem: NSStatusItem?
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
    private let updateController = UpdateController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLogger.info("NovaClipboard launching, phase-2 build")
        setupModelContainer()
        setupStatusItem()
        setupPanelController()
        setupClipboardMonitor()
        setupScreenshotWatcher()
        setupSettingsBindings()
        applyHotKey()
        applyHistoryLimit()
        startRetentionSweep()
        startPermissionMonitor()

        if !settings.hasOnboarded || !AXIsProcessTrusted() {
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
        do {
            let schema = Schema([ClipboardItem.self])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let container = try ModelContainer(for: schema, configurations: [config])
            modelContainer = container
            historyStore = HistoryStore(context: container.mainContext, limit: settings.maxItems)
        } catch {
            appLogger.error("Failed to create ModelContainer: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "NovaClipboard cannot start"
            alert.informativeText = "The clipboard database could not be opened.\n\n\(error.localizedDescription)\n\nThe app will now quit."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            updateStatusIcon(button: button)
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show History", action: #selector(togglePanel), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(UpdateController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updateController
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear All (keep pinned)", action: #selector(clearAll), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit NovaClipboard", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu

        statusItem = item
    }

    private func updateStatusIcon(button: NSStatusBarButton) {
        let symbolName = AXIsProcessTrusted() ? "doc.on.clipboard" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "NovaClipboard")
        image?.isTemplate = AXIsProcessTrusted()
        button.image = image
    }

    private func setupPanelController() {
        guard let modelContainer, let historyStore else { return }
        panelController = PanelController(
            modelContainer: modelContainer,
            historyStore: historyStore,
            anchorResolver: anchorResolver,
            settings: settings,
            onPaste: { [weak self] item in
                guard let self else { return }
                let target = self.panelController?.frontmostAppBeforeShow
                appLogger.info("AppDelegate.onPaste fired, target=\(target?.bundleIdentifier ?? "nil", privacy: .public)")
                self.pasteEngine.paste(item: item, toApp: target)
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
            ? String(format: "Screenshot · %.0f KB", sizeKB)
            : String(format: "Screenshot · %.1f MB", sizeKB / 1024.0)

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
        // Stop polling once Accessibility is granted — revocation is rare and the user is
        // already inside System Settings if they do it; we can rely on the next app launch
        // to repaint the warning icon.
        guard !AXIsProcessTrusted() else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.statusItem?.button else { return }
                self.updateStatusIcon(button: button)
                if AXIsProcessTrusted() {
                    self.permissionMonitorTimer?.invalidate()
                    self.permissionMonitorTimer = nil
                }
            }
        }
        permissionMonitorTimer = timer
    }

    // MARK: - Menu actions

    @objc private func togglePanel() {
        panelController?.toggle()
    }

    @objc private func openSettings() {
        if let win = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsView(settings: settings))
        let win = NSWindow(contentViewController: host)
        win.title = "NovaClipboard Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = SettingsWindowDelegate.shared
        settingsWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func clearAll() {
        historyStore?.clearAll(keepPinned: true)
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
        win.title = "Welcome"
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
