import AppKit
import Carbon.HIToolbox

final class HotKeyManager {
    private static let signature: FourCharCode = {
        let chars = Array("NCLB".utf8)
        return (FourCharCode(chars[0]) << 24)
            | (FourCharCode(chars[1]) << 16)
            | (FourCharCode(chars[2]) << 8)
            | FourCharCode(chars[3])
    }()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    private static var shared: HotKeyManager?

    func register(keyCombo: KeyCombo, handler: @escaping () -> Void) {
        unregister()
        self.handler = handler
        HotKeyManager.shared = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ in
                guard let eventRef else { return noErr }
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard status == noErr, hkID.signature == HotKeyManager.signature else {
                    return noErr
                }
                HotKeyManager.shared?.handler?()
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )

        let hkID = EventHotKeyID(signature: HotKeyManager.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCombo.keyCode,
            keyCombo.modifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("HotKeyManager: RegisterEventHotKey failed with status \(status)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        self.handler = nil
        if HotKeyManager.shared === self {
            HotKeyManager.shared = nil
        }
    }

    deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }
}
