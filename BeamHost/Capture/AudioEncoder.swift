// AudioEncoder.swift
// Normalizes ScreenCaptureKit audio to Float32 interleaved PCM and forwards it.
// Input: PCM from ScreenCaptureKit (Float32 or Int16, interleaved/non-interleaved)
// Output: Float32 interleaved PCM (stereo 44.1k target from stream config)

import AudioToolbox
import CoreMedia
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "AudioEncoder")

// MARK: - Delegate

protocol AudioEncoderDelegate: AnyObject {
    func audioEncoder(_ encoder: AudioEncoder, didEncodeChunk data: Data, presentationTime: CMTime)
    func audioEncoder(_ encoder: AudioEncoder, didUpdateSampleRate sampleRate: Double, channels: Int)
}

// MARK: - AudioEncoder

final class AudioEncoder {

    weak var delegate: AudioEncoderDelegate?
    private let encoderQueue = DispatchQueue(label: "com.beam.beacon.audioencoder", qos: .userInteractive)
    private var isRunning = false
    private var lastPublishedSampleRate: Double = 0
    private var lastPublishedChannels: Int = 0

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        isRunning = true
        logger.info("AudioEncoder started (Float32 PCM passthrough)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        lastPublishedSampleRate = 0
        lastPublishedChannels = 0
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
        guard isRunning else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let extracted = extractInterleavedFloat32PCM(from: sampleBuffer) else { return }
        publishFormatIfNeeded(sampleRate: extracted.sampleRate, channels: extracted.channels)
        delegate?.audioEncoder(self, didEncodeChunk: extracted.data, presentationTime: pts)
    }

    private func extractInterleavedFloat32PCM(from sampleBuffer: CMSampleBuffer) -> (data: Data, sampleRate: Double, channels: Int)? {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            logger.error("AudioEncoder: missing audio format description")
            return nil
        }
        let asbd = asbdPtr.pointee

        let sourceChannels = Int(asbd.mChannelsPerFrame)
        guard sourceChannels > 0 else { return nil }
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        let extraBuffers = max(sourceChannels - 1, 0)
        let ablByteCount = MemoryLayout<AudioBufferList>.size + (MemoryLayout<AudioBuffer>.size * extraBuffers)
        var ablRaw = [UInt8](repeating: 0, count: ablByteCount)
        var retainedBlock: CMBlockBuffer?

        let status: OSStatus = ablRaw.withUnsafeMutableBytes { raw in
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: raw.bindMemory(to: AudioBufferList.self).baseAddress!,
                bufferListSize: ablByteCount,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &retainedBlock
            )
        }

        guard status == noErr else {
            logger.error("AudioEncoder: CMSampleBufferGetAudioBufferList failed (\(status))")
            return nil
        }

        return ablRaw.withUnsafeMutableBytes { raw in
            let abl = raw.baseAddress!.assumingMemoryBound(to: AudioBufferList.self)
            let numberBuffers = Int(abl.pointee.mNumberBuffers)
            let firstBuffer = withUnsafeMutablePointer(to: &abl.pointee.mBuffers) { $0 }

            if numberBuffers == 1 && !isNonInterleaved {
                let buffer = firstBuffer.pointee
                guard let dataPtr = buffer.mData else { return nil }

                if isFloat && bitsPerChannel == 32 {
                    let byteCount = min(Int(buffer.mDataByteSize), sampleCount * sourceChannels * MemoryLayout<Float32>.size)
                    return (Data(bytes: dataPtr, count: byteCount), asbd.mSampleRate, sourceChannels)
                }

                if isSignedInt && bitsPerChannel == 16 {
                    let maxSamples = min(Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size, sampleCount * sourceChannels)
                    let src = dataPtr.assumingMemoryBound(to: Int16.self)
                    var out = Data(count: maxSamples * MemoryLayout<Float32>.size)
                    out.withUnsafeMutableBytes { dstRaw in
                        let dst = dstRaw.baseAddress!.assumingMemoryBound(to: Float32.self)
                        for i in 0..<maxSamples {
                            dst[i] = Float32(src[i]) / Float32(Int16.max)
                        }
                    }
                    return (out, asbd.mSampleRate, sourceChannels)
                }

                logger.error("AudioEncoder: unsupported interleaved source format flags=\(asbd.mFormatFlags), bits=\(bitsPerChannel)")
                return nil
            }

            // Non-interleaved path: interleave channels into Float32 output.
            let channelCount = min(sourceChannels, numberBuffers)
            guard channelCount > 0 else { return nil }

            if isFloat && bitsPerChannel == 32 {
                var frameCount = sampleCount
                for ch in 0..<channelCount {
                    let chBuffer = (firstBuffer + ch).pointee
                    frameCount = min(frameCount, Int(chBuffer.mDataByteSize) / MemoryLayout<Float32>.size)
                }

                var out = Data(count: frameCount * channelCount * MemoryLayout<Float32>.size)
                out.withUnsafeMutableBytes { dstRaw in
                    let dst = dstRaw.baseAddress!.assumingMemoryBound(to: Float32.self)
                    for ch in 0..<channelCount {
                        let chBuffer = (firstBuffer + ch).pointee
                        guard let srcPtr = chBuffer.mData else { continue }
                        let src = srcPtr.assumingMemoryBound(to: Float32.self)
                        for frame in 0..<frameCount {
                            dst[(frame * channelCount) + ch] = src[frame]
                        }
                    }
                }
                return (out, asbd.mSampleRate, channelCount)
            }

            if isSignedInt && bitsPerChannel == 16 {
                var frameCount = sampleCount
                for ch in 0..<channelCount {
                    let chBuffer = (firstBuffer + ch).pointee
                    frameCount = min(frameCount, Int(chBuffer.mDataByteSize) / MemoryLayout<Int16>.size)
                }

                var out = Data(count: frameCount * channelCount * MemoryLayout<Float32>.size)
                out.withUnsafeMutableBytes { dstRaw in
                    let dst = dstRaw.baseAddress!.assumingMemoryBound(to: Float32.self)
                    for ch in 0..<channelCount {
                        let chBuffer = (firstBuffer + ch).pointee
                        guard let srcPtr = chBuffer.mData else { continue }
                        let src = srcPtr.assumingMemoryBound(to: Int16.self)
                        for frame in 0..<frameCount {
                            dst[(frame * channelCount) + ch] = Float32(src[frame]) / Float32(Int16.max)
                        }
                    }
                }
                return (out, asbd.mSampleRate, channelCount)
            }

            logger.error("AudioEncoder: unsupported non-interleaved source format flags=\(asbd.mFormatFlags), bits=\(bitsPerChannel)")
            return nil
        }
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
