// AudioEncoder.swift
// Normalizes ScreenCaptureKit audio to Float32 interleaved PCM and, when at least one
// connected client has advertised AAC support, additionally encodes it to AAC-LC.
//
// Input:  PCM from ScreenCaptureKit (Float32 or Int16, interleaved/non-interleaved)
// Output: (a) Float32 interleaved PCM — always produced, the legacy wire format
//         (b) raw AAC-LC access units (1024 frames each, NO ADTS) — produced only while
//             `isAACOutputEnabled` is true and the converter is healthy.
//
// Both outputs are delivered for the same input buffer; StreamServer fans each one out only
// to the sessions that negotiated that codec. See BeamAudioCodec in Protocol.swift.

import AudioToolbox
import CoreMedia
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "AudioEncoder")

/// Returned by the converter input proc when there is no buffered PCM left. Any non-zero,
/// non-Apple value works; AudioConverterFillComplexBuffer surfaces it verbatim so we can tell
/// "ran out of input" apart from a real encoder failure.
private let kBeamConverterStarveError: OSStatus = 1

/// How many access units we ask the converter for per FillComplexBuffer call.
private let kBeamMaxOutputPacketsPerCall = 8

// MARK: - Delegate

protocol AudioEncoderDelegate: AnyObject {
    /// Float32 interleaved PCM, PTS = the source CMSampleBuffer's PTS. Always produced.
    func audioEncoder(_ encoder: AudioEncoder, didProducePCMChunk data: Data, presentationTime: CMTime)
    /// One raw AAC-LC access unit, no ADTS. PTS is priming-compensated (see below).
    /// Only produced while `isAACOutputEnabled == true` and converter setup succeeded.
    func audioEncoder(_ encoder: AudioEncoder, didProduceAACChunk data: Data, presentationTime: CMTime)
    func audioEncoder(_ encoder: AudioEncoder, didUpdateSampleRate sampleRate: Double, channels: Int)
}

// MARK: - AudioEncoder

final class AudioEncoder {

    weak var delegate: AudioEncoderDelegate?
    private let encoderQueue = DispatchQueue(label: "com.beam.beacon.audioencoder", qos: .userInteractive)
    private var isRunning = false
    private var lastPublishedSampleRate: Double = 0
    private var lastPublishedChannels: Int = 0

    // MARK: - AAC state (encoderQueue only)

    private var aacConverter: AudioConverterRef?
    private var aacSourceSampleRate: Double = 0
    private var aacSourceChannels: Int = 0
    private var aacBytesPerFrame: Int = 0
    private var aacFramesPerPacket: Int64 = Int64(BeamAudioCodec.aacFramesPerPacket)
    private var aacPrimingFrames: Int64 = Int64(BeamAudioCodec.aacPrimingFrames)
    private var aacStartPTSUs: Int64 = 0
    private var aacNeedsAnchor = true
    private var aacOutputAUIndex: Int64 = 0
    private var aacInputFramesFed: Int64 = 0
    private var pendingPCM = Data()
    private var _aacFailed = false
    private var _isAACOutputEnabled = false
    private var requestedBitrate: Int = 128_000
    private var lastAppliedBitrate: Int = 0

    private var inputScratch: UnsafeMutableRawPointer?
    private var inputScratchCapacity = 0
    private var outputScratch: UnsafeMutableRawPointer?
    private var outputScratchCapacity = 0

    /// Set by StreamServer whenever the set of authenticated sessions changes. When false the
    /// converter is torn down and no AAC work is done at all.
    var isAACOutputEnabled: Bool {
        get { encoderQueue.sync { _isAACOutputEnabled } }
        set {
            encoderQueue.async { [weak self] in
                guard let self, self._isAACOutputEnabled != newValue else { return }
                self._isAACOutputEnabled = newValue
                if !newValue {
                    self.teardownAACConverter()
                }
                logger.info("AAC output \(newValue ? "enabled" : "disabled")")
            }
        }
    }

    /// True once AudioConverterNew (or encoding) has failed for this stream; latches until stop().
    var aacFailed: Bool { encoderQueue.sync { _aacFailed } }

    /// Applied live via kAudioConverterEncodeBitRate; safe to call mid-stream. Does NOT
    /// re-anchor the PTS clock and does NOT produce a codec transition on the wire.
    func setAACBitrate(_ bitsPerSecond: Int) {
        encoderQueue.async { [weak self] in
            guard let self else { return }
            self.requestedBitrate = bitsPerSecond
            if let conv = self.aacConverter {
                self.applyBitrate(to: conv)
            }
        }
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        isRunning = true
        encoderQueue.async { [weak self] in
            self?._aacFailed = false
        }
        logger.info("AudioEncoder started (Float32 PCM + optional AAC-LC)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        lastPublishedSampleRate = 0
        lastPublishedChannels = 0
        encoderQueue.async { [weak self] in
            guard let self else { return }
            self.teardownAACConverter()
            self._aacFailed = false
        }
        logger.info("AudioEncoder stopped")
    }

    deinit {
        // encoderQueue work is already drained by stop(); free anything still held.
        if let conv = aacConverter { AudioConverterDispose(conv) }
        inputScratch?.deallocate()
        outputScratch?.deallocate()
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
        delegate?.audioEncoder(self, didProducePCMChunk: extracted.data, presentationTime: pts)

        guard _isAACOutputEnabled, !_aacFailed else { return }
        encodeAAC(
            pcm: extracted.data,
            sampleRate: extracted.sampleRate,
            channels: extracted.channels,
            inputPTSUs: pts.microseconds
        )
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

    // MARK: - AAC-LC Encoding
    //
    // Priming: AAC-LC introduces a constant ~2112-frame (47.9 ms at 44.1 kHz) delay end to end
    // (encoder priming + decoder lookahead). Left uncompensated it is a permanent negative A/V
    // offset that pushes the client's sync error toward its hard-resync threshold. We therefore
    // run a sample-accurate OUTPUT clock here and declare each access unit as starting 2112
    // frames EARLIER than its nominal position, which cancels the delay exactly. The client
    // performs no trimming and no compensation at all — doing so would double-correct.

    private func encodeAAC(pcm: Data, sampleRate: Double, channels: Int, inputPTSUs: Int64) {
        let safeChannels = max(1, channels)
        guard sampleRate > 0, !pcm.isEmpty else { return }

        // A source-format change means a brand new converter and a fresh PTS anchor.
        if aacConverter == nil || sampleRate != aacSourceSampleRate || safeChannels != aacSourceChannels {
            teardownAACConverter()
            guard setupAACConverter(sampleRate: sampleRate, channels: safeChannels) else {
                _aacFailed = true
                logger.error("AAC converter setup failed — this stream stays on PCM for all clients")
                return
            }
        }
        guard let conv = aacConverter else { return }

        // Anchor / drift guard. The converter buffers across input buffers, so output PTS must
        // come from the frame clock, not from whichever input buffer happened to be in hand.
        if aacNeedsAnchor {
            aacStartPTSUs = inputPTSUs
            aacOutputAUIndex = 0
            aacInputFramesFed = 0
            aacNeedsAnchor = false
        } else {
            let predicted = aacStartPTSUs + Int64((Double(aacInputFramesFed) * 1_000_000.0 / aacSourceSampleRate).rounded())
            if abs(inputPTSUs - predicted) > 250_000 {
                logger.warning("AAC clock drifted \((inputPTSUs - predicted) / 1000)ms (capture stall?) — re-anchoring")
                AudioConverterReset(conv)
                pendingPCM.removeAll(keepingCapacity: true)
                aacStartPTSUs = inputPTSUs
                aacOutputAUIndex = 0
                aacInputFramesFed = 0
            }
        }

        let frames = pcm.count / aacBytesPerFrame
        guard frames > 0 else { return }
        pendingPCM.append(pcm.prefix(frames * aacBytesPerFrame))
        aacInputFramesFed += Int64(frames)

        drainConverter(conv)
    }

    private func drainConverter(_ conv: AudioConverterRef) {
        guard let outScratch = outputScratch else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var descriptions = [AudioStreamPacketDescription](
            repeating: AudioStreamPacketDescription(),
            count: kBeamMaxOutputPacketsPerCall
        )

        while true {
            var packetCount = UInt32(kBeamMaxOutputPacketsPerCall)
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(aacSourceChannels),
                    mDataByteSize: UInt32(outputScratchCapacity),
                    mData: outScratch
                )
            )

            let status = descriptions.withUnsafeMutableBufferPointer { descPtr -> OSStatus in
                AudioConverterFillComplexBuffer(
                    conv,
                    beamAACInputProc,
                    selfPtr,
                    &packetCount,
                    &abl,
                    descPtr.baseAddress
                )
            }

            if status != noErr && status != kBeamConverterStarveError {
                logger.error("AAC encode failed (\(status)) — degrading this stream to PCM permanently")
                _aacFailed = true
                teardownAACConverter()
                return
            }

            if packetCount > 0 {
                for i in 0..<Int(packetCount) {
                    let desc = descriptions[i]
                    let byteCount = Int(desc.mDataByteSize)
                    guard byteCount > 0, byteCount <= BeamAudioCodec.maxAccessUnitBytes else {
                        // Never emit an AU that cannot fit in one packet — there is no audio
                        // fragmentation path. Still advance the clock so PTS stays truthful.
                        if byteCount > 0 {
                            logger.error("Skipping oversized AAC access unit (\(byteCount) B)")
                        }
                        aacOutputAUIndex += 1
                        continue
                    }
                    let au = Data(bytes: outScratch.advanced(by: Int(desc.mStartOffset)), count: byteCount)
                    let frameOffset = aacOutputAUIndex * aacFramesPerPacket - aacPrimingFrames
                    let ptsUs = aacStartPTSUs + Int64((Double(frameOffset) * 1_000_000.0 / aacSourceSampleRate).rounded())
                    aacOutputAUIndex += 1
                    delegate?.audioEncoder(
                        self,
                        didProduceAACChunk: au,
                        presentationTime: CMTime(value: ptsUs, timescale: 1_000_000)
                    )
                }
            }

            // Out of buffered input, or the converter produced nothing this round.
            if status == kBeamConverterStarveError || packetCount == 0 { return }
        }
    }

    /// Called from the C input proc, on encoderQueue (FillComplexBuffer is synchronous).
    fileprivate func provideConverterInput(
        packets: UnsafeMutablePointer<UInt32>,
        bufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        guard let scratch = inputScratch, aacBytesPerFrame > 0 else {
            packets.pointee = 0
            return kBeamConverterStarveError
        }
        let wantedBytes = Int(packets.pointee) * aacBytesPerFrame
        let byteCount = min(wantedBytes, min(pendingPCM.count, inputScratchCapacity))
            / aacBytesPerFrame * aacBytesPerFrame
        guard byteCount > 0 else {
            packets.pointee = 0
            return kBeamConverterStarveError
        }

        pendingPCM.withUnsafeBytes { raw in
            scratch.copyMemory(from: raw.baseAddress!, byteCount: byteCount)
        }
        pendingPCM.removeFirst(byteCount)

        bufferList.pointee.mNumberBuffers = 1
        bufferList.pointee.mBuffers.mNumberChannels = UInt32(aacSourceChannels)
        bufferList.pointee.mBuffers.mDataByteSize = UInt32(byteCount)
        bufferList.pointee.mBuffers.mData = scratch
        // Source is LPCM, so one packet == one frame.
        packets.pointee = UInt32(byteCount / aacBytesPerFrame)
        return noErr
    }

    // MARK: - Converter setup / teardown

    private func setupAACConverter(sampleRate: Double, channels: Int) -> Bool {
        var src = AudioStreamBasicDescription()
        src.mSampleRate       = sampleRate
        src.mFormatID         = kAudioFormatLinearPCM
        src.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        src.mFramesPerPacket  = 1
        src.mChannelsPerFrame = UInt32(channels)
        src.mBitsPerChannel   = 32
        src.mBytesPerFrame    = UInt32(channels * MemoryLayout<Float32>.size)
        src.mBytesPerPacket   = src.mBytesPerFrame

        var dst = AudioStreamBasicDescription()
        dst.mSampleRate       = sampleRate
        dst.mFormatID         = kAudioFormatMPEG4AAC   // AAC-LC
        dst.mFormatFlags      = 0
        dst.mBytesPerPacket   = 0                      // variable
        dst.mFramesPerPacket  = UInt32(BeamAudioCodec.aacFramesPerPacket)
        dst.mBytesPerFrame    = 0
        dst.mChannelsPerFrame = UInt32(channels)
        dst.mBitsPerChannel   = 0
        dst.mReserved         = 0

        var conv: AudioConverterRef?
        let status = AudioConverterNew(&src, &dst, &conv)
        guard status == noErr, let converter = conv else {
            logger.error("AudioConverterNew failed (\(status))")
            return false
        }

        // CBR: predictable AU size is what makes the 1400-byte packet cap provable.
        var mode = kAudioCodecBitRateControlMode_Constant
        _ = AudioConverterSetProperty(
            converter,
            kAudioCodecPropertyBitRateControlMode,
            UInt32(MemoryLayout<UInt32>.size),
            &mode
        )

        aacConverter = converter
        aacSourceSampleRate = sampleRate
        aacSourceChannels = channels
        aacBytesPerFrame = channels * MemoryLayout<Float32>.size
        lastAppliedBitrate = 0
        applyBitrate(to: converter)

        // Read back what the converter actually produces rather than assuming 1024.
        var outASBD = AudioStreamBasicDescription()
        var outSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioConverterGetProperty(converter, kAudioConverterCurrentOutputStreamDescription, &outSize, &outASBD) == noErr,
           outASBD.mFramesPerPacket > 0 {
            aacFramesPerPacket = Int64(outASBD.mFramesPerPacket)
        } else {
            aacFramesPerPacket = Int64(BeamAudioCodec.aacFramesPerPacket)
        }

        var prime = AudioConverterPrimeInfo()
        var primeSize = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        if AudioConverterGetProperty(converter, kAudioConverterPrimeInfo, &primeSize, &prime) == noErr,
           prime.leadingFrames > 0 {
            aacPrimingFrames = Int64(prime.leadingFrames)
        } else {
            aacPrimingFrames = Int64(BeamAudioCodec.aacPrimingFrames)
        }

        // Scratch buffers. Input holds ~0.25 s of PCM per call; output holds the max AU size
        // for every packet we request in one go.
        inputScratchCapacity = max(aacBytesPerFrame * Int(sampleRate) / 4, aacBytesPerFrame * 4096)
        inputScratch = UnsafeMutableRawPointer.allocate(byteCount: inputScratchCapacity, alignment: 16)
        outputScratchCapacity = BeamAudioCodec.maxAccessUnitBytes * kBeamMaxOutputPacketsPerCall
        outputScratch = UnsafeMutableRawPointer.allocate(byteCount: outputScratchCapacity, alignment: 16)

        pendingPCM.removeAll(keepingCapacity: true)
        aacNeedsAnchor = true
        aacOutputAUIndex = 0
        aacInputFramesFed = 0

        logger.info("AAC-LC converter ready: \(sampleRate, format: .fixed(precision: 0)) Hz, \(channels)ch, \(self.aacFramesPerPacket) frames/AU, priming \(self.aacPrimingFrames)")
        return true
    }

    private func applyBitrate(to converter: AudioConverterRef) {
        let target = min(requestedBitrate, 160_000)
        var chosen = target

        // Never set an inapplicable rate — the call fails and the converter silently keeps
        // whatever it had. Snap to the largest applicable value <= target instead.
        var size: UInt32 = 0
        if AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr,
           size >= UInt32(MemoryLayout<AudioValueRange>.size) {
            let count = Int(size) / MemoryLayout<AudioValueRange>.size
            var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
            var ioSize = size
            let ok = ranges.withUnsafeMutableBytes { raw -> Bool in
                AudioConverterGetProperty(
                    converter, kAudioConverterApplicableEncodeBitRates, &ioSize, raw.baseAddress!
                ) == noErr
            }
            if ok {
                var candidates: [Int] = []
                for r in ranges {
                    if r.mMinimum > 0 { candidates.append(Int(r.mMinimum)) }
                    if r.mMaximum > 0 { candidates.append(Int(r.mMaximum)) }
                }
                if !candidates.isEmpty {
                    let atOrBelow = candidates.filter { $0 <= target }
                    chosen = atOrBelow.max() ?? (candidates.min() ?? target)
                }
            }
        }

        guard chosen != lastAppliedBitrate else { return }
        var rate = UInt32(chosen)
        let status = AudioConverterSetProperty(
            converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate
        )
        if status == noErr {
            lastAppliedBitrate = chosen
            logger.info("AAC bitrate set to \(chosen) bps (requested \(self.requestedBitrate))")
        } else {
            logger.error("Failed to set AAC bitrate \(chosen) (\(status))")
        }
    }

    private func teardownAACConverter() {
        if let conv = aacConverter {
            AudioConverterDispose(conv)
        }
        aacConverter = nil
        inputScratch?.deallocate()
        inputScratch = nil
        inputScratchCapacity = 0
        outputScratch?.deallocate()
        outputScratch = nil
        outputScratchCapacity = 0
        pendingPCM.removeAll(keepingCapacity: false)
        aacSourceSampleRate = 0
        aacSourceChannels = 0
        aacBytesPerFrame = 0
        aacNeedsAnchor = true
        aacOutputAUIndex = 0
        aacInputFramesFed = 0
        aacStartPTSUs = 0
        lastAppliedBitrate = 0
    }
}

// MARK: - Converter input callback

private let beamAACInputProc: AudioConverterComplexInputDataProc = {
    _, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
    // LPCM source: no packet descriptions.
    outDataPacketDescription?.pointee = nil
    guard let inUserData else {
        ioNumberDataPackets.pointee = 0
        return kBeamConverterStarveError
    }
    let encoder = Unmanaged<AudioEncoder>.fromOpaque(inUserData).takeUnretainedValue()
    return encoder.provideConverterInput(packets: ioNumberDataPackets, bufferList: ioData)
}
