// AudioEncoder.swift
// Normalizes ScreenCaptureKit audio to Float32 interleaved PCM and, when at least one
// connected client has advertised AAC support, additionally encodes it to AAC-LC.
//
// Output: (a) Float32 interleaved PCM — always produced, the legacy wire format
//         (b) raw AAC-LC access units — produced only while `isAACOutputEnabled` is true
//             and the PhorosMedia encoder is healthy.
//
// StreamServer sends each output only to sessions that negotiated its codec. The
// encoding itself lives in PhorosMedia; what stays here is Beacon policy: when AAC is
// worth producing at all, and how to retry after a converter failure.

import CoreMedia
import Foundation
import OSLog
import Phoros
import PhorosMedia

private let logger = Logger(subsystem: "com.beam.beacon", category: "AudioEncoder")

// MARK: - Delegate

protocol HostAudioEncoderDelegate: AnyObject {
    /// Float32 interleaved PCM, PTS = the source CMSampleBuffer's PTS. Always produced.
    func audioEncoder(_ encoder: HostAudioEncoder, didProducePCMChunk data: Data, presentationTime: CMTime)
    /// One raw AAC-LC access unit, no ADTS. PTS is priming-compensated by PhorosMedia.
    func audioEncoder(_ encoder: HostAudioEncoder, didProduceAACChunk data: Data, presentationTime: CMTime)
    func audioEncoder(_ encoder: HostAudioEncoder, didUpdateSampleRate sampleRate: Double, channels: Int)
}

// MARK: - HostAudioEncoder

final class HostAudioEncoder {

    weak var delegate: HostAudioEncoderDelegate?
    private let encoderQueue = DispatchQueue(label: "com.beam.beacon.audioencoder", qos: .userInteractive)
    private var isRunning = false
    private var lastPublishedSampleRate: Double = 0
    private var lastPublishedChannels: Int = 0

    // MARK: - AAC state (encoderQueue only)

    private let aac = AACEncoder()
    /// AAC encoding is disabled while this is true. It used to be a life sentence — cleared
    /// only by start()/stop() — so a single transient converter error killed audio for
    /// every AAC client until the last one disconnected. It is now a retry with backoff.
    private var aacFailedAt: Date?
    private var aacFailureCount = 0
    private static let maxAACRetries = 20
    private static let aacRetryBackoff: TimeInterval = 2.0
    private var _isAACOutputEnabled = false

    /// Set by StreamServer whenever the set of authenticated sessions changes. When false the
    /// converter is torn down and no AAC work is done at all.
    var isAACOutputEnabled: Bool {
        get { encoderQueue.sync { _isAACOutputEnabled } }
        set {
            encoderQueue.async { [weak self] in
                guard let self, self._isAACOutputEnabled != newValue else { return }
                self._isAACOutputEnabled = newValue
                if !newValue { self.aac.reset() }
                logger.info("AAC output \(newValue ? "enabled" : "disabled")")
            }
        }
    }

    /// Applied live; safe to call mid-stream. Does NOT re-anchor the PTS clock and does NOT
    /// produce a codec transition on the wire.
    func setAACBitrate(_ bitsPerSecond: Int) {
        encoderQueue.async { [weak self] in self?.aac.setBitrate(bitsPerSecond) }
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        isRunning = true
        encoderQueue.async { [weak self] in self?.clearAACFailure() }
        logger.info("AudioEncoder started (Float32 PCM + optional AAC-LC)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        lastPublishedSampleRate = 0
        lastPublishedChannels = 0
        encoderQueue.async { [weak self] in
            self?.aac.reset()
            self?.clearAACFailure()
        }
        logger.info("AudioEncoder stopped")
    }

    // MARK: - Encode

    func encode(sampleBuffer: CMSampleBuffer) {
        guard isRunning else { return }
        encoderQueue.async { [weak self] in
            self?.processSampleBuffer(sampleBuffer)
        }
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning, let chunk = PCMChunk(sampleBuffer: sampleBuffer) else { return }
        publishFormatIfNeeded(sampleRate: chunk.sampleRate, channels: chunk.channels)
        delegate?.audioEncoder(self, didProducePCMChunk: chunk.samples, presentationTime: chunk.presentationTime)

        guard _isAACOutputEnabled else { return }
        if let failedAt = aacFailedAt {
            // Retry rather than stay dead forever. AAC-LC access units are independently
            // decodable, so a fresh converter resyncs immediately; the client re-anchors on the
            // PTS discontinuity via its own resync path.
            guard Date().timeIntervalSince(failedAt) >= Self.aacRetryBackoff,
                  aacFailureCount <= Self.maxAACRetries else { return }
            logger.info("Retrying AAC encoding after failure #\(self.aacFailureCount)")
            aacFailedAt = nil
        }
        do {
            for unit in try aac.encode(chunk) {
                delegate?.audioEncoder(self, didProduceAACChunk: unit.bytes, presentationTime: unit.presentationTime)
            }
        } catch {
            aacFailedAt = Date()
            aacFailureCount += 1
            if aacFailureCount > Self.maxAACRetries {
                logger.error("AAC failure (\(error)) #\(self.aacFailureCount) — retry budget exhausted, staying on PCM")
            } else {
                logger.error("AAC failure (\(error)) #\(self.aacFailureCount) — retrying in \(Self.aacRetryBackoff)s")
            }
        }
    }

    private func clearAACFailure() {
        aacFailedAt = nil
        aacFailureCount = 0
    }

    private func publishFormatIfNeeded(sampleRate: Double, channels: Int) {
        let safeChannels = max(1, channels)
        let sampleRateChanged = abs(sampleRate - lastPublishedSampleRate) > 1
        let channelsChanged = safeChannels != lastPublishedChannels
        guard sampleRateChanged || channelsChanged else { return }
        lastPublishedSampleRate = sampleRate
        lastPublishedChannels = safeChannels
        delegate?.audioEncoder(self, didUpdateSampleRate: sampleRate, channels: safeChannels)
        logger.info("AudioEncoder format updated: \(sampleRate, format: .fixed(precision: 0)) Hz, \(safeChannels)ch")
    }
}
