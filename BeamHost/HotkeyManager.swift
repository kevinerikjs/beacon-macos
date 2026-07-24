// HotkeyManager.swift
// Global hotkey for toggling window-streaming mode (BEAM-2).
//
// Uses Carbon RegisterEventHotKey rather than a CGEvent tap / NSEvent global monitor:
// it's the only API that delivers system-wide key events WITHOUT requiring the
// Accessibility permission, and it can't observe any keystrokes other than the one
// registered combo — strictly less privilege than the alternatives the PRD floated.
//
// The binding (key code + Carbon modifier mask) persists in UserDefaults and is
// configurable from Settings → General via HotkeyRecorderView.

import AppKit
import Carbon.HIToolbox

@Observable
final class HotkeyManager {

    static let shared = HotkeyManager()

    /// Fired on the main thread when the registered combo is pressed.
    var onActivate: (() -> Void)?

    /// Whether the global hotkey is registered. Persisted.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "globalHotkeyEnabled")
            isEnabled ? register() : unregister()
        }
    }

    /// Virtual key code of the binding (kVK_*). Default: B.
    private(set) var keyCode: UInt32

    /// Carbon modifier mask (cmdKey | optionKey | controlKey | shiftKey). Default: ⌥⌘.
    private(set) var modifiers: UInt32

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: "globalHotkeyEnabled") == nil
            ? true : defaults.bool(forKey: "globalHotkeyEnabled")
        keyCode = defaults.object(forKey: "globalHotkeyKeyCode") == nil
            ? UInt32(kVK_ANSI_B) : UInt32(defaults.integer(forKey: "globalHotkeyKeyCode"))
        modifiers = defaults.object(forKey: "globalHotkeyModifiers") == nil
            ? UInt32(cmdKey | optionKey) : UInt32(defaults.integer(forKey: "globalHotkeyModifiers"))
    }

    /// Call once at app launch (AppState.init) after assigning `onActivate`.
    func start() {
        installHandlerIfNeeded()
        if isEnabled { register() }
    }

    /// Store and apply a new binding (from the Settings recorder).
    func setBinding(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        UserDefaults.standard.set(Int(keyCode), forKey: "globalHotkeyKeyCode")
        UserDefaults.standard.set(Int(modifiers), forKey: "globalHotkeyModifiers")
        if isEnabled { register() }
    }

    // MARK: - Carbon plumbing

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            DispatchQueue.main.async { HotkeyManager.shared.onActivate?() }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
    }

    private func register() {
        unregister()
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4245_414D) /* 'BEAM' */, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("[HotkeyManager] RegisterEventHotKey failed: \(status)")
        }
    }

    private func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    // MARK: - Display

    /// Human-readable combo, e.g. "⌥⌘B" — for the Settings recorder button.
    var displayString: String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + Self.keyName(for: keyCode)
    }

    /// NSEvent modifier flags → Carbon mask (for the recorder).
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Name for a virtual key code, via the current keyboard layout (falls back to known specials).
    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        // NOT a range check: the F-key virtual keycodes are not numerically ordered
        // (kVK_F1 is 122, kVK_F20 is 90), so `kVK_F1...kVK_F20` builds a range whose
        // lowerBound exceeds its upperBound and traps at runtime for *every* keycode that
        // reaches it — which crashed Beacon whenever the settings window was opened.
        // fKeyNumber's explicit map is the only correct way to recognise these.
        if let number = fKeyNumber(keyCode) { return "F\(number)" }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> String in
            guard let layoutPtr = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "Key \(keyCode)" }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let err = UCKeyTranslate(layoutPtr, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                     UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                     &deadKeyState, chars.count, &length, &chars)
            guard err == noErr, length > 0 else { return "Key \(keyCode)" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }

    private static func fKeyNumber(_ keyCode: UInt32) -> Int? {
        let map: [Int: Int] = [
            kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7,
            kVK_F8: 8, kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12, kVK_F13: 13,
            kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
        ]
        return map[Int(keyCode)]
    }
}
