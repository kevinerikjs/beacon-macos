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
            perform(action, text: payload.text)
        } else {
            performLegacy(payload.key)
        }
    }

    private static func perform(_ action: PhoneControlAction, text: String?) {
        switch action {
        case .textInput(_, let sendReturn):
            guard let text, !text.isEmpty else { return }
            typeText(text, sendReturn: sendReturn)
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
