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

    /// Hotkey id for the panel toggle. Quick-paste slots use `quickPasteBaseID + digit`.
    private static let panelHotKeyID: UInt32 = 1
    private static let quickPasteBaseID: UInt32 = 100

    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]

    // MARK: - Panel hotkey

    @discardableResult
    func register(keyCombo: KeyCombo, handler: @escaping () -> Void) -> Bool {
        registerHotKey(
            id: HotKeyManager.panelHotKeyID,
            keyCode: keyCombo.keyCode,
            modifiers: keyCombo.modifiers,
            handler: handler
        )
    }

    // MARK: - Quick-paste hotkeys (⌘⇧1…9)

    /// Registers digit keys 1–9 with the given modifiers. The handler receives the
    /// 1-based digit that was pressed.
    func registerQuickPaste(modifiers: UInt32, handler: @escaping (Int) -> Void) {
        unregisterQuickPaste()
        let digitKeyCodes: [Int] = [
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
            kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
        ]
        for (offset, keyCode) in digitKeyCodes.enumerated() {
            let digit = offset + 1
            registerHotKey(
                id: HotKeyManager.quickPasteBaseID + UInt32(digit),
                keyCode: UInt32(keyCode),
                modifiers: modifiers,
                handler: { handler(digit) }
            )
        }
    }

    func unregisterQuickPaste() {
        for digit in 1...9 {
            unregisterHotKey(id: HotKeyManager.quickPasteBaseID + UInt32(digit))
        }
    }

    // MARK: - Registration internals

    @discardableResult
    private func registerHotKey(
        id: UInt32,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping () -> Void
    ) -> Bool {
        // Re-registering the same slot replaces the old binding (e.g. the panel hotkey changes).
        unregisterHotKey(id: id)

        guard installEventHandlerIfNeeded() else { return false }

        let hkID = EventHotKeyID(signature: HotKeyManager.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            hotKeyLogger.error("RegisterEventHotKey failed for id \(id, privacy: .public) with status \(status, privacy: .public)")
            return false
        }
        hotKeyRefs[id] = ref
        handlers[id] = handler
        return true
    }

    private func unregisterHotKey(id: UInt32) {
        if let ref = hotKeyRefs[id] {
            UnregisterEventHotKey(ref)
            hotKeyRefs[id] = nil
        }
        handlers[id] = nil
    }

    /// Installs the shared Carbon event handler once. All hotkeys dispatch through it,
    /// keyed by `EventHotKeyID.id`.
    private func installEventHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }

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
                guard let handler = manager.handlers[hkID.id] else {
                    return OSStatus(eventNotHandledErr)
                }
                handler()
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
            return false
        }
        return true
    }

    func unregister() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        handlers.removeAll()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    deinit {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }
}
