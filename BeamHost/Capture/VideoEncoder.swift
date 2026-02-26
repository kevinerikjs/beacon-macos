// VideoEncoder.swift
// Hardware-accelerated H.264 encoding via VideoToolbox VTCompressionSession.
// Produces Annex B NAL units ready for network transmission.

import VideoToolbox
import CoreMedia
import OSLog

private let logger = Logger(subsystem: "com.beam.host", category: "VideoEncoder")

// MARK: - Delegate

protocol VideoEncoderDelegate: AnyObject {
    /// Called for each encoded video sample. `isKeyframe` is true for IDR frames.
    func videoEncoder(_ encoder: VideoEncoder, didEncodeFrame data: Data, presentationTime: CMTime, isKeyframe: Bool)
    func videoEncoder(_ encoder: VideoEncoder, didEncodeParameterSets spsData: Data, ppsData: Data)
}

// MARK: - VideoEncoder

final class VideoEncoder {

    weak var delegate: VideoEncoderDelegate?

    private var session: VTCompressionSession?
    private let encoderQueue = DispatchQueue(label: "com.beam.host.videoencoder", qos: .userInteractive)

    // Configuration
    private let width: Int32
    private let height: Int32
    private let frameRate: Double
    private let bitrateBps: Int

    /// Whether parameter sets (SPS/PPS) have been sent for this session.
    private var parameterSetsSent = false

    /// Set to true (on encoderQueue) to force the next frame to be an IDR keyframe.
    private var forceKeyframeFlag = false

    init(width: Int32, height: Int32, frameRate: Double = 30, bitrateMbps: Double = 6) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitrateBps = Int(bitrateMbps * 1_000_000)
    }

    // MARK: - Session Management

    func start() throws {
        guard session == nil else { return }

        var compressionSession: VTCompressionSession?

        // Use hardware encoder exclusively
        let encoderSpec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ]

        let status = VTCompressionSessionCreate(
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

        guard status == noErr, let session = compressionSession else {
            throw VideoEncoderError.sessionCreationFailed(status)
        }

        // Configure session properties
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)

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
        logger.info("VideoEncoder started \(self.width)x\(self.height) @ \(Int(self.frameRate))fps, \(self.bitrateBps / 1_000_000)Mbps")
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

        // Extract parameter sets (SPS/PPS) from keyframes if not yet sent
        if isKeyframe && !parameterSetsSent {
            if let (sps, pps) = extractParameterSets(from: sampleBuffer) {
                parameterSetsSent = true
                delegate?.videoEncoder(self, didEncodeParameterSets: sps, ppsData: pps)
            }
        }

        // Convert AVCC format to Annex B
        if let annexBData = convertToAnnexB(sampleBuffer: sampleBuffer) {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            delegate?.videoEncoder(self, didEncodeFrame: annexBData, presentationTime: pts, isKeyframe: isKeyframe)
        }
    }

    // MARK: - Format Helpers

    private func extractParameterSets(from sampleBuffer: CMSampleBuffer) -> (sps: Data, pps: Data)? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }

        var spsCount = 0, spsSize = 0
        var spsPointer: UnsafePointer<UInt8>?
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil)

        var ppsCount = 0, ppsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: &ppsCount, nalUnitHeaderLengthOut: nil)

        guard let sps = spsPointer, let pps = ppsPointer else { return nil }

        // Wrap in Annex B start codes
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var spsData = Data(startCode)
        spsData.append(UnsafeBufferPointer(start: sps, count: spsSize))
        var ppsData = Data(startCode)
        ppsData.append(UnsafeBufferPointer(start: pps, count: ppsSize))

        return (spsData, ppsData)
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

            // Read AVCC NAL length (4-byte big-endian)
            let nalLengthBytes = UnsafeRawPointer(pointer.advanced(by: offset))
            let nalLength = Int(nalLengthBytes.load(as: UInt32.self).bigEndian)
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

