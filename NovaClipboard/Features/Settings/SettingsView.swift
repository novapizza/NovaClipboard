import SwiftUI
import AppKit
import Carbon.HIToolbox

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
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
        .frame(width: 480, height: 360)
        .padding(20)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)

            HotKeyPicker(combo: $settings.hotKey)

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
                    in: 100...2000,
                    step: 50
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
                    in: 1...50,
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
            Toggle("Ignore password fields", isOn: $settings.ignorePasswordFields)
                .help("Active in Phase 3 — currently placeholder.")
                .disabled(true)
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("NovaClipboard")
                .font(.title2.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Link("Send feedback", destination: URL(string: "mailto:haunc@creativeforce.io")!)
                Link("GitHub", destination: URL(string: "https://github.com/creativeforce")!)
            }
            .font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .frame(minWidth: 100)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(capturing ? Color.accentColor : Color.secondary.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .background(HotKeyCapture(active: capturing) { newCombo in
                combo = newCombo
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
