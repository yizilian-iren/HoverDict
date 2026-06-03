import AppKit
import Carbon

/// Registers a SYSTEM-WIDE hotkey via Carbon's `RegisterEventHotKey`.
///
/// Why Carbon and not an NSEvent global key monitor: a global keyDown monitor requires
/// the Input Monitoring / Accessibility permission, whereas a Carbon hot key does NOT —
/// it works for a background `.accessory` app with no extra permission prompt.
final class HotKeyManager {

    /// Invoked (on the main thread) each time the hotkey is pressed.
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Default = ⌘⇧A. Key codes are virtual keys (kVK_ANSI_A == 0).
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_A),
                  modifiers: UInt32 = UInt32(cmdKey | shiftKey)) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        // The Carbon handler must be a capture-less C function pointer; we route back to
        // `self` through the userData pointer.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers on the main runloop already; hop to main to be safe.
            DispatchQueue.main.async { manager.onTrigger?() }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)

        let id = EventHotKeyID(signature: fourCharCode("HVKY"), id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            // e.g. another app already owns this combo.
            NSLog("HoverDict: hotkey registration failed (status \(status)). It may be in use by another app.")
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKeyRef = nil
        eventHandler = nil
    }
}

/// Pack a 4-char string into an OSType (FourCharCode).
private func fourCharCode(_ string: String) -> OSType {
    var code: OSType = 0
    for unit in string.utf16.prefix(4) {
        code = (code << 8) + OSType(unit)
    }
    return code
}
