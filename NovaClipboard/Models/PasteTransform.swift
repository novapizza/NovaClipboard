import Foundation

/// A user-defined rule that rewrites text as it is pasted: every match of `pattern` is
/// replaced according to `action`. History keeps the original; only what goes onto the
/// pasteboard for that paste changes. Stored as JSON in `AppSettings.pasteTransforms`.
struct PasteTransform: Codable, Identifiable, Equatable, Hashable {
    enum Action: String, Codable, CaseIterable, Identifiable {
        case uppercase
        case lowercase
        /// Replace with `template` (`$0` = whole match, `$1`… = capture groups).
        case replace
        case remove

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .uppercase: return String(localized: "Uppercase")
            case .lowercase: return String(localized: "Lowercase")
            case .replace: return String(localized: "Replace with")
            case .remove: return String(localized: "Remove")
            }
        }
    }

    var id = UUID()
    var name: String
    var pattern: String
    var action: Action
    var template: String = ""
    var caseInsensitive: Bool = false
    var isEnabled: Bool = true
    /// Only applies when pasting into one of these apps; empty means every app.
    var appBundleIDs: [String] = []
    /// Also rewrite the clipboard the moment matching text is copied, so a plain ⌘V anywhere
    /// pastes the result. The target app isn't known at copy time, so such a rule is never
    /// limited to apps.
    var applyOnCopy: Bool = false

    /// nil when `pattern` doesn't compile.
    func makeRegex() -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// Why `pattern` doesn't compile, for the editor; nil when it's valid.
    var patternError: String? {
        guard !pattern.isEmpty else { return String(localized: "Enter a pattern") }
        do {
            _ = try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
            return nil
        } catch {
            return String(localized: "Invalid regular expression")
        }
    }

    func applies(toApp bundleID: String?) -> Bool {
        guard !appBundleIDs.isEmpty else { return true }
        guard let bundleID else { return false }
        return appBundleIDs.contains(bundleID)
    }
}

extension PasteTransform {
    private enum CodingKeys: String, CodingKey {
        case id, name, pattern, action, template, caseInsensitive, isEnabled, appBundleIDs, applyOnCopy
    }

    /// Tolerates fields added after a rule was saved, so older rules keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        pattern = try c.decode(String.self, forKey: .pattern)
        action = try c.decode(Action.self, forKey: .action)
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? ""
        caseInsensitive = try c.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? false
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        appBundleIDs = try c.decodeIfPresent([String].self, forKey: .appBundleIDs) ?? []
        applyOnCopy = try c.decodeIfPresent(Bool.self, forKey: .applyOnCopy) ?? false
    }
}

extension PasteTransform {
    /// Ready-made rules offered in Settings. None is enabled until the user adds it.
    static var presets: [PasteTransform] {
        [
            PasteTransform(
                name: String(localized: "Uppercase UUIDs"),
                pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
                action: .uppercase
            ),
            PasteTransform(
                name: String(localized: "Trim leading and trailing whitespace"),
                pattern: #"^\s+|\s+$"#,
                action: .remove
            ),
            PasteTransform(
                name: String(localized: "Collapse repeated spaces"),
                pattern: #" {2,}"#,
                action: .replace,
                template: " "
            ),
            PasteTransform(
                name: String(localized: "Lowercase email addresses"),
                pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
                action: .lowercase,
                caseInsensitive: true
            )
        ]
    }
}
