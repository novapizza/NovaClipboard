import SwiftUI
import AppKit
import Carbon.HIToolbox

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.14),
                    Color.purple.opacity(0.08),
                    Color.blue.opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Rectangle().fill(.ultraThinMaterial)

            TabView {
                GeneralTab(settings: settings)
                    .tabItem { Label("General", systemImage: "gearshape") }
                HistoryTab(settings: settings)
                    .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                PrivacyTab(settings: settings)
                    .tabItem { Label("Privacy", systemImage: "lock.shield") }
                AboutTab()
                    .tabItem { Label("About", systemImage: "info.circle") }
            }
            .scrollContentBackground(.hidden)
            .padding(20)
        }
        .frame(width: 480, height: 380)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Picker("Language", selection: $settings.appLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .onChange(of: settings.appLanguage) { _, _ in promptLanguageRestart() }

            Toggle("Launch at login", isOn: $settings.launchAtLogin)

            Toggle(isOn: $settings.captureScreenshots) {
                LabelWithInfo("Capture screenshots automatically",
                              info: "Save new screenshots (⌘⇧3/4/5) to history the moment they're written to disk.")
            }

            Toggle(isOn: $settings.disableScreenshotPreview) {
                LabelWithInfo("Skip macOS preview thumbnail (instant capture)",
                              info: "Disables the floating screenshot preview so files land on Desktop immediately. Takes effect on the next ⌘⇧3/4/5 capture.")
            }
            .disabled(!settings.captureScreenshots)

            Toggle(isOn: $settings.copyScreenshotToClipboard) {
                LabelWithInfo("Copy new screenshots to the clipboard",
                              info: "Place each captured screenshot on the clipboard so you can paste it with ⌘V right after ⌘⇧3/4/5 — macOS otherwise only saves the file.")
            }
            .disabled(!settings.captureScreenshots)

            HotKeyPicker(combo: $settings.hotKey)

            Toggle(isOn: $settings.quickPasteEnabled) {
                LabelWithInfo("Quick paste by number",
                              info: "Paste the Nth most recent item directly (slot 1 = newest) without opening the panel.")
            }

            if settings.quickPasteEnabled {
                QuickPasteHotKeyPicker(modifiers: $settings.quickPasteModifiers)
            }

            Picker("Panel position", selection: $settings.panelPosition) {
                Text("At caret").tag(PanelPositionPreference.atCaret)
                Text("At mouse").tag(PanelPositionPreference.atMouse)
                Text("Fixed").tag(PanelPositionPreference.fixed)
            }
            .pickerStyle(.segmented)

            if settings.panelPosition == .fixed {
                HStack {
                    Text("Fixed origin")
                    Spacer()
                    TextField("X", value: Binding(
                        get: { settings.fixedPanelOrigin.x },
                        set: { settings.fixedPanelOrigin.x = $0 }
                    ), formatter: NumberFormatter())
                    .frame(width: 70)
                    TextField("Y", value: Binding(
                        get: { settings.fixedPanelOrigin.y },
                        set: { settings.fixedPanelOrigin.y = $0 }
                    ), formatter: NumberFormatter())
                    .frame(width: 70)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The bundle only reads the language override at launch, so offer to relaunch
    /// immediately. Declining leaves the new language to take effect on the next start.
    private func promptLanguageRestart() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart required")
        alert.informativeText = String(localized: "NovaClipboard needs to restart to change the language.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            relaunchApp()
        }
    }

    private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - History

private struct HistoryTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            HStack {
                Text("Max items: \(settings.maxItems)")
                Spacer()
                Slider(
                    value: Binding(
                        get: { Double(settings.maxItems) },
                        set: { settings.maxItems = Int($0) }
                    ),
                    in: 1...100,
                    step: 1
                )
                .frame(width: 220)
            }
            HStack {
                Text("Max image size: \(settings.maxImageMB) MB")
                Spacer()
                Slider(
                    value: Binding(
                        get: { Double(settings.maxImageMB) },
                        set: { settings.maxImageMB = Int($0) }
                    ),
                    in: 1...10,
                    step: 1
                )
                .frame(width: 220)
            }
            Picker("Retention", selection: $settings.retention) {
                ForEach(RetentionPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacyTab: View {
    @ObservedObject var settings: AppSettings
    @State private var newBundleID: String = ""

    var body: some View {
        Form {
            Section("Blocked apps") {
                Text("Clipboard items copied from these apps will not be captured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("com.example.App", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let trimmed = newBundleID.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty,
                              !settings.blocklistBundleIDs.contains(trimmed) else { return }
                        settings.blocklistBundleIDs.append(trimmed)
                        newBundleID = ""
                    }
                }

                if settings.blocklistBundleIDs.isEmpty {
                    Text("No blocked apps").foregroundStyle(.tertiary)
                } else {
                    List {
                        ForEach(settings.blocklistBundleIDs, id: \.self) { id in
                            HStack {
                                Text(id)
                                Spacer()
                                Button {
                                    settings.blocklistBundleIDs.removeAll { $0 == id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(minHeight: 100, maxHeight: 160)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(width: 96, height: 96)
                .liquidGlass(.regular, in: .circle)
            Text("NovaClipboard")
                .font(.title2.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .liquidGlass(.regular, in: .capsule)
            HStack(spacing: 10) {
                Link(destination: URL(string: "mailto:nch180297@gmail.com")!) {
                    Label("Send feedback", systemImage: "envelope")
                }
                .buttonStyle(.liquidGlass())
                Link(destination: URL(string: "https://github.com/novapizza/NovaClipboard")!) {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.liquidGlass())
            }
            .font(.callout)

            Button {
                UpdateController.shared.checkForUpdates(nil)
            } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.liquidGlass())
            .font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Info tooltip

/// A control label paired with a trailing info icon. Hovering the icon shows the
/// explanatory text instantly in a popover, replacing the hard-to-discover
/// system `.help()` tooltip (which only appears after a delay).
private struct LabelWithInfo: View {
    let title: LocalizedStringKey
    let info: LocalizedStringKey

    init(_ title: LocalizedStringKey, info: LocalizedStringKey) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            InfoTip(text: info)
        }
    }
}

/// An `info.circle` icon that reveals `text` in a popover the moment the pointer
/// enters it, and dismisses it on exit.
private struct InfoTip: View {
    let text: LocalizedStringKey
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .onHover { isHovering = $0 }
            .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240, alignment: .leading)
                    .padding(12)
            }
            .accessibilityLabel(Text(text))
    }
}

// MARK: - Hotkey picker

private struct HotKeyPicker: View {
    @Binding var combo: KeyCombo
    @State private var capturing: Bool = false

    var body: some View {
        HStack {
            Text("Show panel hotkey")
            Spacer()
            Button {
                capturing.toggle()
            } label: {
                Text(capturing ? "Press combo…" : combo.displayString)
                    .font(.callout.monospaced())
                    .frame(minWidth: 100)
            }
            .buttonStyle(.liquidGlass(tint: capturing ? .accentColor : nil))
            .background(HotKeyCapture(active: capturing) { newCombo in
                combo = newCombo
                capturing = false
            })
        }
    }
}

private struct QuickPasteHotKeyPicker: View {
    @Binding var modifiers: UInt32
    @State private var capturing: Bool = false

    var body: some View {
        HStack {
            LabelWithInfo("Quick paste hotkey",
                          info: "Press a combo like ⌥⌘ + any key. Only its modifiers are used; the digits 1–9 pick the item.")
            Spacer()
            Button {
                capturing.toggle()
            } label: {
                Text(capturing ? "Press combo…" : "\(KeyCombo.modifierSymbols(modifiers))1–9")
                    .font(.callout.monospaced())
                    .frame(minWidth: 100)
            }
            .buttonStyle(.liquidGlass(tint: capturing ? .accentColor : nil))
            // Reuse the panel hotkey capture and keep only the modifier mask —
            // the digit is fixed to the slot number.
            .background(HotKeyCapture(active: capturing) { newCombo in
                modifiers = newCombo.modifiers
                capturing = false
            })
        }
    }
}

private struct HotKeyCapture: NSViewRepresentable {
    var active: Bool
    var onCapture: (KeyCombo) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CaptureView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CaptureView else { return }
        view.isCapturing = active
        view.onCapture = onCapture
        if active {
            view.window?.makeFirstResponder(view)
        } else {
            if view.window?.firstResponder === view {
                view.window?.makeFirstResponder(nil)
            }
        }
    }

    private final class CaptureView: NSView {
        var isCapturing: Bool = false
        var onCapture: ((KeyCombo) -> Void)?
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard isCapturing else { super.keyDown(with: event); return }
            if let combo = KeyCombo(event: event) {
                onCapture?(combo)
            }
        }
    }
}
