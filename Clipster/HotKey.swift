import Carbon
import Carbon.HIToolbox   // for kVK_* key codes
import Cocoa

/// A persistable global shortcut definition.
struct HotKeySpec: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        (flags.contains(.command) ? UInt32(cmdKey) : 0) |
        (flags.contains(.option)  ? UInt32(optionKey) : 0) |
        (flags.contains(.control) ? UInt32(controlKey) : 0) |
        (flags.contains(.shift)   ? UInt32(shiftKey) : 0)
    }

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + HotKeySpec.keyName(for: keyCode)
    }

    static func keyName(for keyCode: UInt32) -> String {
        let specials: [UInt32: String] = [
            UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space",
            UInt32(kVK_Delete): "⌫", UInt32(kVK_Escape): "⎋", UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞",
            UInt32(kVK_PageDown): "⇟", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        ]
        if let s = specials[keyCode] { return s }

        // Translate via the current keyboard layout.
        guard let sourceRef = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData)
        else { return "key \(keyCode)" }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let err = layoutData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            guard let base = ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(base, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        if err == noErr, length > 0 {
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
        return "key \(keyCode)"
    }
}

/// Registers multiple Carbon global hotkeys, dispatching by hotkey id.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    static let historyHotKeyID: UInt32 = 1
    static let captureAreaHotKeyID: UInt32 = 2
    static let captureTextHotKeyID: UInt32 = 3

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false
    private let signature: OSType = {
        // 'CLPS' four-char code
        let chars: [UInt8] = Array("CLPS".utf8)
        return OSType(chars[0]) << 24 | OSType(chars[1]) << 16 | OSType(chars[2]) << 8 | OSType(chars[3])
    }()

    private init() {}

    func register(id: UInt32, spec: HotKeySpec, handler: @escaping () -> Void) {
        unregister(id: id)
        installHandlerIfNeeded()
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
        } else {
            handlers[id] = nil
        }
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers[id] = nil
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyCallback, 1, &eventType, nil, nil)
    }
}

/// Global C-compatible callback (no captured context).
private func hotKeyCallback(_ nextHandler: EventHandlerCallRef?,
                            _ theEvent: EventRef?,
                            _ userData: UnsafeMutableRawPointer?) -> OSStatus
{
    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(theEvent, EventParamName(kEventParamDirectObject),
                                EventParamType(typeEventHotKeyID), nil,
                                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    if err == noErr {
        HotKeyCenter.shared.fire(id: hotKeyID.id)
    }
    return noErr
}

/// Loads, persists and (re-)registers the configurable capture shortcuts.
final class ShortcutManager: ObservableObject {
    static let defaultAreaSpec = HotKeySpec(keyCode: UInt32(kVK_ANSI_4),
                                            carbonModifiers: UInt32(cmdKey) | UInt32(optionKey))
    static let defaultTextSpec = HotKeySpec(keyCode: UInt32(kVK_ANSI_5),
                                            carbonModifiers: UInt32(cmdKey) | UInt32(optionKey))

    @Published var captureAreaSpec: HotKeySpec? {
        didSet { persist(captureAreaSpec, key: "hotkeyCaptureArea"); reregister() }
    }
    @Published var captureTextSpec: HotKeySpec? {
        didSet { persist(captureTextSpec, key: "hotkeyCaptureText"); reregister() }
    }

    var onCaptureArea: (() -> Void)?
    var onCaptureText: (() -> Void)?

    private let defaults = UserDefaults.standard

    init() {
        captureAreaSpec = Self.loadSpec(key: "hotkeyCaptureArea", fallback: Self.defaultAreaSpec)
        captureTextSpec = Self.loadSpec(key: "hotkeyCaptureText", fallback: Self.defaultTextSpec)
    }

    func activate() {
        reregister()
    }

    private static func loadSpec(key: String, fallback: HotKeySpec?) -> HotKeySpec? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return fallback }
        // An empty stored value means "explicitly disabled".
        if data.isEmpty { return nil }
        return try? JSONDecoder().decode(HotKeySpec.self, from: data)
    }

    private func persist(_ spec: HotKeySpec?, key: String) {
        if let spec, let data = try? JSONEncoder().encode(spec) {
            defaults.set(data, forKey: key)
        } else {
            defaults.set(Data(), forKey: key)
        }
    }

    private func reregister() {
        HotKeyCenter.shared.unregister(id: HotKeyCenter.captureAreaHotKeyID)
        HotKeyCenter.shared.unregister(id: HotKeyCenter.captureTextHotKeyID)
        if let spec = captureAreaSpec {
            HotKeyCenter.shared.register(id: HotKeyCenter.captureAreaHotKeyID, spec: spec) { [weak self] in
                self?.onCaptureArea?()
            }
        }
        if let spec = captureTextSpec {
            HotKeyCenter.shared.register(id: HotKeyCenter.captureTextHotKeyID, spec: spec) { [weak self] in
                self?.onCaptureText?()
            }
        }
    }
}
