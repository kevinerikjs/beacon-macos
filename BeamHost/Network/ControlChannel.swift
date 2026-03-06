// ControlChannel.swift
// Sends media key events to the system on behalf of the connected iPhone.

import AppKit
import ApplicationServices
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

        switch key {
        case .seekBackward:
            logger.info("Sending key: left arrow")
            postKeyEvent(keyCode: 123)
        case .seekForward:
            logger.info("Sending key: right arrow")
            postKeyEvent(keyCode: 124)
        default:
            let keyCode: Int32
            switch key {
            case .playPause:  keyCode = NX_KEYTYPE_PLAY
            case .next:       keyCode = NX_KEYTYPE_NEXT
            case .previous:   keyCode = NX_KEYTYPE_PREVIOUS
            default:          return
            }
            logger.info("Sending media key: \(key.rawValue)")
            postMediaKey(keyCode: keyCode)
        }
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

    /// Posts a regular keyboard key press+release (for arrow keys, etc.).
    private static func postKeyEvent(keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
