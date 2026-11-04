import Foundation
import os

private let transformLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "PasteTransformer")

/// Applies the enabled `PasteTransform` rules, in order, to text about to be pasted.
///
/// User regexes can be slow — a badly nested pattern backtracks for seconds on long text —
/// and this runs on the paste path, so it is bounded: text over `maxLength` is left alone,
/// and all rules together get `timeLimit`; when either is exceeded the original text is
/// pasted unchanged. Never logs the text itself, only rule names and counts.
struct PasteTransformer {
    static let maxLength = 100_000
    static let timeLimit: TimeInterval = 0.2

    struct Result: Equatable {
        var text: String
        /// Names of the rules that changed something, in the order they ran.
        var appliedRules: [String]
        var isChanged: Bool { !appliedRules.isEmpty }
    }

    let rules: [PasteTransform]
    var timeLimit: TimeInterval = PasteTransformer.timeLimit
    /// Off for UI previews, which run per row and would flood the log.
    var logs = true

    /// - Parameter targetBundleID: the app being pasted into, for rules limited to some apps.
    func apply(to text: String, targetBundleID: String?) -> Result {
        let unchanged = Result(text: text, appliedRules: [])
        let active = rules.filter { $0.isEnabled && $0.applies(toApp: targetBundleID) }
        guard !active.isEmpty, !text.isEmpty else { return unchanged }
        guard text.utf16.count <= Self.maxLength else {
            if logs { transformLogger.info("Skipped paste transforms: text longer than \(Self.maxLength, privacy: .public) characters") }
            return unchanged
        }

        let deadline = Date().addingTimeInterval(timeLimit)
        var current = text
        var applied: [String] = []
        for rule in active {
            guard let regex = rule.makeRegex() else {
                if logs { transformLogger.error("Skipped paste transform \(rule.name, privacy: .public): invalid pattern") }
                continue
            }
            guard let next = Self.transform(current, with: regex, rule: rule, deadline: deadline) else {
                if logs { transformLogger.error("Paste transforms timed out in \(rule.name, privacy: .public); pasting the original") }
                return unchanged
            }
            if next != current {
                applied.append(rule.name)
                current = next
            }
        }
        if logs, !applied.isEmpty {
            transformLogger.info("Applied paste transforms: \(applied.joined(separator: ", "), privacy: .public)")
        }
        return Result(text: current, appliedRules: applied)
    }

    /// nil when the deadline passed before matching finished.
    private static func transform(
        _ text: String, with regex: NSRegularExpression, rule: PasteTransform, deadline: Date
    ) -> String? {
        let source = text as NSString
        var matches: [NSTextCheckingResult] = []
        var timedOut = false
        // `.reportProgress` calls back periodically even between matches, so a pattern that
        // backtracks without matching can still be stopped.
        regex.enumerateMatches(in: text, options: [.reportProgress],
                               range: NSRange(location: 0, length: source.length)) { match, _, stop in
            if Date() > deadline {
                timedOut = true
                stop.pointee = true
                return
            }
            if let match, match.range.location != NSNotFound {
                matches.append(match)
            }
        }
        guard !timedOut else { return nil }
        guard !matches.isEmpty else { return text }

        let result = NSMutableString()
        var cursor = 0
        for match in matches {
            let range = match.range
            result.append(source.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            let matched = source.substring(with: range)
            switch rule.action {
            case .uppercase: result.append(matched.uppercased())
            case .lowercase: result.append(matched.lowercased())
            case .remove: break
            case .replace:
                result.append(regex.replacementString(for: match, in: text, offset: 0, template: rule.template))
            }
            cursor = range.location + range.length
        }
        result.append(source.substring(from: cursor))
        return result as String
    }
}

extension PasteTransformer {
    /// The rules that also run when text is copied (`PasteTransform.applyOnCopy`).
    static func onCopy(_ rules: [PasteTransform]) -> PasteTransformer {
        PasteTransformer(rules: rules.filter { $0.applyOnCopy && $0.appBundleIDs.isEmpty })
    }
}

extension ClipboardItem {
    /// Whether paste transforms run on this item: anything pasted as plain text.
    var isTransformable: Bool {
        [.text, .richText, .link].contains(type)
    }
}

/// What a paste would turn each row into, for the panel's row badge and hover card. Results
/// are cached per item and dropped when the rules or the target app change; a tighter time
/// limit keeps a slow rule from stalling the list.
@MainActor
final class PasteTransformPreview {
    private var rules: [PasteTransform] = []
    private var targetBundleID: String?
    private var cache: [UUID: PasteTransformer.Result] = [:]

    /// nil when the item isn't transformed on paste.
    func result(for item: ClipboardItem, rules: [PasteTransform], targetBundleID: String?) -> PasteTransformer.Result? {
        guard item.isTransformable, rules.contains(where: \.isEnabled) else { return nil }
        if rules != self.rules || targetBundleID != self.targetBundleID {
            cache = [:]
            self.rules = rules
            self.targetBundleID = targetBundleID
        }
        let result = cache[item.id] ?? PasteTransformer(rules: rules, timeLimit: 0.05, logs: false)
            .apply(to: item.contentText ?? item.preview, targetBundleID: targetBundleID)
        cache[item.id] = result
        return result.isChanged ? result : nil
    }
}
