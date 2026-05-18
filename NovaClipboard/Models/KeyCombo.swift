import AppKit
import Carbon.HIToolbox

struct KeyCombo: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultShowPanel = KeyCombo(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | shiftKey)
    )
}
