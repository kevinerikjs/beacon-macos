// Phone-control layouts and reusable macros for the iPhone remote.

import Carbon.HIToolbox
import Foundation
import Observation

enum MediaKeyKind: String, Codable, CaseIterable, Identifiable {
    case playPause
    case next
    case previous
    case volumeUp
    case volumeDown
    case mute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playPause: return "Play/Pause"
        case .next: return "Next"
        case .previous: return "Previous"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        }
    }
}

enum PhoneControlAction: Codable, Equatable {
    case key(keyCode: UInt32, modifiers: UInt32)
    case mediaKey(MediaKeyKind)
    case macro(id: UUID)
    /// The phone asks its user for text first, then the host types it as key presses (and
    /// Return when `sendReturn`). `prompt` is the input box title shown on the phone.
    case textInput(prompt: String, sendReturn: Bool)
    case none

    enum Kind: String, CaseIterable, Identifiable, Codable {
        case key
        case mediaKey
        case macro
        case textInput
        case none

        var id: String { rawValue }

        var title: String {
            switch self {
            case .key: return "Key or shortcut"
            case .mediaKey: return "Media key"
            case .macro: return "Macro"
            case .textInput: return "Ask for text"
            case .none: return "Nothing"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .key: return .key
        case .mediaKey: return .mediaKey
        case .macro: return .macro
        case .textInput: return .textInput
        case .none: return .none
        }
    }

    func replacingKind(_ kind: Kind) -> PhoneControlAction {
        guard kind != self.kind else { return self }
        switch kind {
        case .key: return .key(keyCode: UInt32(kVK_Space), modifiers: 0)
        case .mediaKey: return .mediaKey(.playPause)
        case .macro: return .macro(id: PhoneControlsStore.shared.macros.first?.id ?? UUID())
        case .textInput: return .textInput(prompt: "", sendReturn: true)
        case .none: return .none
        }
    }

    private enum CodingKeys: String, CodingKey { case type, keyCode, modifiers, mediaKey, macroID, prompt, sendReturn }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .key:
            self = .key(
                keyCode: try container.decode(UInt32.self, forKey: .keyCode),
                modifiers: try container.decode(UInt32.self, forKey: .modifiers)
            )
        case .mediaKey:
            self = .mediaKey(try container.decode(MediaKeyKind.self, forKey: .mediaKey))
        case .macro:
            self = .macro(id: try container.decode(UUID.self, forKey: .macroID))
        case .textInput:
            self = .textInput(
                prompt: try container.decodeIfPresent(String.self, forKey: .prompt) ?? "",
                sendReturn: try container.decodeIfPresent(Bool.self, forKey: .sendReturn) ?? true
            )
        case .none:
            self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case .key(let keyCode, let modifiers):
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
        case .mediaKey(let kind):
            try container.encode(kind, forKey: .mediaKey)
        case .macro(let id):
            try container.encode(id, forKey: .macroID)
        case .textInput(let prompt, let sendReturn):
            try container.encode(prompt, forKey: .prompt)
            try container.encode(sendReturn, forKey: .sendReturn)
        case .none:
            break
        }
    }
}

/// One recorded key transition. Modifiers are the chord state at that moment so a replayed
/// ⌘C carries ⌘ on both the down and the up. `delayMs` is the gap since the previous step.
enum MacroStep: Codable, Equatable {
    case keyDown(keyCode: UInt32, modifiers: UInt32, delayMs: UInt32)
    case keyUp(keyCode: UInt32, modifiers: UInt32, delayMs: UInt32)

    var delayMs: UInt32 {
        switch self {
        case .keyDown(_, _, let delayMs), .keyUp(_, _, let delayMs):
            return delayMs
        }
    }

    private enum CodingKeys: String, CodingKey { case type, keyCode, modifiers, delayMs }
    private enum StepType: String, Codable { case keyDown, keyUp }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let delayMs = try container.decode(UInt32.self, forKey: .delayMs)
        let keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        let modifiers = try container.decode(UInt32.self, forKey: .modifiers)
        switch try container.decode(StepType.self, forKey: .type) {
        case .keyDown: self = .keyDown(keyCode: keyCode, modifiers: modifiers, delayMs: delayMs)
        case .keyUp:   self = .keyUp(keyCode: keyCode, modifiers: modifiers, delayMs: delayMs)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(delayMs, forKey: .delayMs)
        switch self {
        case .keyDown(let keyCode, let modifiers, _):
            try container.encode(StepType.keyDown, forKey: .type)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
        case .keyUp(let keyCode, let modifiers, _):
            try container.encode(StepType.keyUp, forKey: .type)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
        }
    }
}

struct Macro: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var steps: [MacroStep]
}

struct PhoneControlButton: Codable, Equatable, Identifiable {
    let id: UUID
    var symbol: String
    var label: String
    var prominent: Bool
    var action: PhoneControlAction
}

struct PhoneControlLayout: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let isBuiltIn: Bool
    var buttons: [PhoneControlButton]
}

@Observable
final class PhoneControlsStore {
    static let shared = PhoneControlsStore()

    private static let defaultsKey = "phoneControlsStore"

    var layouts: [PhoneControlLayout]
    var activeLayoutID: UUID
    var macros: [Macro]

    private init() {
        if let saved = Self.load() {
            var loadedLayouts = saved.layouts.isEmpty ? [Self.defaultLayout] : saved.layouts
            // The built-in layout was persisted before the keyboard button existed: append it
            // once so upgraded installs get the same default as fresh ones.
            if let index = loadedLayouts.firstIndex(where: { $0.isBuiltIn }),
               loadedLayouts[index].buttons.count < 7,
               !loadedLayouts[index].buttons.contains(where: { $0.action.kind == .textInput }) {
                loadedLayouts[index].buttons.append(
                    PhoneControlButton(id: UUID(), symbol: "keyboard", label: "Keyboard Input", prominent: false,
                                       action: .textInput(prompt: "", sendReturn: true))
                )
            }
            layouts = loadedLayouts
            activeLayoutID = loadedLayouts.contains(where: { $0.id == saved.activeLayoutID })
                ? saved.activeLayoutID : loadedLayouts[0].id
            macros = saved.macros
        } else {
            layouts = [Self.defaultLayout]
            activeLayoutID = Self.defaultLayout.id
            macros = []
            persist()
        }
    }

    var activeLayout: PhoneControlLayout {
        layouts.first(where: { $0.id == activeLayoutID }) ?? layouts[0]
    }

    func layout(id: UUID) -> PhoneControlLayout? {
        layouts.first(where: { $0.id == id })
    }

    func action(forControlID id: String) -> PhoneControlAction? {
        guard let buttonID = UUID(uuidString: id) else { return nil }
        return activeLayout.buttons.first(where: { $0.id == buttonID })?.action
    }

    func wireControls() -> [BeamPhoneControl] {
        activeLayout.buttons.map { button in
            var control = BeamPhoneControl(
                id: button.id.uuidString,
                symbol: button.symbol,
                label: button.label,
                prominent: button.prominent ? true : nil
            )
            if case .textInput(let prompt, _) = button.action {
                control.promptsForText = true
                control.textPrompt = prompt.isEmpty ? nil : prompt
            }
            return control
        }
    }

    func createLayout() {
        let layout = PhoneControlLayout(
            id: UUID(), name: uniqueLayoutName("New Layout"), isBuiltIn: false,
            buttons: [Self.makeBlankButton()]
        )
        layouts.append(layout)
        activeLayoutID = layout.id
        persist()
    }

    func duplicateLayout(_ layout: PhoneControlLayout) {
        let copy = PhoneControlLayout(
            id: UUID(), name: uniqueLayoutName("\(layout.name) Copy"), isBuiltIn: false,
            buttons: layout.buttons.map {
                PhoneControlButton(
                    id: UUID(), symbol: $0.symbol, label: $0.label,
                    prominent: $0.prominent, action: $0.action
                )
            }
        )
        layouts.append(copy)
        activeLayoutID = copy.id
        persist()
    }

    func renameLayout(id: UUID, to name: String) {
        guard let index = layouts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        layouts[index].name = trimmed.isEmpty ? "Untitled Layout" : trimmed
        persist()
    }

    func deleteLayout(id: UUID) {
        guard let index = layouts.firstIndex(where: { $0.id == id }), !layouts[index].isBuiltIn else { return }
        layouts.remove(at: index)
        if activeLayoutID == id { activeLayoutID = layouts[0].id }
        persist()
    }

    func setActiveLayout(_ id: UUID) {
        guard layouts.contains(where: { $0.id == id }) else { return }
        activeLayoutID = id
        persist()
    }

    func updateButton(layoutID: UUID, buttonID: UUID, _ update: (inout PhoneControlButton) -> Void) {
        guard let layoutIndex = layouts.firstIndex(where: { $0.id == layoutID }),
              let buttonIndex = layouts[layoutIndex].buttons.firstIndex(where: { $0.id == buttonID }) else { return }
        update(&layouts[layoutIndex].buttons[buttonIndex])
        persist()
    }

    func setProminent(layoutID: UUID, buttonID: UUID, isProminent: Bool) {
        guard let layoutIndex = layouts.firstIndex(where: { $0.id == layoutID }) else { return }
        for index in layouts[layoutIndex].buttons.indices {
            if layouts[layoutIndex].buttons[index].id == buttonID {
                layouts[layoutIndex].buttons[index].prominent = isProminent
            } else if isProminent {
                layouts[layoutIndex].buttons[index].prominent = false
            }
        }
        persist()
    }

    func addButton(to layoutID: UUID) {
        guard let index = layouts.firstIndex(where: { $0.id == layoutID }),
              layouts[index].buttons.count < 7 else { return }
        layouts[index].buttons.append(Self.makeBlankButton())
        persist()
    }

    func removeButton(layoutID: UUID, buttonID: UUID) {
        guard let layoutIndex = layouts.firstIndex(where: { $0.id == layoutID }),
              layouts[layoutIndex].buttons.count > 1,
              let buttonIndex = layouts[layoutIndex].buttons.firstIndex(where: { $0.id == buttonID }) else { return }
        layouts[layoutIndex].buttons.remove(at: buttonIndex)
        persist()
    }

    func moveButton(layoutID: UUID, buttonID: UUID, by offset: Int) {
        guard let layoutIndex = layouts.firstIndex(where: { $0.id == layoutID }),
              let fromIndex = layouts[layoutIndex].buttons.firstIndex(where: { $0.id == buttonID }) else { return }
        let toIndex = fromIndex + offset
        guard layouts[layoutIndex].buttons.indices.contains(toIndex) else { return }
        let button = layouts[layoutIndex].buttons.remove(at: fromIndex)
        layouts[layoutIndex].buttons.insert(button, at: toIndex)
        persist()
    }

    func macro(id: UUID) -> Macro? {
        macros.first(where: { $0.id == id })
    }

    func saveMacro(_ macro: Macro) {
        if let index = macros.firstIndex(where: { $0.id == macro.id }) {
            macros[index] = macro
        } else {
            macros.append(macro)
        }
        persist()
    }

    func deleteMacro(id: UUID) {
        macros.removeAll { $0.id == id }
        for layoutIndex in layouts.indices {
            for buttonIndex in layouts[layoutIndex].buttons.indices {
                if case .macro(let macroID) = layouts[layoutIndex].buttons[buttonIndex].action,
                   macroID == id {
                    layouts[layoutIndex].buttons[buttonIndex].action = .none
                }
            }
        }
        persist()
    }

    private func uniqueLayoutName(_ name: String) -> String {
        let names = Set(layouts.map { $0.name.lowercased() })
        guard names.contains(name.lowercased()) else { return name }
        var number = 2
        while names.contains("\(name) \(number)".lowercased()) { number += 1 }
        return "\(name) \(number)"
    }

    private func persist() {
        let stored = StoredLayouts(layouts: layouts, activeLayoutID: activeLayoutID, macros: macros)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> StoredLayouts? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(StoredLayouts.self, from: data)
    }

    private struct StoredLayouts: Codable {
        var layouts: [PhoneControlLayout]
        var activeLayoutID: UUID
        var macros: [Macro]
    }

    private static func makeBlankButton() -> PhoneControlButton {
        PhoneControlButton(id: UUID(), symbol: "circle", label: "Button", prominent: false, action: .none)
    }

    private static let defaultLayout = PhoneControlLayout(
        id: UUID(), name: "Default", isBuiltIn: true,
        buttons: [
            PhoneControlButton(id: UUID(), symbol: "arrow.counterclockwise", label: "Seek Back", prominent: false,
                               action: .key(keyCode: UInt32(kVK_LeftArrow), modifiers: 0)),
            PhoneControlButton(id: UUID(), symbol: "backward.fill", label: "Previous", prominent: false,
                               action: .mediaKey(.previous)),
            PhoneControlButton(id: UUID(), symbol: "playpause.fill", label: "Play/Pause", prominent: true,
                               action: .mediaKey(.playPause)),
            PhoneControlButton(id: UUID(), symbol: "forward.fill", label: "Next", prominent: false,
                               action: .mediaKey(.next)),
            PhoneControlButton(id: UUID(), symbol: "arrow.clockwise", label: "Seek Forward", prominent: false,
                               action: .key(keyCode: UInt32(kVK_RightArrow), modifiers: 0)),
            PhoneControlButton(id: UUID(), symbol: "keyboard", label: "Keyboard Input", prominent: false,
                               action: .textInput(prompt: "", sendReturn: true))
        ]
    )
}
