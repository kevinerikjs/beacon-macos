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
        guard isEnabled else { return t }
        if experiment["delay0"] != nil { t.maxFrameDelayCount = 0 }
        if experiment["speed"] != nil { t.prioritizeSpeed = true }
        if experiment["llrc"] != nil { t.lowLatencyRateControl = true }
        switch experiment["profile"] {
        case "baseline": t.h264Profile = .baseline
        case "main": t.h264Profile = .main
        default: break
        }
        if let b = experiment["burst"] { t.burstMultiplier = b == "none" ? nil : Double(b) }
        return t
    }

    static var captureQueueDepth: Int? { experiment["queue"].flatMap(Int.init) }

    static var timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    static func nowNanos() -> UInt64 { mach_absolute_time() * UInt64(timebase.numer) / UInt64(timebase.denom) }

    /// One event line. `id` correlates a press across stages; frame stages use the frame number.
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
    private var white = false
    private var flips = 0
    private var observers: [NSObjectProtocol] = []
    private var lastA = false
    private let mover = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    private var moverTimer: DispatchSourceTimer?
    private var moverX: CGFloat = 0

    init() {
        // A 1920x1080 window at the back of the normal level, in the bottom-right corner. Beacon
        // captures this window alone (window mode), so the person can keep using the Mac and
        // whatever covers the window does not reach the capture.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 1920, height: 1080)
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
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            moverX = (moverX + 8).truncatingRemainder(dividingBy: size.width - 24)
            mover.frame.origin = CGPoint(x: moverX, y: 8)
        }
        t.resume()
        moverTimer = t
        GCController.shouldMonitorBackgroundEvents = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        })
        GCController.controllers().forEach(attach)
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
