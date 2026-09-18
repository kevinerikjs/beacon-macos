import CoreMedia
import Foundation
import Phoros

// Beacon's own policy on top of the Phoros wire contract: encoder settings per
// preset, the auto-adaptation ladder, AAC tuning, and the escape hatch that
// forces PCM. None of this is on the wire; the phone has its own copy of what
// it needs.

extension QualityPreset {
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .p360_30: return "360p · 30 fps"
        case .p480_30: return "480p · 30 fps"
        case .p720_30: return "720p · 30 fps"
        case .p720_60: return "720p · 60 fps"
        case .p1080_30: return "1080p · 30 fps"
        case .p1080_60: return "1080p · 60 fps"
        }
    }

    /// Target video bitrate for this preset.
    var bitrateMbps: Double {
        switch self {
        case .auto: return 6
        case .p360_30: return 1.5
        case .p480_30: return 2.5
        case .p720_30: return 4
        case .p720_60: return 6
        case .p1080_30: return 6
        case .p1080_60: return 10
        }
    }

    /// The ladder `.auto` climbs and descends, lowest first.
    static let autoTiers: [QualityPreset] = [.p360_30, .p480_30, .p720_30, .p1080_30]
}

extension AudioCodecID {
    /// UserDefaults key, identical on both platforms, that forces the legacy PCM path.
    /// Escape hatch for a bad release; the macOS half self-updates via Sparkle.
    static let forcePCMDefaultsKey = "BeamForcePCMAudio"

    /// AAC bitrate for the active video preset. Bound to the preset because it is the only
    /// signal the host has for a constrained link, and the auto-tiering already drives it
    /// down on exactly those links. Halved for mono. Never above 160 kbps, which is what
    /// keeps one access unit inside a single 1400-byte packet (audio is never fragmented).
    static func aacBitrate(for preset: QualityPreset, channels: Int) -> Int {
        let stereoRate: Int
        switch preset {
        case .p360_30: stereoRate = 64_000
        case .p480_30: stereoRate = 96_000
        case .p720_30, .p720_60, .p1080_30, .p1080_60, .auto: stereoRate = 128_000
        }
        return channels <= 1 ? stereoRate / 2 : min(stereoRate, 160_000)
    }
}

extension CMTime {
    /// This time on the wire clock: microseconds, the unit every Phoros timestamp uses.
    var microseconds: Int64 {
        guard timescale != 0 else { return 0 }
        return Int64(Double(value) / Double(timescale) * 1_000_000)
    }
}

import PhorosInput

extension GamepadProfile {
    /// UserDefaults key for the identity Beacon's virtual controller presents.
    static let defaultsKey = "BeaconVirtualControllerProfile"

    /// The stored choice, Xbox when unset. Xbox and PlayStation are adopted by
    /// macOS's GameController framework, so every game sees the same layout;
    /// Generic only reaches games that read raw HID and guess.
    static var selected: GamepadProfile {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(GamepadProfile.init(rawValue:)) ?? .xboxOne }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var displayName: String {
        switch self {
        case .xboxOne: return "Xbox controller"
        case .dualShock4: return "PlayStation controller (DualShock 4)"
        case .generic: return "Generic gamepad"
        }
    }
}
