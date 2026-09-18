// harness-client: the phone side of the latency harness, running on the Mac.
//
// Same Phoros stack Beam uses: PhorosConnection, PairingClient, FrameAssembler, VideoFormat,
// ControllerSampler, plus a VTDecompressionSession where Beam has AVSampleBufferDisplayLayer.
// It connects to a Beacon in harness mode on this machine, streams, forwards the harness pad
// (DualShock 4 identity) as .input packets, asks Beacon to press that pad on a schedule, and
// stamps every stage it can see into a log file: stage,id,mach_ns[,extra].
//
//   P<id>  press requested (control message sent)
//   H1     .input packet sent with an A transition (numbered by transition)
//   H7     assembled frame received (id = frame number, extra = pts_us,bytes)
//   H8     decoded frame's luma flipped (id = frame number, extra = luma)
//
// Usage: harness-client [presses=100] [interval_ms=700] [log=/Volumes/yuh/business/.scratch/harness/client.log]

import CoreMedia
import Foundation
import GameController
import Network
import Phoros
import PhorosInput
import PhorosMedia
import PhorosNetwork
import PhorosSession
import VideoToolbox

let args = CommandLine.arguments
let pressCount = args.count > 1 ? Int(args[1]) ?? 100 : 100
let intervalMs = args.count > 2 ? Int(args[2]) ?? 700 : 700
let logPath = args.count > 3 ? args[3] : "/Volumes/yuh/business/.scratch/harness/client.log"
let preset: QualityPreset = args.count > 4 ? (QualityPreset(rawValue: args[4]) ?? .p1080_60) : .p1080_60

var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
func nowNanos() -> UInt64 { mach_absolute_time() * UInt64(timebase.numer) / UInt64(timebase.denom) }

let logQueue = DispatchQueue(label: "harness.log")
try? FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: logPath, contents: nil)
let logHandle = try! FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
func log(_ stage: String, _ id: Int, at nanos: UInt64 = nowNanos(), extra: String = "") {
    let line = "\(stage),\(id),\(nanos)\(extra.isEmpty ? "" : "," + extra)\n"
    logQueue.async { logHandle.write(line.data(using: .utf8)!) }
}
func stderr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - Connection

let secret = SharedSecret(hex: "5e1f2a9c4d7b3e6a8f0c1d2e3b4a5968778695a4b3c2d1e0f1e2d3c4b5a69788")!
let capabilities = ClientCapabilities(deviceName: "Harness", deviceID: "harness-client", audioCodecs: [.pcmFloat32], videoCodecs: [.h264], wantsAudio: false)
let params = PhorosConnection.parameters()
let link = PhorosConnection(to: NWEndpoint.hostPort(host: "127.0.0.1", port: 7979), parameters: params)

var authenticated = false
var assembler = FrameAssembler()
var formatDescription: CMVideoFormatDescription?
var decoder: VTDecompressionSession?
var lastLuma: Double = -1
var flipCount = 0
var framesReceived = 0
var framesDecoded = 0
let decodeQueue = DispatchQueue(label: "harness.decode", qos: .userInteractive)

func sendControl(_ message: ControlMessage) {
    let data = try! JSONEncoder().encode(message)
    link.send(data)
}

func makeDecoder(_ description: CMVideoFormatDescription) {
    if let decoder { VTDecompressionSessionInvalidate(decoder) }
    var session: VTDecompressionSession?
    let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { _, refcon, status, _, imageBuffer, pts, _ in
        guard status == noErr, let imageBuffer, let refcon else { return }
        let frameNumber = Int(bitPattern: refcon)
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        // Mean luma of a centre patch of the Y plane. The flash window covers the whole display,
        // so any patch works; the centre avoids the menu bar and dock.
        let width = CVPixelBufferGetWidthOfPlane(imageBuffer, 0), height = CVPixelBufferGetHeightOfPlane(imageBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0) else { return }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, n = 0
        for y in stride(from: height / 2 - 100, to: height / 2 + 100, by: 4) {
            for x in stride(from: width / 2 - 100, to: width / 2 + 100, by: 4) { sum += Int(p[y * rowBytes + x]); n += 1 }
        }
        let luma = Double(sum) / Double(n)
        framesDecoded += 1
        if framesDecoded % 60 == 1 { log("L", frameNumber, extra: String(format: "%.0f,%dx%d", luma, width, height)) }
        if lastLuma >= 0, abs(luma - lastLuma) > 60 {
            flipCount += 1
            log("H8", frameNumber, extra: String(format: "%.0f", luma))
        }
        lastLuma = luma
    }, decompressionOutputRefCon: nil)
    let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary, outputCallback: &callback, decompressionSessionOut: &session)
    guard status == noErr, let session else { stderr("decoder create failed \(status)"); return }
    VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    decoder = session
}

func decode(_ frame: AssembledFrame) {
    guard let formatDescription, let decoder,
          let sample = VideoFormat.makeSampleBuffer(annexB: frame.bitstream, formatDescription: formatDescription, presentationTime: CMTime(value: CMTimeValue(frame.presentationTimestamp), timescale: 1_000_000)) else { return }
    var flags = VTDecodeInfoFlags()
    VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], frameRefcon: UnsafeMutableRawPointer(bitPattern: Int(frame.frameNumber)), infoFlagsOut: &flags)
}

link.onReady = {
    stderr("connected; authenticating")
    let auth = capabilities.authRequest(secret: secret)
    link.send(try! JSONEncoder().encode(auth))
}
link.onEnd = { reason in stderr("link ended: \(reason)"); exit(2) }
link.onFrame = { frame in
    switch frame {
    case .packet(let packet):
        switch packet.header.type {
        case .video, .videoKeyframe:
            guard let header = VideoFragmentHeader.parse(from: packet.payload) else { return }
            _ = header
            decodeQueue.async {
                if let assembled = assembler.receive(packet.payload, isKeyframe: packet.header.type == .videoKeyframe) {
                    framesReceived += 1
                    log("H7", Int(assembled.frameNumber), extra: "\(assembled.presentationTimestamp),\(assembled.bitstream.count)")
                    decode(assembled)
                }
            }
        case .parameterSets:
            guard let codec = VideoCodecID(packetFlags: packet.header.flags),
                  let description = VideoFormat.makeDescription(parameterSets: packet.payload, codec: codec) else { return }
            decodeQueue.async { formatDescription = description; makeDecoder(description); stderr("parameter sets: \(codec.wireName)") }
        case .control:
            handleJSON(packet.payload)
        default: break
        }
    case .message(let json):
        handleJSON(json)
    }
}

func handleJSON(_ data: Data) {
    if let pairing = try? JSONDecoder().decode(PairingMessage.self, from: data), pairing.type == .authSuccess || pairing.type == .authFailed {
        switch PairingClient.interpret(pairing) {
        case .authenticated(let host, _, _, _):
            authenticated = true
            stderr("authenticated; host supportsControllerInput=\(host.supportsControllerInput)")
            sendControl(.qualityRequest(preset))
            startController()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { startPresses() }
        case .failed(let reason): stderr("auth failed: \(reason)"); exit(3)
        default: break
        }
        return
    }
    if let control = try? JSONDecoder().decode(ControlMessage.self, from: data) {
        if case .ping = control { sendControl(.pong) }
    }
}

// MARK: - Controller (the harness pad, DualShock 4 identity, forwarded like Beam does)

let sampler = ControllerSampler()
var lastA = false
var inputTransitions = 0
func startController() {
    GCController.shouldMonitorBackgroundEvents = true
    sampler.accepts = { $0.productCategory.localizedCaseInsensitiveContains("dualshock") }
    sampler.onAttachmentChange = { attached in stderr("harness pad attached=\(attached)") }
    sampler.onReport = { report, connected in
        let a = report.buttons.contains(.a)
        if a != lastA { lastA = a; inputTransitions += 1; log("H1", inputTransitions, extra: a ? "down" : "up") }
        link.send(Packet.encode(.input, flags: connected ? ControllerReport.connectedFlag : 0, payload: report.serialized()))
    }
    sampler.start()
}

// MARK: - Press schedule

var pressID = 0
func startPresses() {
    stderr("pressing \(pressCount) times every ~\(intervalMs) ms at \(preset.rawValue)")
    func next() {
        pressID += 1
        if pressID > pressCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                stderr("done: frames received=\(framesReceived) decoded=\(framesDecoded) flips=\(flipCount)")
                logQueue.sync {}
                exit(0)
            }
            return
        }
        log("P", pressID)
        sendControl(.mediaKey(MediaKeyCommand(key: .playPause, controlID: "harness.press.\(pressID)")))
        let jitter = Double(Int.random(in: -150...150)) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(intervalMs) / 1000 + jitter) { next() }
    }
    next()
}

link.start()
RunLoop.main.run()
