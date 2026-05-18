import AppKit
import SwiftData
import os

private let appLogger = Logger(subsystem: "io.creativeforce.NovaClipboard", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var modelContainer: ModelContainer?
    private var historyStore: HistoryStore?
    private var clipboardMonitor: ClipboardMonitor?
    private let hotKeyManager = HotKeyManager()
    private let anchorResolver = PanelAnchorResolver()
    private let pasteEngine = PasteEngine()
    private var panelController: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLogger.info("NovaClipboard launched build=paste-debug-1")
        setupModelContainer()
        setupStatusItem()
        setupPanelController()
        setupHotKey()
        setupClipboardMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        hotKeyManager.unregister()
    }

    private func setupModelContainer() {
        do {
            let schema = Schema([ClipboardItem.self])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let container = try ModelContainer(for: schema, configurations: [config])
            modelContainer = container
            historyStore = HistoryStore(context: container.mainContext)
        } catch {
            NSLog("Failed to create ModelContainer: \(error)")
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "NovaClipboard")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show History", action: #selector(togglePanel), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit NovaClipboard", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu

        statusItem = item
    }

    private func setupPanelController() {
        guard let modelContainer else { return }
        panelController = PanelController(
            modelContainer: modelContainer,
            anchorResolver: anchorResolver,
            onPaste: { [weak self] item in
                guard let self else { return }
                let target = self.panelController?.frontmostAppBeforeShow
                appLogger.info("AppDelegate.onPaste fired, target=\(target?.bundleIdentifier ?? "nil", privacy: .public)")
                self.pasteEngine.paste(item: item, toApp: target)
            }
        )
    }

    private func setupHotKey() {
        hotKeyManager.register(keyCombo: .defaultShowPanel) { [weak self] in
            self?.panelController?.toggle()
        }
    }

    private func setupClipboardMonitor() {
        let monitor = ClipboardMonitor()
        monitor.onNewItem = { [weak self] item in
            MainActor.assumeIsolated {
                self?.historyStore?.insert(item)
            }
        }
        monitor.start()
        clipboardMonitor = monitor
    }

    @objc private func togglePanel() {
        panelController?.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
