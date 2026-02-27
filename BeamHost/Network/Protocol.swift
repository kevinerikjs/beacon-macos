// Protocol.swift
// Beam Network Protocol - shared contract between macOS host and iOS client
// IMPORTANT: Any changes here must be mirrored in beam-ios/Beam/Streaming/Protocol.swift

import Foundation
import CoreMedia

// MARK: - Packet Types

enum BeamPacketType: UInt8 {
    case video      = 0x01  // H.264 video fragment
    case audio      = 0x02  // AAC audio chunk
    case control    = 0x03  // Control message (TCP, JSON-encoded)
    case heartbeat  = 0x04  // Keep-alive ping/pong (UDP)
    case spsPps     = 0x05  // H.264 SPS/PPS parameter sets (sent before first frame)
    case videoIDR   = 0x06  // H.264 IDR (keyframe) fragment
}

// MARK: - Packet Header
//
// Layout (10 bytes):
//   [0..3]  magic       = 0x4245414D ("BEAM")
//   [4]     type        = BeamPacketType raw value
//   [5]     flags       = reserved, set to 0
//   [6..9]  length      = payload byte count (big-endian UInt32)
//
// Total header = 10 bytes, followed by `length` bytes of payload.

struct BeamPacketHeader {
    static let magic: UInt32 = 0x4245414D  // "BEAM"
    static let size: Int = 10

    let type: BeamPacketType
    let flags: UInt8
    let payloadLength: UInt32

    func serialized() -> Data {
        var magic = BeamPacketHeader.magic.bigEndian
        var length = payloadLength.bigEndian
        var out = Data(capacity: BeamPacketHeader.size)
        withUnsafeBytes(of: &magic) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(flags)
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        return out
    }

    static func parse(from data: Data) -> BeamPacketHeader? {
        guard data.count >= BeamPacketHeader.size else { return nil }
        let magic = data[0..<4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard magic == BeamPacketHeader.magic else { return nil }
        guard let type = BeamPacketType(rawValue: data[4]) else { return nil }
        let flags = data[5]
        let length = data[6..<10].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        return BeamPacketHeader(type: type, flags: flags, payloadLength: length)
    }
}

// MARK: - Video Payload
//
// For video and videoIDR packets, payload layout:
//   [0..3]   frameNumber      UInt32 big-endian  (monotonically increasing)
//   [4..5]   fragmentIndex    UInt16 big-endian  (0-based)
//   [6..7]   totalFragments   UInt16 big-endian
//   [8..15]  presentationTS   Int64  big-endian  (microseconds, CMTime-derived)
//   [16...]  nalData          raw H.264 Annex B NAL unit bytes

struct BeamVideoPayloadHeader {
    static let size: Int = 16

    let frameNumber: UInt32
    let fragmentIndex: UInt16
    let totalFragments: UInt16
    let presentationTimestamp: Int64  // microseconds

    func serialized() -> Data {
        var out = Data(capacity: BeamVideoPayloadHeader.size)
        var fn = frameNumber.bigEndian
        var fi = fragmentIndex.bigEndian
        var tf = totalFragments.bigEndian
        var ts = presentationTimestamp.bigEndian
        withUnsafeBytes(of: &fn) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &fi) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &tf) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { out.append(contentsOf: $0) }
        return out
    }

    static func parse(from data: Data) -> BeamVideoPayloadHeader? {
        guard data.count >= BeamVideoPayloadHeader.size else { return nil }
        let fn  = data[0..<4].withUnsafeBytes  { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let fi  = data[4..<6].withUnsafeBytes  { $0.loadUnaligned(as: UInt16.self).bigEndian }
        let tf  = data[6..<8].withUnsafeBytes  { $0.loadUnaligned(as: UInt16.self).bigEndian }
        let ts  = data[8..<16].withUnsafeBytes { $0.loadUnaligned(as: Int64.self).bigEndian }
        return BeamVideoPayloadHeader(
            frameNumber: fn,
            fragmentIndex: fi,
            totalFragments: tf,
            presentationTimestamp: ts
        )
    }
}

// MARK: - Audio Payload
//
// For audio packets, payload layout:
//   [0..3]   sequenceNumber   UInt32 big-endian
//   [4..11]  presentationTS   Int64  big-endian (microseconds)
//   [12...]  aacData          raw AAC-LC ADTS bytes

struct BeamAudioPayloadHeader {
    static let size: Int = 12

    let sequenceNumber: UInt32
    let presentationTimestamp: Int64  // microseconds

    func serialized() -> Data {
        var out = Data(capacity: BeamAudioPayloadHeader.size)
        var sn = sequenceNumber.bigEndian
        var ts = presentationTimestamp.bigEndian
        withUnsafeBytes(of: &sn) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { out.append(contentsOf: $0) }
        return out
    }

    static func parse(from data: Data) -> BeamAudioPayloadHeader? {
        guard data.count >= BeamAudioPayloadHeader.size else { return nil }
        let sn = data[0..<4].withUnsafeBytes  { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let ts = data[4..<12].withUnsafeBytes { $0.loadUnaligned(as: Int64.self).bigEndian }
        return BeamAudioPayloadHeader(sequenceNumber: sn, presentationTimestamp: ts)
    }
}

// MARK: - Control Messages (JSON over TCP)

enum BeamControlMessageType: String, Codable {
    case mediaKey           = "media_key"
    case ping               = "ping"
    case pong               = "pong"
    case streamRequest      = "stream_request"
    case streamStop         = "stream_stop"
    case qualityFeedback    = "quality_feedback"
}

struct BeamControlMessage: Codable {
    let type: BeamControlMessageType
    let payload: BeamControlPayload?
}

enum BeamControlPayload: Codable {
    case mediaKey(BeamMediaKeyPayload)
    case qualityFeedback(BeamQualityFeedbackPayload)
    case empty

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let mk = try? container.decode(BeamMediaKeyPayload.self) {
            self = .mediaKey(mk)
        } else if let qf = try? container.decode(BeamQualityFeedbackPayload.self) {
            self = .qualityFeedback(qf)
        } else {
            self = .empty
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .mediaKey(let mk):     try container.encode(mk)
        case .qualityFeedback(let qf): try container.encode(qf)
        case .empty:                try container.encodeNil()
        }
    }
}

struct BeamMediaKeyPayload: Codable {
    enum Key: String, Codable {
        case playPause  = "play_pause"
        case next       = "next"
        case previous   = "previous"
    }
    let key: Key
}

struct BeamQualityFeedbackPayload: Codable {
    let droppedFrames: Int
    let bufferMs: Int
}

// MARK: - Pairing Messages (JSON over TCP)

enum BeamPairingMessageType: String, Codable {
    case hello          = "hello"       // iOS → macOS: I want to pair, here's my identity
    case challenge      = "challenge"   // macOS → iOS: here's the code to display
    case codeVerify     = "code_verify" // iOS → macOS: user entered this code
    case pairSuccess    = "pair_success"// macOS → iOS: here's the shared secret
    case pairFailed     = "pair_failed" // macOS → iOS: code wrong
    case authRequest    = "auth_request"// iOS → macOS: reconnect with stored secret
    case authSuccess    = "auth_success"// macOS → iOS: authenticated, stream starting
    case authFailed     = "auth_failed" // macOS → iOS: bad secret
}

struct BeamPairingMessage: Codable {
    let type: BeamPairingMessageType
    let deviceName: String?
    let deviceID: String?      // UUID, stable per device
    let code: String?          // 6-digit pairing code
    let sharedSecret: String?  // hex-encoded 32-byte random secret
    let error: String?
}

// MARK: - Helpers

extension CMTime {
    /// Convert to microseconds for wire protocol
    var microseconds: Int64 {
        guard timescale != 0 else { return 0 }
        return Int64(Double(value) / Double(timescale) * 1_000_000)
    }
}

extension Data {
    /// Encode as a length-prefixed TCP message: [UInt32 big-endian length][data]
    func lengthPrefixed() -> Data {
        var out = Data(capacity: 4 + count)
        var len = UInt32(count).bigEndian
        Swift.withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(self)
        return out
    }
}
