// ControlChannel.swift
// Sends configured phone-control events to the system on behalf of the connected iPhone.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "ControlChannel")

/// Dispatches configured keyboard, media-key, and macro actions.
enum MediaKeyDispatcher {
    // NX key type constants from IOKit's ev_keymap.h.
    private static let nxKeyTypeSoundUp: Int32 = 0
    private static let nxKeyTypeSoundDown: Int32 = 1
    private static let nxKeyTypeMute: Int32 = 7
    private static let nxKeyTypePlay: Int32 = 16
    private static let nxKeyTypeNext: Int32 = 17
    private static let nxKeyTypePrevious: Int32 = 18

    /// Whether Accessibility permission has been granted, as required to post CGEvents.
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility permission in System Settings.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Sends a configured action when the phone includes a control id. Legacy phone clients only
    /// send `key`, so they retain the original arrow-key and NX media-key behaviour.
    static func send(_ payload: BeamMediaKeyPayload) {
        guard isAccessibilityGranted else {
            logger.warning("Accessibility permission not granted; phone control dropped. Grant access in System Settings > Privacy > Accessibility.")
            return
        }

        if let controlID = payload.controlID,
           let action = PhoneControlsStore.shared.action(forControlID: controlID) {
            perform(action, payload: payload)
        } else {
            performLegacy(payload.key)
        }
    }

    /// Maps phone taps to screen points (BEAM-40). Set by StreamServer at start.
    static var screenPointForTap: ((CGPoint) -> CGPoint?)?

    private static func perform(_ action: PhoneControlAction, payload: BeamMediaKeyPayload) {
        switch action {
        case .textInput(_, let sendReturn):
            guard let text = payload.text, !text.isEmpty else { return }
            typeText(text, sendReturn: sendReturn)
        case .liveKeyboard:
            guard let key = payload.keystroke, !key.isEmpty else { return }
            typeKeystroke(key, modifiers: payload.keystrokeModifiers ?? 0)
        case .modifier:
            // Armed on the phone; arrives here folded into a later keystroke.
            break
        case .click(let fixed):
            guard let click = payload.click else { return }
            guard let point = screenPointForTap?(CGPoint(x: click.x, y: click.y)) else {
                logger.warning("Phone click dropped: nothing is being captured")
                return
            }
            let right: Bool
            switch fixed {
            case .left: right = false
            case .right: right = true
            case .choose: right = click.button == "right"
            }
            postClick(at: point, right: right)
        case .key(let keyCode, let modifiers):
            postKeyPress(keyCode: keyCode, modifiers: modifiers)
        case .mediaKey(let kind):
            postMediaKey(kind)
        case .macro(let id):
            guard let macro = PhoneControlsStore.shared.macro(id: id) else {
                logger.warning("Phone control references a missing macro: \(id.uuidString)")
                return
            }
            replayMacro(macro.steps)
        case .none:
            break
        }
    }

    private static func performLegacy(_ key: BeamMediaKeyPayload.Key) {
        switch key {
        case .seekBackward:
            postKeyPress(keyCode: UInt32(kVK_LeftArrow), modifiers: 0)
        case .seekForward:
            postKeyPress(keyCode: UInt32(kVK_RightArrow), modifiers: 0)
        case .playPause:
            postMediaKey(.playPause)
        case .next:
            postMediaKey(.next)
        case .previous:
            postMediaKey(.previous)
        }
    }

    /// Posts press and release events for an NX media key.
    private static func postMediaKey(_ kind: MediaKeyKind) {
        let keyCode: Int32
        switch kind {
        case .playPause: keyCode = nxKeyTypePlay
        case .next: keyCode = nxKeyTypeNext
        case .previous: keyCode = nxKeyTypePrevious
        case .volumeUp: keyCode = nxKeyTypeSoundUp
        case .volumeDown: keyCode = nxKeyTypeSoundDown
        case .mute: keyCode = nxKeyTypeMute
        }

        let down = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((keyCode << 16) | (0xA << 8)),
            data2: -1
        )
        let up = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xB00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((keyCode << 16) | (0xB << 8)),
            data2: -1
        )
        down?.cgEvent?.post(tap: .cghidEventTap)
        up?.cgEvent?.post(tap: .cghidEventTap)
    }

    private static func postKeyPress(keyCode: UInt32, modifiers: UInt32) {
        postKeyboardEvent(keyCode: keyCode, modifiers: modifiers, isDown: true)
        postKeyboardEvent(keyCode: keyCode, modifiers: modifiers, isDown: false)
    }

    private static func postKeyboardEvent(keyCode: UInt32, modifiers: UInt32, isDown: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(truncatingIfNeeded: keyCode),
            keyDown: isDown
        )
        event?.flags = eventFlags(for: modifiers)
        event?.post(tap: .cghidEventTap)
    }

    /// Replays stored steps off the network queue so a long macro never holds up the session.
    private static func replayMacro(_ steps: [MacroStep]) {
        guard !steps.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for step in steps {
                if step.delayMs > 0 {
                    Thread.sleep(forTimeInterval: TimeInterval(step.delayMs) / 1_000)
                }
                postMacroStep(step)
            }
        }
    }

    private static func postMacroStep(_ step: MacroStep) {
        switch step {
        case .keyDown(let keyCode, let modifiers, _):
            postKeyboardEvent(keyCode: keyCode, modifiers: modifiers, isDown: true)
        case .keyUp(let keyCode, let modifiers, _):
            postKeyboardEvent(keyCode: keyCode, modifiers: modifiers, isDown: false)
        }
    }

    /// One key from the phone keyboard in live mode. Backspace and Return go as their real
    /// keys so terminals and editors treat them as such; everything else as Unicode.
    private static func typeKeystroke(_ key: String, modifiers: UInt32) {
        DispatchQueue.global(qos: .userInitiated).async {
            switch key {
            case "\u{8}", "\u{7f}":
                postKeyPress(keyCode: UInt32(kVK_Delete), modifiers: modifiers)
            case "\n", "\r":
                postKeyPress(keyCode: UInt32(kVK_Return), modifiers: modifiers)
            case "\t":
                postKeyPress(keyCode: UInt32(kVK_Tab), modifiers: modifiers)
            case _ where modifiers != 0:
                // A chord needs a real key code (⌘C is not "⌘ + the letter C as text").
                // Shift is folded into the character the phone already sent when the
                // character has a key; unknown characters fall back to plain typing.
                if let keyCode = ansiKeyCode(for: key) {
                    postKeyPress(keyCode: keyCode, modifiers: modifiers)
                } else {
                    logger.warning("No key code for \"\(key)\"; typing it without modifiers")
                    typeKeystroke(key, modifiers: 0)
                }
            default:
                guard let source = CGEventSource(stateID: .hidSystemState) else { return }
                var units = Array(key.utf16)
                for isDown in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
                    event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    event?.post(tap: .cghidEventTap)
                }
            }
        }
    }

    /// ANSI key code for a typed character, for chords. Letters are case-insensitive.
    private static func ansiKeyCode(for key: String) -> UInt32? {
        let table: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8,
            "9": kVK_ANSI_9, " ": kVK_Space, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, ";": kVK_ANSI_Semicolon,
            "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        ]
        guard key.count == 1, let ch = key.lowercased().first, let code = table[ch] else { return nil }
        return UInt32(code)
    }

    /// Mouse click at a global screen point (BEAM-40): move, press, release. Mouse events need
    /// only Accessibility, unlike a virtual HID device.
    private static func postClick(at point: CGPoint, right: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            let button: CGMouseButton = right ? .right : .left
            let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
            let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?
                .post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: point, mouseButton: button)?
                .post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
            CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: point, mouseButton: button)?
                .post(tap: .cghidEventTap)
            logger.info("Phone click at (\(Int(point.x)), \(Int(point.y))) \(right ? "right" : "left")")
        }
    }

    /// Types arbitrary text into whatever has focus, as Unicode key events so it works on any
    /// keyboard layout, one character per event with a short gap so terminals keep up.
    /// Newlines inside the text are typed as Return too.
    private static func typeText(_ text: String, sendReturn: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            for scalar in text.unicodeScalars {
                if scalar == "\n" || scalar == "\r" {
                    postKeyPress(keyCode: UInt32(kVK_Return), modifiers: 0)
                } else {
                    var unit = Array(String(scalar).utf16)
                    for isDown in [true, false] {
                        let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
                        event?.keyboardSetUnicodeString(stringLength: unit.count, unicodeString: &unit)
                        event?.post(tap: .cghidEventTap)
                    }
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            if sendReturn {
                Thread.sleep(forTimeInterval: 0.05)
                postKeyPress(keyCode: UInt32(kVK_Return), modifiers: 0)
            }
        }
    }

    private static func eventFlags(for modifiers: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        return flags
    }
}
