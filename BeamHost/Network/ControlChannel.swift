// ControlChannel.swift
// Sends media key events to the system on behalf of the connected iPhone.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "ControlChannel")

/// Dispatches media key events to macOS system media controls.
enum MediaKeyDispatcher {

    // NX key type constants (from IOKit's ev_keymap.h)
    private static let NX_KEYTYPE_PLAY: Int32       = 16
    private static let NX_KEYTYPE_NEXT: Int32       = 17
    private static let NX_KEYTYPE_PREVIOUS: Int32   = 18
    private static let NX_KEYTYPE_FAST: Int32       = 19
    private static let NX_KEYTYPE_REWIND: Int32     = 20

    /// Whether Accessibility permission has been granted (required to post CGEvents).
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility permission (opens System Settings).
    static func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// Sends the media key event corresponding to the given control command.
    /// No-op (with a log warning) if Accessibility permission has not been granted.
    static func send(_ key: BeamMediaKeyPayload.Key) {
        guard isAccessibilityGranted else {
            logger.warning("Accessibility permission not granted — media key '\(key.rawValue)' dropped. Grant access in System Settings > Privacy > Accessibility.")
            return
        }

        switch PhoneControlsStore.shared.action(for: key) {
        case .arrowKeys:
            guard let keyCode = keyboardKeyCode(for: key) else { return }
            logger.info("Sending keyboard key: \(key.rawValue)")
            postKeyEvent(keyCode: keyCode)
        case .jlKeys:
            guard let keyCode = jlKeyCode(for: key) else { return }
            logger.info("Sending J/L key: \(key.rawValue)")
            postKeyEvent(keyCode: keyCode)
        case .shiftArrows:
            guard let keyCode = keyboardKeyCode(for: key) else { return }
            logger.info("Sending Shift key: \(key.rawValue)")
            postChord(keyCode: keyCode, modifiers: UInt32(shiftKey))
        case .mediaKeys:
            sendMediaKey(for: key)
        case .shortcut(let keyCode, let modifiers):
            logger.info("Sending shortcut: \(key.rawValue)")
            postChord(keyCode: keyCode, modifiers: modifiers)
        case .macro(let steps):
            logger.info("Sending macro: \(key.rawValue), \(steps.count) steps")
            replayMacro(steps)
        }
    }

    private static func keyboardKeyCode(for key: BeamMediaKeyPayload.Key) -> UInt32? {
        switch key {
        case .seekBackward: return UInt32(kVK_LeftArrow)
        case .seekForward:  return UInt32(kVK_RightArrow)
        case .playPause:    return UInt32(kVK_Space)
        case .next, .previous: return nil
        }
    }

    private static func jlKeyCode(for key: BeamMediaKeyPayload.Key) -> UInt32? {
        switch key {
        case .seekBackward: return UInt32(kVK_ANSI_J)
        case .seekForward:  return UInt32(kVK_ANSI_L)
        case .playPause:    return UInt32(kVK_ANSI_K)
        case .next, .previous: return nil
        }
    }

    private static func sendMediaKey(for key: BeamMediaKeyPayload.Key) {
        let keyCode: Int32
        switch key {
        case .playPause:  keyCode = NX_KEYTYPE_PLAY
        case .next:       keyCode = NX_KEYTYPE_NEXT
        case .previous:   keyCode = NX_KEYTYPE_PREVIOUS
        case .seekBackward: keyCode = NX_KEYTYPE_PREVIOUS
        case .seekForward:  keyCode = NX_KEYTYPE_NEXT
        }
        logger.info("Sending media key: \(key.rawValue)")
        postMediaKey(keyCode: keyCode)
    }

    /// Posts a CGEvent media key press+release to the system event stream.
    private static func postMediaKey(keyCode: Int32) {
        // Media keys use NX events packed into a CGEvent
        // This technique works for system-wide media key events (Spotify, Apple Music, etc.)
        let keyDownEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,   // NX_SUBTYPE_AUX_MOUSE_BUTTONS not right, use 8 for media
            data1: Int((keyCode << 16) | (0xA << 8)),
            data2: -1
        )

        let keyUpEvent = NSEvent.otherEvent(
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

        keyDownEvent?.cgEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.cgEvent?.post(tap: .cghidEventTap)
    }

    /// Posts a regular keyboard key press+release with Carbon modifier masks.
    private static func postChord(keyCode: UInt32, modifiers: UInt32) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let flags = eventFlags(for: modifiers)
        let virtualKey = CGKeyCode(truncatingIfNeeded: keyCode)

        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Replays a macro away from the control connection's network queue.
    private static func replayMacro(_ steps: [MacroStep]) {
        guard !steps.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            for step in steps {
                if step.delayMs > 0 {
                    Thread.sleep(forTimeInterval: TimeInterval(step.delayMs) / 1_000)
                }
                postChord(keyCode: step.keyCode, modifiers: step.modifiers)
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

    /// Posts a regular keyboard key press+release (for arrow keys, etc.).
    private static func postKeyEvent(keyCode: UInt32) {
        postChord(keyCode: keyCode, modifiers: 0)
    }
}
