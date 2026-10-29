import Carbon
import Carbon.HIToolbox   // for kVK_* key codes
import Cocoa

/// Simple Carbon hotkey wrapper that avoids capturing in the C callback.
enum HotKey {
    // Keep the handler in a static var (no capture in the C callback)
    private static var pressedHandler: (() -> Void)?

    // Keep a strong ref to the registered hot key so it stays active
    private static var hotKeyRef: EventHotKeyRef?

    static func register(modifiers: NSEvent.ModifierFlags,
                         key: UInt32 = UInt32(kVK_ANSI_V),
                         handler: @escaping () -> Void)
    {
        pressedHandler = handler

        // Build Carbon modifier mask
        let carbonMods: UInt32 =
            (modifiers.contains(.command) ? UInt32(cmdKey) : 0) |
            (modifiers.contains(.option)  ? UInt32(optionKey) : 0) |
            (modifiers.contains(.control) ? UInt32(controlKey) : 0) |
            (modifiers.contains(.shift)   ? UInt32(shiftKey) : 0)

        // Use 'let' — we don't mutate this
        let eventHotKeyID = EventHotKeyID(signature: OSType(UInt32(truncatingIfNeeded: "CLIP".hashValue)),
                                          id: UInt32(1))

        // Register the hotkey
        var ref: EventHotKeyRef?
        RegisterEventHotKey(key, carbonMods, eventHotKeyID, GetEventDispatcherTarget(), 0, &ref)
        hotKeyRef = ref

        // Install a C-style callback that does NOT capture Swift context
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(),
                            hotKeyCallback, 1, &eventType, nil, nil)
    }
}

/// Global C-compatible callback (no captured context)
private func hotKeyCallback(_ nextHandler: EventHandlerCallRef?,
                            _ theEvent: EventRef?,
                            _ userData: UnsafeMutableRawPointer?) -> OSStatus
{
    // Fire the stored Swift closure
    HotKey.performHandler()
    return noErr
}

// Expose a tiny helper so the global function can call back without capturing
private extension HotKey {
    static func performHandler() {
        pressedHandler?()
    }
}
