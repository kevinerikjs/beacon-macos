// ControlChannel.swift
// Turns a phone control press into system events. The event posting itself
// (keystrokes, text, media keys, clicks) is PhorosInput.InputReplay. What stays here is
// Beacon policy: which configured action a control id maps to, macros, and the
// left/right choice for click buttons.

import Foundation
import OSLog
import Phoros
import PhorosInput

private let logger = Logger(subsystem: "com.beam.beacon", category: "ControlChannel")

/// Dispatches configured keyboard, media-key, and macro actions.
enum MediaKeyDispatcher {
    /// Whether Accessibility permission has been granted, as required to post events.
    static var isAccessibilityGranted: Bool { InputReplay.isAccessibilityGranted }

    /// Prompt the user to grant Accessibility permission in System Settings.
    static func requestAccessibilityPermission() { InputReplay.requestAccessibilityPermission() }

    /// Maps phone taps to screen points (BEAM-40). Set by StreamServer at start.
    static var screenPointForTap: ((CGPoint) -> CGPoint?)?

    /// Sends a configured action when the phone includes a control id. Legacy phone clients only
    /// send `key`, so they retain the original arrow-key and NX media-key behaviour.
    static func send(_ payload: MediaKeyCommand) {
        guard isAccessibilityGranted else {
            logger.warning("Accessibility permission not granted; phone control dropped. Grant access in System Settings > Privacy > Accessibility.")
            return
        }

        if let controlID = payload.controlID,
           let action = PhoneControlsStore.shared.action(forControlID: controlID) {
            perform(action, payload: payload)
        } else {
            InputReplay.perform(payload.key)
        }
    }

    private static func perform(_ action: PhoneControlAction, payload: MediaKeyCommand) {
        switch action {
        case .textInput(_, let sendReturn):
            guard let text = payload.text, !text.isEmpty else { return }
            InputReplay.typeText(text, thenReturn: sendReturn)
        case .liveKeyboard:
            guard let key = payload.keystroke, !key.isEmpty else { return }
            InputReplay.typeKeystroke(key, modifiers: KeyModifiers(rawValue: payload.keystrokeModifiers ?? 0))
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
            InputReplay.click(at: point, right: right)
            logger.info("Phone click at (\(Int(point.x)), \(Int(point.y))) \(right ? "right" : "left")")
        case .key(let keyCode, let modifiers):
            InputReplay.pressKey(code: keyCode, modifiers: KeyModifiers(rawValue: modifiers))
        case .mediaKey(let kind):
            InputReplay.postMediaKey(kind.replayKey)
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

    /// Replays stored steps off the network queue so a long macro never holds up the session.
    private static func replayMacro(_ steps: [MacroStep]) {
        guard !steps.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for step in steps {
                if step.delayMs > 0 {
                    Thread.sleep(forTimeInterval: TimeInterval(step.delayMs) / 1_000)
                }
                switch step {
                case .keyDown(let keyCode, let modifiers, _):
                    InputReplay.postKey(code: keyCode, modifiers: KeyModifiers(rawValue: modifiers), down: true)
                case .keyUp(let keyCode, let modifiers, _):
                    InputReplay.postKey(code: keyCode, modifiers: KeyModifiers(rawValue: modifiers), down: false)
                }
            }
        }
    }
}

private extension MediaKeyKind {
    var replayKey: InputReplay.MediaKey {
        switch self {
        case .playPause: return .playPause
        case .next: return .next
        case .previous: return .previous
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        case .mute: return .mute
        }
    }
}
