import AppKit
import Carbon.HIToolbox

struct KeyCombo: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultShowPanel = KeyCombo(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    /// Build from an NSEvent's keyCode + modifierFlags. Returns nil if the event has no eligible modifiers.
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbonMods = KeyCombo.carbonModifiers(from: mods)
        guard carbonMods != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.modifiers = carbonMods
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var displayString: String {
        KeyCombo.modifierSymbols(modifiers) + KeyCombo.keyName(for: keyCode)
    }

    /// Symbol prefix for a Carbon modifier mask (e.g. `⌥⌘`). Empty if no modifiers.
    static func modifierSymbols(_ modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        return parts.joined()
    }

    private static func carbonModifiers(from cocoa: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if cocoa.contains(.command) { m |= UInt32(cmdKey) }
        if cocoa.contains(.shift) { m |= UInt32(shiftKey) }
        if cocoa.contains(.option) { m |= UInt32(optionKey) }
        if cocoa.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↵"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        default: return "Key \(keyCode)"
        }
    }
}
