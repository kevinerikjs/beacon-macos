// AudioEncoder.swift
// AAC-LC audio encoding via AudioToolbox AudioConverter.
// Input: PCM from ScreenCaptureKit (Float32, interleaved stereo, 44100 Hz)
// Output: AAC-LC ADTS frames

import AudioToolbox
import CoreMedia
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.beam.host", category: "AudioEncoder")

// MARK: - Delegate

protocol AudioEncoderDelegate: AnyObject {
    func audioEncoder(_ encoder: AudioEncoder, didEncodeChunk data: Data, presentationTime: CMTime)
}

// MARK: - AudioEncoder

final class AudioEncoder {

    weak var delegate: AudioEncoderDelegate?

    private var converter: AudioConverterRef?
    private let outputBitrate: Int = 128_000  // 128 kbps stereo AAC
    private let sampleRate: Double = 44100
    private let channels: UInt32 = 2

    // PCM buffer for accumulating input before encoding
    private var inputBuffer = Data()
    private var inputPCMFormat: AudioStreamBasicDescription?

    // Track presentation time of buffered audio
    private var bufferStartTime: CMTime = .invalid

    private let encoderQueue = DispatchQueue(label: "com.beam.host.audioencoder", qos: .userInteractive)

    // MARK: - Lifecycle

    func start() throws {
        guard converter == nil else { return }

        // Input format: Float32 non-interleaved or Int16 - ScreenCaptureKit provides Float32
        var inputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        // Output format: AAC-LC
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,  // AAC-LC standard frame size
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var conv: AudioConverterRef?
        let status = AudioConverterNew(&inputFormat, &outputFormat, &conv)
        guard status == noErr, let conv else {
            throw AudioEncoderError.converterCreationFailed(status)
        }

        // Set bitrate
        var bitrate = UInt32(outputBitrate)
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)

        self.converter = conv
        self.inputPCMFormat = inputFormat
        logger.info("AudioEncoder started - AAC-LC \(self.outputBitrate / 1000)kbps")
    }

    func stop() {
        guard let converter else { return }
        AudioConverterDispose(converter)
        self.converter = nil
        inputBuffer.removeAll()
        bufferStartTime = .invalid
        logger.info("AudioEncoder stopped")
    }

    // MARK: - Encode

    func encode(sampleBuffer: CMSampleBuffer) {
        guard converter != nil else { return }

        encoderQueue.async { [weak self] in
            self?.processSampleBuffer(sampleBuffer)
        }
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let converter else { return }

        // Get PCM data from the sample buffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var dataPointer: UnsafeMutablePointer<CChar>?
        var dataLength = 0
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &dataLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let ptr = dataPointer else { return }

        // Capture presentation time of first buffered sample
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !bufferStartTime.isValid { bufferStartTime = pts }

        inputBuffer.append(UnsafeBufferPointer(start: UnsafePointer<UInt8>(bitPattern: Int(bitPattern: ptr)), count: dataLength))

        // AAC-LC frame = 1024 PCM frames
        let bytesPerPCMFrame = Int(4 * channels)  // Float32 * 2 channels
        let aacFrameSize = 1024 * bytesPerPCMFrame

        // Encode all complete AAC frames available
        while inputBuffer.count >= aacFrameSize {
            encodeOneAACFrame(from: converter)
        }
    }

    private func encodeOneAACFrame(from converter: AudioConverterRef) {
        let bytesPerPCMFrame = Int(4 * channels)
        let aacFrameSize = 1024 * bytesPerPCMFrame

        guard inputBuffer.count >= aacFrameSize else { return }

        let pcmFrameData = inputBuffer.prefix(aacFrameSize)
        inputBuffer.removeFirst(aacFrameSize)

        // Build AudioBufferList for input PCM
        var inputData = pcmFrameData
        let encodedPTS = bufferStartTime

        // Advance buffer start time by one AAC frame duration
        if bufferStartTime.isValid {
            let frameDuration = CMTime(value: 1024, timescale: CMTimeScale(sampleRate))
            bufferStartTime = bufferStartTime + frameDuration
        }

        inputData.withUnsafeMutableBytes { rawInput in
            let inputPointer = rawInput.baseAddress!

            let inputABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: channels,
                    mDataByteSize: UInt32(aacFrameSize),
                    mData: inputPointer
                )
            )

            // Output buffer - AAC frame is typically < 768 bytes per channel
            let outputBufferSize = 2048
            var outputData = Data(count: outputBufferSize)
            outputData.withUnsafeMutableBytes { rawOutput in
                let outputPointer = rawOutput.baseAddress!

                var outputABL = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: channels,
                        mDataByteSize: UInt32(outputBufferSize),
                        mData: outputPointer
                    )
                )

                var ioOutputDataPacketSize: UInt32 = 1
                var packetDescription = AudioStreamPacketDescription()

                // AudioConverterFillComplexBuffer is synchronous - pointer is valid throughout
                var inputABLCopy = inputABL
                var convertStatus: OSStatus = noErr
                var encodedBytes = 0

                withUnsafeMutablePointer(to: &inputABLCopy) { ablPointer in
                    var userData = AudioEncoderUserData(
                        inputABL: ablPointer,
                        remainingPackets: 1
                    )
                    convertStatus = AudioConverterFillComplexBuffer(
                        converter,
                        audioEncoderDataProc,
                        &userData,
                        &ioOutputDataPacketSize,
                        &outputABL,
                        &packetDescription
                    )
                    encodedBytes = Int(outputABL.mBuffers.mDataByteSize)
                }

                if convertStatus == noErr, ioOutputDataPacketSize > 0, encodedBytes > 0 {
                    let encodedData = Data(bytes: outputPointer, count: encodedBytes)
                    let adtsData = addADTSHeader(to: encodedData)
                    self.delegate?.audioEncoder(self, didEncodeChunk: adtsData, presentationTime: encodedPTS)
                }
            }
        }
    }

    // MARK: - ADTS Header
    // ADTS wrapping is needed for the iOS AVAudioEngine to consume the AAC frames.

    private func addADTSHeader(to aacData: Data) -> Data {
        // ADTS header is 7 bytes (without CRC)
        let adtsLength = aacData.count + 7
        var header = Data(count: 7)

        // AAC-LC profile = 1 (profile - 1)
        // 44100 Hz sample rate index = 4
        // 2 channels
        let samplerateIndex: UInt8 = 4   // 44100 Hz
        let channelConfig: UInt8 = UInt8(channels)
        let profile: UInt8 = 1          // AAC-LC

        header[0] = 0xFF
        header[1] = 0xF9  // MPEG-4 AAC, no CRC
        header[2] = ((profile & 0x3) << 6) | ((samplerateIndex & 0xF) << 2) | ((channelConfig >> 2) & 0x1)
        header[3] = ((channelConfig & 0x3) << 6) | (UInt8((adtsLength >> 11) & 0x3))
        header[4] = UInt8((adtsLength >> 3) & 0xFF)
        header[5] = UInt8((adtsLength & 0x7) << 5) | 0x1F
        header[6] = 0xFC

        var result = header
        result.append(aacData)
        return result
    }
}

// MARK: - Converter Callback User Data

private struct AudioEncoderUserData {
    var inputABL: UnsafeMutablePointer<AudioBufferList>
    var remainingPackets: UInt32
}

private func audioEncoderDataProc(
    _ converter: AudioConverterRef,
    _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = inUserData?.assumingMemoryBound(to: AudioEncoderUserData.self) else {
        return -1
    }

    if userData.pointee.remainingPackets == 0 {
        ioNumberDataPackets.pointee = 0
        return kAudio_ParamError
    }

    ioData.pointee = userData.pointee.inputABL.pointee
    ioNumberDataPackets.pointee = 1
    userData.pointee.remainingPackets = 0
    return noErr
}

// MARK: - Errors

enum AudioEncoderError: Error, LocalizedError {
    case converterCreationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed(let code):
            return "AudioConverter creation failed (OSStatus \(code))"
        }
    }
}
