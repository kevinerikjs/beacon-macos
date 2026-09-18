// VideoQualityManager.swift
// Manages adaptive quality selection for the stream.
// Auto mode: adapts based on quality feedback from iOS. Manual: holds preset.

import Foundation
import Phoros
import PhorosSession
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "VideoQualityManager")

@Observable
final class VideoQualityManager {

    // MARK: - Preference (macOS default, persisted)

    var preferredPreset: QualityPreset {
        didSet {
            UserDefaults.standard.set(preferredPreset.rawValue, forKey: "streamQualityPreset")
            if !hasActiveOverride { resolveAndApply(from: preferredPreset) }
        }
    }

    // MARK: - Active State

    /// Currently active (resolved) preset — never .auto.
    private(set) var activePreset: QualityPreset = .p1080_30

    /// True when the connected iOS client has overridden the macOS default for this session.
    private var hasActiveOverride = false

    // MARK: - Callback

    var onPresetChanged: ((QualityPreset) -> Void)?

    // MARK: - Auto Adaptation

    /// Feedback-driven tier selection with hysteresis lives in PhorosSession; the ladder
    /// (which presets, in which order) is Beacon's policy.
    private var ladder = QualityLadder(tiers: QualityPreset.autoTiers)
    private var autoTimer: DispatchSourceTimer?

    // MARK: - Init

    init() {
        let saved = UserDefaults.standard.string(forKey: "streamQualityPreset") ?? ""
        preferredPreset = QualityPreset(rawValue: saved) ?? .auto
        let initial = preferredPreset == .auto ? QualityPreset.autoTiers.last! : preferredPreset
        activePreset = initial
        ladder.set(initial)
    }

    // MARK: - Session Lifecycle

    func sessionStarted() {
        hasActiveOverride = false
        resolveAndApply(from: preferredPreset)
    }

    func sessionEnded() {
        stopAutoTimer()
        hasActiveOverride = false
    }

    // MARK: - iOS Input

    func receiveQualityFeedback(_ quality: Double) {
        ladder.feedback(quality)
    }

    func handleQualityRequest(_ preset: QualityPreset) {
        hasActiveOverride = true
        if preset == .auto {
            startAutoTimer()
            apply(ladder.current)
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
        guard let next = ladder.evaluate() else { return }
        logger.info("Auto \(next.rawValue)")
        apply(next)
    }

    // MARK: - Helpers

    private func resolveAndApply(from preset: QualityPreset) {
        if preset == .auto {
            startAutoTimer()
            apply(ladder.current)
        } else {
            stopAutoTimer()
            apply(preset)
        }
    }

    private func apply(_ preset: QualityPreset) {
        guard preset != activePreset else { return }
        activePreset = preset
        ladder.set(preset)
        onPresetChanged?(preset)
    }
}
