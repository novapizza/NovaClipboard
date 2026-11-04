import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings tab listing the paste transform rules (`AppSettings.pasteTransforms`).
struct PasteTransformsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var editing: PasteTransform?
    /// Set when the editor was opened for a new rule, so Save appends instead of replacing.
    @State private var isNew = false

    var body: some View {
        Form {
            Section {
                if settings.pasteTransforms.isEmpty {
                    Text("No rules yet. Add one, or start from a preset.")
                        .foregroundStyle(.tertiary)
                } else {
                    List {
                        ForEach($settings.pasteTransforms) { $rule in
                            ruleRow($rule)
                        }
                        .onMove { settings.pasteTransforms.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .frame(minHeight: 120, maxHeight: 180)
                }

                HStack {
                    Menu {
                        Button("New Rule…") {
                            open(PasteTransform(name: "", pattern: "", action: .uppercase), isNew: true)
                        }
                        Divider()
                        ForEach(PasteTransform.presets) { preset in
                            Button(preset.name) { open(preset, isNew: true) }
                        }
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                    .fixedSize()
                    Spacer()
                }
            } header: {
                Text("Rewrite text as it's pasted, e.g. uppercase every UUID. Rules run top to bottom. History keeps the original, and ⌥↵ or ⌥-click pastes it unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { rule in
            PasteTransformEditor(rule: rule, isNew: isNew) { saved in
                if let index = settings.pasteTransforms.firstIndex(where: { $0.id == saved.id }) {
                    settings.pasteTransforms[index] = saved
                } else {
                    settings.pasteTransforms.append(saved)
                }
            }
        }
    }

    private func ruleRow(_ rule: Binding<PasteTransform>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.wrappedValue.name)
                    .lineLimit(1)
                Text(summary(rule.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if rule.wrappedValue.patternError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(String(localized: "Invalid regular expression"))
            }
            Button {
                open(rule.wrappedValue, isNew: false)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help(String(localized: "Edit"))
            Button {
                settings.pasteTransforms.removeAll { $0.id == rule.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Delete"))
        }
    }

    private func summary(_ rule: PasteTransform) -> String {
        var text = "/\(rule.pattern)/ → \(rule.action.displayName)"
        if rule.action == .replace {
            text += " \"\(rule.template)\""
        }
        if rule.applyOnCopy {
            text += " · " + String(localized: "on copy")
        } else if !rule.appBundleIDs.isEmpty {
            text += " · " + rule.appBundleIDs.map(AppName.of).joined(separator: ", ")
        }
        return text
    }

    private func open(_ rule: PasteTransform, isNew: Bool) {
        var rule = rule
        if isNew { rule.id = UUID() }
        self.isNew = isNew
        editing = rule
    }
}

/// Sheet for creating or editing one rule, with a live tester.
private struct PasteTransformEditor: View {
    @State var rule: PasteTransform
    let isNew: Bool
    let onSave: (PasteTransform) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sample = ""
    @State private var limitToApps: Bool

    init(rule: PasteTransform, isNew: Bool, onSave: @escaping (PasteTransform) -> Void) {
        _rule = State(initialValue: rule)
        _limitToApps = State(initialValue: !rule.appBundleIDs.isEmpty)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            (isNew ? Text("New Rule") : Text("Edit Rule"))
                .font(.headline)

            Form {
                TextField("Name", text: $rule.name)

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Pattern (regular expression)", text: $rule.pattern)
                        .font(.body.monospaced())
                    if let error = rule.patternError, !rule.pattern.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Toggle("Ignore case", isOn: $rule.caseInsensitive)

                Picker("Action", selection: $rule.action) {
                    ForEach(PasteTransform.Action.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                if rule.action == .replace {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Replacement", text: $rule.template)
                            .font(.body.monospaced())
                        Text("$0 inserts the whole match, $1 the first capture group.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $rule.applyOnCopy) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apply as soon as text is copied")
                        Text("⌘V anywhere pastes the result, not just pasting from NovaClipboard. The clipboard then holds plain text only; the original stays in history (⌥↵ pastes it).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // The target app isn't known when text is copied.
                if !rule.applyOnCopy {
                    Picker("Apply when pasting into", selection: $limitToApps) {
                        Text("Any app").tag(false)
                        Text("Only these apps").tag(true)
                    }
                    if limitToApps {
                        appList
                    }
                }

                Section("Try it") {
                    TextField("Sample text", text: $sample, axis: .vertical)
                        .lineLimit(2...4)
                    LabeledContent("Result") {
                        Text(testResult)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = rule
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    if !limitToApps || saved.applyOnCopy { saved.appBundleIDs = [] }
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 460, height: 520)
    }

    private var canSave: Bool {
        !rule.name.trimmingCharacters(in: .whitespaces).isEmpty && rule.patternError == nil
    }

    private var testResult: String {
        guard !sample.isEmpty else { return "—" }
        guard rule.patternError == nil else { return sample }
        var probe = rule
        probe.isEnabled = true
        probe.appBundleIDs = []
        return PasteTransformer(rules: [probe], logs: false).apply(to: sample, targetBundleID: nil).text
    }

    @ViewBuilder
    private var appList: some View {
        ForEach(rule.appBundleIDs, id: \.self) { bundleID in
            HStack {
                Text(AppName.of(bundleID))
                Text(bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    rule.appBundleIDs.removeAll { $0 == bundleID }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        Button("Add App…", action: chooseApp)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  !rule.appBundleIDs.contains(bundleID) else { continue }
            rule.appBundleIDs.append(bundleID)
        }
    }
}

private enum AppName {
    /// The app's display name, or the bundle ID when the app isn't installed.
    static func of(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
