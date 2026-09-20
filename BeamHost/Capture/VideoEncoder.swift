// VideoEncoder.swift
// Beacon's video encoder: PhorosMedia.VideoEncoder plus Beacon's preset and
// frame-size policy. Produces Annex B frames and parameter sets ready for the wire.

import CoreMedia
import Foundation
import OSLog
import Phoros
import PhorosMedia

private let logger = Logger(subsystem: "com.beam.beacon", category: "VideoEncoder")

// MARK: - Delegate

protocol HostVideoEncoderDelegate: AnyObject {
    /// Called for each encoded video sample. `isKeyframe` is true for IDR frames.
    func videoEncoder(_ encoder: HostVideoEncoder, didEncodeFrame data: Data, presentationTime: CMTime, isKeyframe: Bool)
    /// Called once per compression session when the parameter sets are first available.
    /// `codec` is the codec the session ACTUALLY started with, which may differ from the
    /// requested one if the HEVC encoder could not be created and the session fell back.
    func videoEncoder(_ encoder: HostVideoEncoder, didEncodeParameterSets data: Data, codec: VideoCodecID)
}

// MARK: - HostVideoEncoder

final class HostVideoEncoder {

    weak var delegate: HostVideoEncoderDelegate?

    private let encoder: PhorosMedia.VideoEncoder
    private var started = false

    /// Whether this Mac can hardware-encode HEVC. A `false` here keeps the negotiation from
    /// ever choosing a codec the hardware can't produce.
    static var isHEVCEncodeSupported: Bool { PhorosMedia.VideoEncoder.isHEVCSupported }

    /// Codec the running session uses. The delegate reports the value the session actually
    /// started with, which is the authority for the .parameterSets packet's codec flag.
    var codec: VideoCodecID { encoder.activeCodec }

    init(width: Int32, height: Int32, frameRate: Double = 30, bitrateMbps: Double = 6, codec: VideoCodecID = .h264) {
        encoder = PhorosMedia.VideoEncoder(configuration: VideoEncoderConfiguration(
            width: width, height: height, frameRate: frameRate,
            bitrateBitsPerSecond: Int(bitrateMbps * 1_000_000), codec: codec,
            keyframeInterval: Harness.keyframeInterval ?? 2,
            latency: Harness.encoderTuning()
        ))
        encoder.onParameterSets = { [weak self] data, codec in
            guard let self else { return }
            logger.info("VideoEncoder started \(codec.wireName) \(self.encoder.configuration.width)x\(self.encoder.configuration.height)")
            self.delegate?.videoEncoder(self, didEncodeParameterSets: data, codec: codec)
        }
        encoder.onFrame = { [weak self] data, pts, isKeyframe in
            guard let self else { return }
            if Harness.isEnabled { Harness.log("H5E", Int(pts.microseconds), extra: "\(data.count),\(isKeyframe ? 1 : 0)") }
            self.delegate?.videoEncoder(self, didEncodeFrame: data, presentationTime: pts, isKeyframe: isKeyframe)
        }
        encoder.onFrameDropped = {
            if Harness.isEnabled { Harness.log("H5D", 0) }
        }
        encoder.onError = { status in
            // Never swallow this: a failed restart leaves the pipeline running with no encoder,
            // which reaches the user as a permanently black stream and nothing in the log.
            logger.error("VideoEncoder error (OSStatus \(status))")
            if Harness.isEnabled { Harness.log("H5X", Int(status)) }
        }
    }

    // MARK: - Session Management

    func start() throws {
        guard !started else { return }
        try encoder.start()
        started = true
    }

    func stop() {
        encoder.stop()
        started = false
        logger.info("VideoEncoder stopped")
    }

    /// Choose the codec the NEXT `start()` will use. No-op once a session is running.
    func setInitialCodec(_ newCodec: VideoCodecID) {
        guard !started else { return }
        encoder.reconfigure { $0.codec = newCodec }
    }

    /// Frame size the NEXT `start()` will use (BEAM-38): capture may begin straight into window
    /// mode, whose frame follows the window's aspect rather than the preset's.
    func setInitialFrameSize(_ size: CGSize) {
        guard !started else { return }
        encoder.reconfigure {
            $0.width = Int32(size.width)
            $0.height = Int32(size.height)
        }
    }

    /// Restart with the given preset. `frameSize` overrides the preset's dimensions when the
    /// capture frame follows a window's aspect (BEAM-38); fps and bitrate still come from the
    /// preset. Fresh parameter sets and an IDR follow on the next encoded frame.
    func reconfigure(preset: QualityPreset, frameSize: CGSize? = nil, frameRate: Double? = nil) {
        encoder.reconfigure {
            $0.width = Int32(frameSize?.width ?? CGFloat(preset.width))
            $0.height = Int32(frameSize?.height ?? CGFloat(preset.height))
            $0.frameRate = frameRate ?? Harness.frameRate(for: preset.frameRate)
            $0.bitrateBitsPerSecond = Int(preset.bitrateMbps * 1_000_000)
        }
    }

    /// Restart at a new frame rate, keeping everything else (a client asked for more or less).
    func reconfigure(frameRate: Double) {
        encoder.reconfigure { $0.frameRate = frameRate }
    }

    /// Restart on a new codec, keeping dimensions and bitrate. Used when the negotiated codec
    /// changes mid-stream (an H.264-only client joins and forces the shared encoder down).
    func reconfigure(codec newCodec: VideoCodecID) {
        encoder.reconfigure { $0.codec = newCodec }
    }

    /// Restart at a new frame size, keeping fps, bitrate and codec (BEAM-38).
    func reconfigure(frameSize: CGSize) {
        encoder.reconfigure {
            $0.width = Int32(frameSize.width)
            $0.height = Int32(frameSize.height)
        }
    }

    /// Live bitrate change for link adaptation: no restart, no keyframe.
    func setBitrate(_ bitsPerSecond: Int) {
        encoder.setBitrate(bitsPerSecond)
    }

    /// Request that the next encoded frame be a keyframe (IDR). Safe from any thread.
    func requestKeyframe() {
        encoder.requestKeyframe()
    }

    // MARK: - Encode

    func encode(sampleBuffer: CMSampleBuffer) {
        encoder.encode(sampleBuffer)
    }
}
