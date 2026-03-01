// VideoQualityManager.swift
// Manages adaptive quality selection for the stream.
// Auto mode: adapts based on quality feedback from iOS. Manual: holds preset.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "VideoQualityManager")

@Observable
final class VideoQualityManager {

    // MARK: - Preference (macOS default, persisted)

    var preferredPreset: StreamQualityPreset {
        didSet {
            UserDefaults.standard.set(preferredPreset.rawValue, forKey: "streamQualityPreset")
            if !hasActiveOverride { resolveAndApply(from: preferredPreset) }
        }
    }

    // MARK: - Active State

    /// Currently active (resolved) preset — never .auto.
    private(set) var activePreset: StreamQualityPreset = .p1080_30

    /// True when the connected iOS client has overridden the macOS default for this session.
    private var hasActiveOverride = false

    // MARK: - Callback

    var onPresetChanged: ((StreamQualityPreset) -> Void)?

    // MARK: - Auto Adaptation

    private static let tiers = StreamQualityPreset.autoTiers
    private var tierIndex: Int = StreamQualityPreset.autoTiers.count - 1  // start at top tier

    private var lastChangeTime: Date = .distantPast
    private var sustainedLowStart: Date?
    private var sustainedHighStart: Date?
    private var latestQuality: Double = 1.0
    private var autoTimer: DispatchSourceTimer?

    private static let stepDownThreshold: Double  = 0.45
    private static let stepUpThreshold: Double    = 0.80
    private static let sustainedLowSecs: TimeInterval  = 3.0
    private static let sustainedHighSecs: TimeInterval = 12.0
    private static let minChangeInterval: TimeInterval = 6.0

    // MARK: - Init

    init() {
        let saved = UserDefaults.standard.string(forKey: "streamQualityPreset") ?? ""
        preferredPreset = StreamQualityPreset(rawValue: saved) ?? .auto
        let initial = preferredPreset == .auto ? Self.tiers.last! : preferredPreset
        activePreset = initial
        tierIndex = Self.tiers.firstIndex(of: initial) ?? Self.tiers.count - 1
    }

    // MARK: - Session Lifecycle

    func sessionStarted() {
        hasActiveOverride = false
        resolveAndApply(from: preferredPreset)
    }

    func sessionEnded() {
        stopAutoTimer()
        hasActiveOverride = false
        sustainedLowStart = nil
        sustainedHighStart = nil
    }

    // MARK: - iOS Input

    func receiveQualityFeedback(_ quality: Double) {
        latestQuality = quality
    }

    func handleQualityRequest(_ preset: StreamQualityPreset) {
        hasActiveOverride = true
        if preset == .auto {
            startAutoTimer()
            apply(Self.tiers[tierIndex])
        } else {
            stopAutoTimer()
            apply(preset)
        }
        logger.info("iOS quality request: \(preset.rawValue) → active: \(self.activePreset.rawValue)")
    }

    // MARK: - Auto Timer

    private func startAutoTimer() {
        stopAutoTimer()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.evaluate() }
        timer.resume()
        autoTimer = timer
    }

    private func stopAutoTimer() {
        autoTimer?.cancel()
        autoTimer = nil
    }

    // MARK: - Evaluation

    private func evaluate() {
        let q = latestQuality
        let now = Date()

        if q < Self.stepDownThreshold {
            sustainedHighStart = nil
            if sustainedLowStart == nil { sustainedLowStart = now }
            if let s = sustainedLowStart,
               now.timeIntervalSince(s) >= Self.sustainedLowSecs,
               now.timeIntervalSince(lastChangeTime) >= Self.minChangeInterval { stepDown() }
        } else if q > Self.stepUpThreshold {
            sustainedLowStart = nil
            if sustainedHighStart == nil { sustainedHighStart = now }
            if let s = sustainedHighStart,
               now.timeIntervalSince(s) >= Self.sustainedHighSecs,
               now.timeIntervalSince(lastChangeTime) >= Self.minChangeInterval { stepUp() }
        } else {
            sustainedLowStart = nil
            sustainedHighStart = nil
        }
    }

    private func stepDown() {
        guard tierIndex > 0 else { return }
        tierIndex -= 1
        let p = Self.tiers[tierIndex]
        logger.info("Auto ▼ \(p.rawValue)")
        apply(p); sustainedLowStart = nil
    }

    private func stepUp() {
        guard tierIndex < Self.tiers.count - 1 else { return }
        tierIndex += 1
        let p = Self.tiers[tierIndex]
        logger.info("Auto ▲ \(p.rawValue)")
        apply(p); sustainedHighStart = nil
    }

    // MARK: - Helpers

    private func resolveAndApply(from preset: StreamQualityPreset) {
        if preset == .auto {
            startAutoTimer()
            apply(Self.tiers[tierIndex])
        } else {
            stopAutoTimer()
            apply(preset)
        }
    }

    private func apply(_ preset: StreamQualityPreset) {
        guard preset != activePreset else { return }
        lastChangeTime = Date()
        activePreset = preset
        if let idx = Self.tiers.firstIndex(of: preset) { tierIndex = idx }
        onPresetChanged?(preset)
    }
}
