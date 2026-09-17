// VideoEncoder.swift
// Hardware-accelerated H.264 / HEVC encoding via VideoToolbox VTCompressionSession.
// Produces Annex B NAL units ready for network transmission.

import VideoToolbox
import CoreMedia
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "VideoEncoder")

// MARK: - Delegate

protocol VideoEncoderDelegate: AnyObject {
    /// Called for each encoded video sample. `isKeyframe` is true for IDR frames.
    func videoEncoder(_ encoder: VideoEncoder, didEncodeFrame data: Data, presentationTime: CMTime, isKeyframe: Bool)
    /// Called once per compression session when the parameter sets are first available.
    /// `data` is the full Annex B blob (H.264: SPS+PPS; HEVC: VPS+SPS+PPS). `codec` is the
    /// codec the session ACTUALLY started with, which may differ from the requested one if the
    /// HEVC encoder could not be created and the session fell back to H.264.
    func videoEncoder(_ encoder: VideoEncoder, didEncodeParameterSets data: Data, codec: BeamVideoCodec)
}

// MARK: - VideoEncoder

final class VideoEncoder {

    weak var delegate: VideoEncoderDelegate?

    private var session: VTCompressionSession?
    private let encoderQueue = DispatchQueue(label: "com.beam.beacon.videoencoder", qos: .userInteractive)

    // Configuration
    private var width: Int32
    private var height: Int32
    private var frameRate: Double
    private var bitrateBps: Int

    /// Codec the encoder is currently configured for. Read/written on `encoderQueue`; the
    /// delegate reports the value the session actually started with, which is the authority for
    /// the .spsPps packet's codec flag. Defaults to H.264 (the permanent wire default).
    private(set) var codec: BeamVideoCodec = .h264

    /// Whether parameter sets have been sent for this session.
    private var parameterSetsSent = false

    /// Set to true (on encoderQueue) to force the next frame to be an IDR keyframe.
    private var forceKeyframeFlag = false

    init(width: Int32, height: Int32, frameRate: Double = 30, bitrateMbps: Double = 6, codec: BeamVideoCodec = .h264) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitrateBps = Int(bitrateMbps * 1_000_000)
        self.codec = codec
    }

    /// Whether this Mac can hardware-encode HEVC. Probed once and cached. Near-universal on the
    /// Macs that meet Beacon's macOS 14 floor (all Apple Silicon, Intel 2017+), but a `false`
    /// here keeps the negotiation from ever choosing a codec the hardware can't produce.
    static let isHEVCEncodeSupported: Bool = {
        var session: VTCompressionSession?
        let spec: [String: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 640, height: 360,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let session { VTCompressionSessionInvalidate(session) }
        let supported = status == noErr && session != nil
        logger.info("HEVC hardware encode supported: \(supported)")
        return supported
    }()

    // MARK: - Session Management

    func start() throws {
        try encoderQueue.sync { try startInternal() }
    }

    /// Choose the codec the NEXT `start()` will use. No-op once a session is running — use
    /// `reconfigure(codec:)` to change codec mid-stream. Serialised on `encoderQueue` so it
    /// can't race the start it precedes.
    func setInitialCodec(_ newCodec: BeamVideoCodec) {
        encoderQueue.sync { if session == nil { codec = newCodec } }
    }

    private func startInternal() throws {
        guard session == nil else { return }

        // Use hardware encoder exclusively.
        let encoderSpec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ]

        // Try the requested codec; if HEVC can't be created on this hardware, fall the session
        // back to H.264 rather than leaving the pipeline with no encoder. The delegate reports
        // whichever codec actually started, so the .spsPps packet's codec flag stays truthful
        // and the receiver builds the matching format description.
        var compressionSession: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &compressionSession
        )

        if (status != noErr || compressionSession == nil), codec == .hevc {
            logger.error("HEVC compression session create failed (\(status)) — falling back to H.264")
            codec = .h264
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: width,
                height: height,
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: encoderSpec as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: compressionOutputCallback,
                refcon: Unmanaged.passUnretained(self).toOpaque(),
                compressionSessionOut: &compressionSession
            )
        }

        guard status == noErr, let session = compressionSession else {
            throw VideoEncoderError.sessionCreationFailed(status)
        }

        // Configure session properties
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        )

        // Bitrate
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitrateBps)
        )
        // Data rate limits: max burst
        let dataRateLimits = [bitrateBps * 2, 1] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)

        // Frame rate
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: frameRate)
        )

        // Keyframe interval: force IDR every 2 seconds
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: Int(frameRate * 2))
        )

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        logger.info("VideoEncoder started \(self.codec.wireName) \(self.width)x\(self.height) @ \(Int(self.frameRate))fps, \(self.bitrateBps / 1_000_000)Mbps")
    }

    /// Tear down current session and create a new one with the given preset.
    /// Resets parameter sets — new SPS/PPS + IDR will be emitted on the next encoded frame.
    func reconfigure(preset: StreamQualityPreset) {
        encoderQueue.async { [weak self] in
            guard let self else { return }
            if let s = session { VTCompressionSessionInvalidate(s); session = nil }
            parameterSetsSent = false
            forceKeyframeFlag = false
            width = Int32(preset.width)
            height = Int32(preset.height)
            frameRate = preset.fps
            bitrateBps = Int(preset.bitrateMbps * 1_000_000)
            // Never swallow this: a failed restart leaves the pipeline running with no encoder,
            // which reaches the user as a permanently black stream and nothing in the log.
            do {
                try startInternal()
                logger.info("VideoEncoder reconfigured → \(preset.width)x\(preset.height) @\(Int(preset.fps))fps")
            } catch {
                logger.error("VideoEncoder reconfigure FAILED at \(preset.width)x\(preset.height): \(error)")
            }
        }
    }

    /// Tear down and restart the session on a new codec, keeping the current dimensions and
    /// bitrate. Used when the negotiated codec changes mid-stream (e.g. an H.264-only client
    /// joins and forces the shared encoder down from HEVC). Resets parameter sets so fresh
    /// VPS/SPS/PPS + an IDR are emitted for the new codec on the next frame.
    func reconfigure(codec newCodec: BeamVideoCodec) {
        encoderQueue.async { [weak self] in
            guard let self else { return }
            guard newCodec != codec || session == nil else { return }
            if let s = session { VTCompressionSessionInvalidate(s); session = nil }
            parameterSetsSent = false
            forceKeyframeFlag = false
            codec = newCodec
            do {
                try startInternal()
                logger.info("VideoEncoder codec → \(self.codec.wireName)")
            } catch {
                logger.error("VideoEncoder codec reconfigure FAILED (\(newCodec.wireName)): \(error)")
            }
        }
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
        parameterSetsSent = false
        forceKeyframeFlag = false
        logger.info("VideoEncoder stopped")
    }

    /// Request that the next encoded frame be a keyframe (IDR).
    /// Safe to call from any thread.
    func requestKeyframe() {
        encoderQueue.async { [weak self] in
            self?.forceKeyframeFlag = true
        }
    }

    // MARK: - Encode

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        encoderQueue.async { [weak self] in
            guard let self else { return }
            // Pop the force-keyframe flag if set
            var frameProperties: CFDictionary? = nil
            if forceKeyframeFlag {
                forceKeyframeFlag = false
                frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            }

            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: imageBuffer,
                presentationTimeStamp: presentationTime,
                duration: .invalid,
                frameProperties: frameProperties,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
            if status != noErr {
                logger.error("VTCompressionSessionEncodeFrame failed: \(status)")
            }
        }
    }

    // MARK: - Output Callback

    func handleEncodedFrame(
        status: OSStatus,
        flags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?
    ) {
        guard status == noErr, let sampleBuffer else {
            if status != noErr { logger.error("Encoding error: \(status)") }
            return
        }
        guard sampleBuffer.isValid else { return }

        // A frame is a keyframe (IDR) if kCMSampleAttachmentKey_NotSync is absent or false
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        let isKeyframe: Bool
        if let attachments, CFArrayGetCount(attachments) > 0,
           let dict = CFArrayGetValueAtIndex(attachments, 0).map({ Unmanaged<CFDictionary>.fromOpaque($0).takeUnretainedValue() }),
           let notSync = (dict as NSDictionary)[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        } else {
            isKeyframe = true  // No attachment = no B-frames = keyframe
        }

        // Extract parameter sets from keyframes if not yet sent. H.264 carries SPS+PPS; HEVC
        // carries VPS+SPS+PPS. The blob is Annex B (start-code prefixed) and codec is reported
        // so the receiver knows which format-description builder to use.
        if isKeyframe && !parameterSetsSent {
            if let paramData = extractParameterSets(from: sampleBuffer) {
                parameterSetsSent = true
                delegate?.videoEncoder(self, didEncodeParameterSets: paramData, codec: codec)
            }
        }

        // Convert AVCC format to Annex B
        if let annexBData = convertToAnnexB(sampleBuffer: sampleBuffer) {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            delegate?.videoEncoder(self, didEncodeFrame: annexBData, presentationTime: pts, isKeyframe: isKeyframe)
        }
    }

    // MARK: - Format Helpers

    /// Extract the codec's parameter sets from a keyframe as a single Annex B blob:
    /// H.264 → SPS+PPS (2 NALs), HEVC → VPS+SPS+PPS (3 NALs), each start-code prefixed.
    private func extractParameterSets(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // Read the parameter-set count from index 0, then pull every set. HEVC and H.264 use
        // different accessors; the count-out tells us how many sets to emit for each.
        var count = 0
        if codec == .hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        guard count >= 2 else { return nil }

        var blob = Data()
        for index in 0..<count {
            var size = 0
            var pointer: UnsafePointer<UInt8>?
            let status: OSStatus
            if codec == .hevc {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer else { return nil }
            blob.append(contentsOf: startCode)
            blob.append(UnsafeBufferPointer(start: pointer, count: size))
        }
        return blob.isEmpty ? nil : blob
    }

    /// Convert VideoToolbox AVCC output to Annex B format (start code prefix before each NAL).
    private func convertToAnnexB(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else { return nil }

        var result = Data(capacity: totalLength)
        var offset = 0
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        while offset < totalLength {
            guard offset + 4 <= totalLength else { break }

            // Read AVCC NAL length (4-byte big-endian) — use loadUnaligned since
            // offset may not be 4-byte aligned after variable-length NAL units.
            let nalLengthBytes = UnsafeRawPointer(pointer.advanced(by: offset))
            let nalLength = Int(nalLengthBytes.loadUnaligned(as: UInt32.self).bigEndian)
            offset += 4

            guard offset + nalLength <= totalLength else { break }

            // Replace 4-byte length prefix with Annex B start code
            result.append(contentsOf: startCode)
            result.append(UnsafeBufferPointer(
                start: UnsafePointer<UInt8>(bitPattern: Int(bitPattern: pointer) + offset),
                count: nalLength
            ))
            offset += nalLength
        }

        return result.isEmpty ? nil : result
    }
}

// MARK: - C Callback

private func compressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handleEncodedFrame(status: status, flags: infoFlags, sampleBuffer: sampleBuffer)
}

// MARK: - Errors

enum VideoEncoderError: Error, LocalizedError {
    case sessionCreationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let code):
            return "Failed to create VTCompressionSession (OSStatus \(code)). Hardware encoder may be unavailable."
        }
    }
}

