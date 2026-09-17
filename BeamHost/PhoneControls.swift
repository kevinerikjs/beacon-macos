// Configurable actions for the media controls shown on the iPhone.

import Foundation
import Observation

struct MacroStep: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let delayMs: UInt32
}

enum PhoneControlAction: Codable, Equatable {
    case arrowKeys
    case jlKeys
    case shiftArrows
    case mediaKeys
    case shortcut(keyCode: UInt32, modifiers: UInt32)
    case macro([MacroStep])

    enum Preset: String, CaseIterable, Codable, Identifiable {
        case arrowKeys = "arrow_keys"
        case jlKeys = "jl_keys"
        case shiftArrows = "shift_arrows"
        case mediaKeys = "media_keys"
        case shortcut
        case macro

        var id: String { rawValue }

        var title: String {
            switch self {
            case .arrowKeys:    return "Arrow keys"
            case .jlKeys:       return "J / L keys"
            case .shiftArrows:  return "Shift + arrows"
            case .mediaKeys:    return "Media keys"
            case .shortcut:     return "Keyboard shortcut"
            case .macro:        return "Macro"
            }
        }
    }

    var preset: Preset {
        switch self {
        case .arrowKeys:             return .arrowKeys
        case .jlKeys:                return .jlKeys
        case .shiftArrows:           return .shiftArrows
        case .mediaKeys:             return .mediaKeys
        case .shortcut:              return .shortcut
        case .macro:                  return .macro
        }
    }

    /// Changes the preset while preserving an existing shortcut or macro when possible.
    func replacingPreset(_ preset: Preset) -> PhoneControlAction {
        switch preset {
        case .arrowKeys:    return .arrowKeys
        case .jlKeys:       return .jlKeys
        case .shiftArrows:  return .shiftArrows
        case .mediaKeys:    return .mediaKeys
        case .shortcut:
            if case .shortcut = self { return self }
            return .shortcut(keyCode: 0, modifiers: 0)
        case .macro:
            if case .macro = self { return self }
            return .macro([])
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case keyCode
        case modifiers
        case steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Preset.self, forKey: .type)

        switch type {
        case .arrowKeys:    self = .arrowKeys
        case .jlKeys:       self = .jlKeys
        case .shiftArrows:  self = .shiftArrows
        case .mediaKeys:    self = .mediaKeys
        case .shortcut:
            self = .shortcut(
                keyCode: try container.decode(UInt32.self, forKey: .keyCode),
                modifiers: try container.decode(UInt32.self, forKey: .modifiers)
            )
        case .macro:
            self = .macro(try container.decode([MacroStep].self, forKey: .steps))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .type)

        switch self {
        case .shortcut(let keyCode, let modifiers):
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
        case .macro(let steps):
            try container.encode(steps, forKey: .steps)
        default:
            break
        }
    }
}

struct PhoneControlConfig: Codable, Equatable {
    var action: PhoneControlAction
    var symbol: String
    var label: String
}

@Observable
final class PhoneControlsStore {

    static let shared = PhoneControlsStore()
    static let buttonIDs = ["seek_backward", "seek_forward", "play_pause"]

    private static let defaultsKey = "phoneControlConfigs"

    private(set) var configs: [String: PhoneControlConfig]

    private init() {
        configs = Self.loadConfigs()
    }

    func config(for id: String) -> PhoneControlConfig {
        configs[id] ?? Self.defaultConfig(for: id)
    }

    func action(for key: BeamMediaKeyPayload.Key) -> PhoneControlAction {
        guard let id = Self.buttonID(for: key) else { return .mediaKeys }
        return config(for: id).action
    }

    func setConfig(_ config: PhoneControlConfig, for id: String) {
        guard Self.buttonIDs.contains(id) else { return }
        configs[id] = config
        persist()
    }

    func wireControls() -> [BeamPhoneControl] {
        Self.buttonIDs.map { id in
            let config = config(for: id)
            return BeamPhoneControl(id: id, symbol: config.symbol, label: config.label)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func loadConfigs() -> [String: PhoneControlConfig] {
        var loaded = Dictionary(uniqueKeysWithValues: buttonIDs.map { ($0, defaultConfig(for: $0)) })

        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([String: PhoneControlConfig].self, from: data) else {
            return loaded
        }

        for id in buttonIDs {
            if let config = saved[id] {
                loaded[id] = config
            }
        }
        return loaded
    }

    private static func buttonID(for key: BeamMediaKeyPayload.Key) -> String? {
        switch key {
        case .seekBackward: return "seek_backward"
        case .seekForward:  return "seek_forward"
        case .playPause:    return "play_pause"
        case .next, .previous: return nil
        }
    }

    private static func defaultConfig(for id: String) -> PhoneControlConfig {
        switch id {
        case "seek_backward":
            return PhoneControlConfig(action: .arrowKeys, symbol: "gobackward", label: "Rewind")
        case "seek_forward":
            return PhoneControlConfig(action: .arrowKeys, symbol: "goforward", label: "Fast Forward")
        case "play_pause":
            return PhoneControlConfig(action: .mediaKeys, symbol: "playpause.fill", label: "Play/Pause")
        default:
            return PhoneControlConfig(action: .mediaKeys, symbol: "questionmark", label: id)
        }
    }
}
