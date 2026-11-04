import XCTest
@testable import NovaClipboard

final class PasteTransformerTests: XCTestCase {
    private let uuidRule = PasteTransform.presets[0]

    func testUppercasesUUIDsOnly() {
        let text = "id: 3f2504e0-4f89-11d3-9a0c-0305e82c3301, name: abc"
        let result = PasteTransformer(rules: [uuidRule]).apply(to: text, targetBundleID: nil)
        XCTAssertEqual(result.text, "id: 3F2504E0-4F89-11D3-9A0C-0305E82C3301, name: abc")
        XCTAssertEqual(result.appliedRules, [uuidRule.name])
    }

    func testUnchangedTextReportsNoRules() {
        let result = PasteTransformer(rules: [uuidRule]).apply(to: "nothing here", targetBundleID: nil)
        XCTAssertEqual(result.text, "nothing here")
        XCTAssertFalse(result.isChanged)
    }

    func testReplaceTemplateUsesCaptureGroups() {
        let rule = PasteTransform(name: "swap", pattern: #"(\w+)@(\w+)"#, action: .replace, template: "$2:$1")
        let result = PasteTransformer(rules: [rule]).apply(to: "a@b c@d", targetBundleID: nil)
        XCTAssertEqual(result.text, "b:a d:c")
    }

    func testRemoveAndLowercase() {
        let trim = PasteTransform.presets[1]
        let lower = PasteTransform(name: "lower", pattern: "[A-Z]+", action: .lowercase)
        let result = PasteTransformer(rules: [trim, lower]).apply(to: "  HELLO World \n", targetBundleID: nil)
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.appliedRules, [trim.name, "lower"])
    }

    func testRulesRunInOrderOnPreviousOutput() {
        let first = PasteTransform(name: "a→b", pattern: "a", action: .replace, template: "b")
        let second = PasteTransform(name: "b→c", pattern: "b", action: .replace, template: "c")
        XCTAssertEqual(PasteTransformer(rules: [first, second]).apply(to: "a", targetBundleID: nil).text, "c")
        XCTAssertEqual(PasteTransformer(rules: [second, first]).apply(to: "a", targetBundleID: nil).text, "b")
    }

    func testDisabledAndInvalidRulesAreSkipped() {
        var disabled = uuidRule
        disabled.isEnabled = false
        let invalid = PasteTransform(name: "bad", pattern: "(", action: .remove)
        XCTAssertNotNil(invalid.patternError)
        let text = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
        let result = PasteTransformer(rules: [disabled, invalid]).apply(to: text, targetBundleID: nil)
        XCTAssertEqual(result.text, text)
    }

    func testAppFilter() {
        var rule = uuidRule
        rule.appBundleIDs = ["com.example.Editor"]
        let text = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
        let transformer = PasteTransformer(rules: [rule])
        XCTAssertTrue(transformer.apply(to: text, targetBundleID: "com.example.Editor").isChanged)
        XCTAssertFalse(transformer.apply(to: text, targetBundleID: "com.example.Other").isChanged)
        XCTAssertFalse(transformer.apply(to: text, targetBundleID: nil).isChanged)
    }

    func testOverlongTextIsLeftAlone() {
        let text = String(repeating: "3f2504e0-4f89-11d3-9a0c-0305e82c3301 ", count: PasteTransformer.maxLength / 37 + 1)
        XCTAssertFalse(PasteTransformer(rules: [uuidRule]).apply(to: text, targetBundleID: nil).isChanged)
    }

    /// A catastrophically backtracking pattern must give up and paste the original.
    func testSlowPatternTimesOut() {
        let slow = PasteTransform(name: "slow", pattern: "(a+)+$", action: .remove)
        let text = String(repeating: "a", count: 40) + "b"
        let start = Date()
        let result = PasteTransformer(rules: [slow], timeLimit: 0.05).apply(to: text, targetBundleID: nil)
        XCTAssertEqual(result.text, text)
        XCTAssertFalse(result.isChanged)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCombinedPasteboardUsesTransformedText() {
        let items = [ClipboardItem.text("3f2504e0-4f89-11d3-9a0c-0305e82c3301"), ClipboardItem.text("x")]
        let transformer = PasteTransformer(rules: [uuidRule])
        let combined = ClipboardItem.combinedPasteboardItems(items) {
            transformer.apply(to: $0.contentText ?? "", targetBundleID: nil).text
        }
        XCTAssertEqual(combined.first?.string(forType: .string), "3F2504E0-4F89-11D3-9A0C-0305E82C3301\nx")
    }

    func testCodableRoundTrip() throws {
        var rule = PasteTransform(name: "r", pattern: "x", action: .replace, template: "$0$0", caseInsensitive: true)
        rule.appBundleIDs = ["com.example.App"]
        let decoded = try JSONDecoder().decode([PasteTransform].self, from: JSONEncoder().encode([rule]))
        XCTAssertEqual(decoded, [rule])
    }

    func testOnCopyUsesOnlyOnCopyRulesWithoutAppLimit() {
        var onCopy = uuidRule
        onCopy.applyOnCopy = true
        var limited = PasteTransform(name: "limited", pattern: "x", action: .remove, applyOnCopy: true)
        limited.appBundleIDs = ["com.example.App"]
        let pasteOnly = PasteTransform(name: "paste only", pattern: "name", action: .uppercase)
        let result = PasteTransformer.onCopy([onCopy, limited, pasteOnly])
            .apply(to: "x 3f2504e0-4f89-11d3-9a0c-0305e82c3301 name", targetBundleID: nil)
        XCTAssertEqual(result.text, "x 3F2504E0-4F89-11D3-9A0C-0305E82C3301 name")
        XCTAssertEqual(result.appliedRules, [onCopy.name])
    }

    /// Rules saved before `applyOnCopy` existed must keep loading.
    func testDecodesRulesSavedWithoutNewerFields() throws {
        let json = #"[{"id":"8F408D38-4CF8-4108-9CDD-E26520B2A95C","name":"Uppercase UUIDs","pattern":"a","action":"uppercase","template":"","isEnabled":true,"caseInsensitive":false,"appBundleIDs":[]}]"#
        let rules = try JSONDecoder().decode([PasteTransform].self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 1)
        XCTAssertFalse(rules[0].applyOnCopy)
        XCTAssertEqual(rules[0].name, "Uppercase UUIDs")
    }
}
