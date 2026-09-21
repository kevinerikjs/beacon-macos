// Harness.swift
// Latency harness, host side. Active only with BEACON_HARNESS=1 in the environment.
//
// The harness measures the loop "controller press → Mac reacts → phone shows it" on one
// machine, so every stage shares one clock. Beacon in harness mode:
//   - authenticates a client with a fixed secret (no pairing UI),
//   - owns a second virtual controller (DualShock 4 identity, the "harness pad") and presses
//     its A button when the client asks over the control channel,
//   - shows a full-screen window that flips black/white when the Beam Controller (the Xbox
//     identity Beacon creates for the client) reports A down,
//   - writes one line per event to a log file: stage,id,mach_ns.
// Everything else is the normal pipeline. See tools/latency-harness/README.md.

import AppKit
import Foundation
import ScreenCaptureKit
import GameController
import OSLog
import Phoros
import PhorosInput
import PhorosMedia
import PhorosSession

enum Harness {
    static let isEnabled = ProcessInfo.processInfo.environment["BEACON_HARNESS"] == "1"
    static let deviceID = "harness-client"
    static let secretHex = "5e1f2a9c4d7b3e6a8f0c1d2e3b4a5968778695a4b3c2d1e0f1e2d3c4b5a69788"
    static let logPath = ProcessInfo.processInfo.environment["BEACON_HARNESS_LOG"] ?? "/Volumes/yuh/business/.scratch/harness/beacon.log"

    private static let logger = Logger(subsystem: "com.beam.beacon", category: "Harness")
    private static let queue = DispatchQueue(label: "com.beam.harness", qos: .userInteractive)
    private static var handle: FileHandle?
    private static var pad: VirtualGamepad?
    private static var padDown = false
    private static var flash: HarnessFlashWindow?
    static var flashWindowNumber: Int = 0

    /// The flash window as ScreenCaptureKit sees it, for window-mode capture.
    static func flashSCWindow() async -> SCWindow? {
        for _ in 0..<20 {
            if flashWindowNumber != 0, let w = await ScreenCapture.availableWindows().first(where: { Int($0.windowID) == flashWindowNumber }) {
                logger.warning("harness window as SCK sees it: \(String(describing: w.frame), privacy: .public) layer \(w.windowLayer)")
                return w
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }
    private static var lastInputA = false
    private static var inputPressCounter = 0

    /// Experiment switches, only in harness mode, from BEACON_EXP="key=value,key=value".
    /// Keys: delay0, speed, llrc, profile=baseline|main|high, burst=<x>|none, queue=<n>.
    static let experiment: [String: String] = {
        guard isEnabled, let raw = ProcessInfo.processInfo.environment["BEACON_EXP"] else { return [:] }
        var out: [String: String] = [:]
        for item in raw.split(separator: ",") {
            let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
            out[kv[0]] = kv.count > 1 ? kv[1] : "1"
        }
        return out
    }()

    static func encoderTuning() -> VideoEncoderConfiguration.LatencyTuning {
        var t = VideoEncoderConfiguration.LatencyTuning()
        // Beacon's defaults, measured on the harness (BEAM-47): the low-latency rate control
        // mode halves encode time and holds the target bitrate where the default mode
        // overshoots it by half on busy content. The other knobs measured no gain.
        t.lowLatencyRateControl = true
        guard isEnabled else { return t }
        if experiment["delay0"] != nil { t.maxFrameDelayCount = 0 }
        if experiment["speed"] != nil { t.prioritizeSpeed = true }
        if experiment["nollrc"] != nil { t.lowLatencyRateControl = false }
        switch experiment["profile"] {
        case "baseline": t.h264Profile = .baseline
        case "main": t.h264Profile = .main
        default: break
        }
        if let b = experiment["burst"] { t.burstMultiplier = b == "none" ? nil : Double(b) }
        return t
    }

    static var captureQueueDepth: Int? { experiment["queue"].flatMap(Int.init) }
    /// BEACON_EXP=fps=120: capture and encode at this rate instead of the preset's.
    static func frameRate(for preset: Double) -> Double { experiment["fps"].flatMap(Double.init) ?? preset }
    /// BEACON_EXP=gop=N: seconds between periodic keyframes. Beacon's default is 5: the
    /// transport never loses a frame, joiners and recoveries ask for their own keyframe, and
    /// a 1080p keyframe is a quarter second of a 6 Mbps link every time it goes out.
    static var keyframeInterval: Double { experiment["gop"].flatMap(Double.init) ?? 5 }

    /// `sched=old` reproduces the shipped scheduler: no queue-age shedding and a byte budget the
    /// in-flight counter alone could never reach, so nothing is ever dropped.
    static func sendPolicy(base: SendPolicy) -> SendPolicy {
        guard isEnabled, experiment["sched"] == "old" else { return base }
        var p = base
        p.maximumQueuedBytes = Int.max / 2
        p.maximumVideoQueueAge = 1e9
        return p
    }

    static var timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    static func nowNanos() -> UInt64 { mach_absolute_time() * UInt64(timebase.numer) / UInt64(timebase.denom) }

    /// One event line. `id` correlates a press across stages; frame stages use the frame number.
    /// FNV-1a over a bitstream: the harness compares what the host sent with what the client
    /// assembled, frame by frame.
    static func hash(_ data: Data) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        data.withUnsafeBytes { buf in for b in buf { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
        return h
    }

    static func log(_ stage: String, _ id: Int, at nanos: UInt64 = nowNanos(), extra: String = "") {
        guard isEnabled else { return }
        let line = "\(stage),\(id),\(nanos)\(extra.isEmpty ? "" : "," + extra)\n"
        queue.async {
            if handle == nil {
                let url = URL(fileURLWithPath: logPath)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: logPath, contents: nil)
                handle = try? FileHandle(forWritingTo: url)
                handle?.seekToEndOfFile()
            }
            handle?.write(line.data(using: .utf8)!)
        }
    }

    static func startIfEnabled() {
        guard isEnabled else { return }
        logger.warning("Beacon is running in latency-harness mode")
        let gamepad = VirtualGamepad(profile: .dualShock4)
        gamepad.onEvent = { event in logger.info("harness pad: \(String(describing: event), privacy: .public)") }
        gamepad.handle(.neutral, connected: true)
        pad = gamepad
        DispatchQueue.main.async { flash = HarnessFlashWindow() }
        log("START", 0)
    }

    /// The client asked for press `id`. Toggle the harness pad's A button. H0.
    static func press(id: Int) {
        guard let pad else { return }
        queue.async {
            padDown.toggle()
            pad.handle(ControllerReport(buttons: padDown ? [.a] : []), connected: true)
            log("H0", id, extra: padDown ? "down" : "up")
        }
    }

    /// `.input` packet arrived. Presses are numbered by A transitions, in order. H2.
    static func inputReceived(_ report: ControllerReport) {
        let a = report.buttons.contains(.a)
        guard a != lastInputA else { return }
        lastInputA = a
        inputPressCounter += 1
        log("H2", inputPressCounter, extra: a ? "down" : "up")
    }

    static func inputPosted() {
        log("H3", inputPressCounter)
    }
}

/// Full-screen window that flips between black and white on every A transition of the
/// Beam Controller. The flip is the visual change the client detects in the stream.
final class HarnessFlashWindow {
    private let window: NSWindow
    /// Read by the synthetic frame source (BEACON_EXP=synthetic): what colour the "screen" is.
    static var isWhite = false
    private var white = false { didSet { HarnessFlashWindow.isWhite = white } }
    private var flips = 0
    private var observers: [NSObjectProtocol] = []
    private var lastA = false
    private let mover = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    private var moverTimer: DispatchSourceTimer?
    private var moverX: CGFloat = 0
    private var loadLayers: [CALayer] = []
    private var loadPhase: Double = 0

    init() {
        // A 1920x1080 window at the back of the normal level, in the bottom-right corner. Beacon
        // captures this window alone (window mode), so the person can keep using the Mac and
        // whatever covers the window does not reach the capture.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = self.size
        let origin = NSPoint(x: screen.frame.maxX - size.width, y: screen.frame.minY)
        window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Beam latency harness"
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.level = .normal
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.orderBack(nil)
        Harness.flashWindowNumber = window.windowNumber

        // ScreenCaptureKit only delivers frames when pixels change. A game changes every frame,
        // so keep a small grey square moving along the bottom edge (outside the luma patch).
        mover.wantsLayer = true
        mover.layer?.backgroundColor = NSColor.gray.cgColor
        window.contentView?.addSubview(mover)
        // Drive the animation from the window's display link, so every commit lands in its
        // own refresh. A 60 Hz dispatch timer drifts against vsync and half its commits merge
        // into the next one: ScreenCaptureKit then delivers idle frames for the merged ones.
        displayLink = window.displayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .distantFuture)
        // BEACON_EXP=load fills the bands above and below the client's centre luma patch with
        // noise that changes every frame, so the encoder works at game-like bitrates instead of
        // the ~30 kbps a black window with one moving square produces.
        if Harness.experiment["load"] != nil, let content = window.contentView {
            content.wantsLayer = true
            // Default: 48 px of noise stretched with linear filtering, so the bands look like
            // smooth game-world blobs (large flat gradients, some edges). load=blocks is 8 px
            // random blocks (nearly incompressible spatially), load=noise re-randomises every frame.
            let mode = Harness.experiment["load"] ?? ""
            let noise = HarnessFlashWindow.noiseImage(side: mode == "blocks" || mode == "noise" ? 256 : 48)
            for y: CGFloat in [0, size.height - 320] {
                let layer = CALayer()
                layer.frame = CGRect(x: 0, y: y, width: size.width, height: 320)
                layer.contents = noise
                layer.contentsGravity = .resize
                layer.magnificationFilter = mode == "blocks" || mode == "noise" ? .nearest : .linear
                layer.actions = ["contentsRect": NSNull()]
                content.layer?.addSublayer(layer)
                loadLayers.append(layer)
            }
        }
        t.setEventHandler {}
        t.resume()
        moverTimer = t
        GCController.shouldMonitorBackgroundEvents = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        })
        GCController.controllers().forEach(attach)
    }

    private var displayLink: CADisplayLink?
    private let size = NSSize(width: 1920, height: 1080)

    private var ticks = 0
    @objc private func tick() {
        ticks += 1
        if ticks % 60 == 0 { Harness.log("TICK", ticks, extra: window.occlusionState.contains(.visible) ? "visible" : "occluded") }
        do {
            moverX = (moverX + 8).truncatingRemainder(dividingBy: size.width - 24)
            mover.frame.origin = CGPoint(x: moverX, y: 8)
            if !loadLayers.isEmpty {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                // Scroll the texture a few pixels per frame (game-like motion the encoder can
                // predict) instead of jumping to random noise (worst-case entropy, which no
                // real content has). BEACON_EXP=load=noise keeps the random jump.
                let jump = Harness.experiment["load"] == "noise"
                loadPhase += 0.0045
                for (i, layer) in loadLayers.enumerated() {
                    let ox = jump ? CGFloat.random(in: 0...0.5) : 0.25 + 0.25 * cos(loadPhase * (i == 0 ? 1 : 1.3))
                    let oy = jump ? CGFloat.random(in: 0...0.5) : 0.25 + 0.25 * sin(loadPhase * (i == 0 ? 0.7 : 1))
                    layer.contentsRect = CGRect(x: ox, y: oy, width: 0.5, height: 0.5)
                }
                CATransaction.commit()
            }
        }
    }

    private static func noiseImage(side: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = .random(in: 0...255); bytes[i + 1] = .random(in: 0...255); bytes[i + 2] = .random(in: 0...255); bytes[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func attach(_ controller: GCController) {
        // Only the controller Beacon creates for the client. The harness pad is a DualShock 4.
        guard controller.productCategory.localizedCaseInsensitiveContains("xbox"), let pad = controller.extendedGamepad else { return }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            guard let self, pressed != lastA else { return }
            lastA = pressed
            flips += 1
            white.toggle()
            window.backgroundColor = white ? .white : .black
            window.contentView?.layer?.backgroundColor = (white ? NSColor.white : NSColor.black).cgColor
            window.displayIfNeeded()
            CATransaction.flush()
            Harness.log("H4", flips, extra: white ? "white" : "black")
        }
    }
}


/// Frames without the screen: a timer at the capture rate fills a BGRA buffer with the flash
/// window's colour (plus a moving bar so the encoder has motion) and hands it to the same
/// delegate path ScreenCaptureKit uses. No Screen Recording grant needed, so a rebuilt
/// Beacon runs unattended. BEACON_EXP=synthetic.
final class HarnessSyntheticSource {
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?
    private let width: Int, height: Int
    private var phase = 0
    private var rng: UInt64 = 0x9E3779B97F4A7C15
    private var bands: [[UInt32]] = []
    /// Rows of noise per frame: sets how many bits a frame costs. HARNESS_NOISE_ROWS, default 1/64 of the height, which fills a 10 Mbps cap at 120 fps.
    private lazy var noiseRows: Int = Int(ProcessInfo.processInfo.environment["HARNESS_NOISE_ROWS"] ?? "") ?? max(8, height / 64)
    private var bandIndex = 0
    init(width: Int, height: Int) { self.width = width; self.height = height }

    func start(frameRate: Double, sink: @escaping (CMSampleBuffer) -> Void) {
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                      kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "beam.harness.synthetic", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: 1.0 / frameRate, leeway: .microseconds(200))
        t.setEventHandler { [weak self] in
            guard let self, let pool else { return }
            let t0 = DispatchTime.now().uptimeNanoseconds
            guard let buffer = Self.make(pool) else { Harness.log("H5N", 0); return }
            self.fill(buffer)
            let gen = (DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            if gen > 4 { Harness.log("H5G", Int(gen)) }
            if self.format == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &self.format) }
            guard let format = self.format else { return }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(frameRate)), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
            if let sample { sink(sample) }
        }
        t.resume(); timer = t
    }

    private static func make(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var b: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b); return b
    }

    private func fill(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let v: UInt8 = HarnessFlashWindow.isWhite ? 235 : 16
        memset(base, Int32(v), rowBytes * height)
        // a 40 px bar sweeping across so every frame differs, and a band of fresh noise in the
        // top quarter so the encoder spends its whole bitrate budget (a flat frame would
        // compress to nothing and the link experiments need the bytes). The detector's
        // centre patch stays clean.
        phase = (phase + 6) % max(1, width - 40)
        let p = base.assumingMemoryBound(to: UInt8.self)
        // pre-generated noise bands, a different one each frame (fresh per-pixel noise is too
        // slow in a Debug build)
        if bands.isEmpty {
            var seed = rng
            for _ in 0..<8 {
                var band = [UInt32](repeating: 0, count: width * noiseRows)
                for i in 0..<band.count { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; band[i] = UInt32(truncatingIfNeeded: seed) | 0xff00_0000 }
                bands.append(band)
            }
            rng = seed
        }
        bandIndex = (bandIndex + 1) % bands.count
        bands[bandIndex].withUnsafeBytes { src in
            for y in 0..<noiseRows { memcpy(p + y * rowBytes, src.baseAddress! + y * width * 4, width * 4) }
        }
        for y in stride(from: height / 4, to: height / 4 + height / 8, by: 1) {
            let row = p + y * rowBytes
            for x in phase..<(phase + 40) { row[x * 4] = 200; row[x * 4 + 1] = 60; row[x * 4 + 2] = 60; row[x * 4 + 3] = 255 }
        }
    }
}
