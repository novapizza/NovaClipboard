import AppKit
import Carbon.HIToolbox
import os

private let hotKeyLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "HotKeyManager")

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

    @discardableResult
    func register(keyCombo: KeyCombo, handler: @escaping () -> Void) -> Bool {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
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
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handler?()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )

        guard installStatus == noErr else {
            hotKeyLogger.error("InstallEventHandler failed with status \(installStatus, privacy: .public)")
            eventHandler = nil
            self.handler = nil
            return false
        }

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
            return true
        } else {
            hotKeyLogger.error("RegisterEventHotKey failed with status \(status, privacy: .public)")
            if let handler = eventHandler {
                RemoveEventHandler(handler)
                eventHandler = nil
            }
            self.handler = nil
            return false
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
