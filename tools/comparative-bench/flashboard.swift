// flashboard: the thing every client streams during a latency trial.
//
// A full-screen window that flips between black and white at randomised intervals and writes
// the exact moment of each flip to a log. Whatever is streaming this Mac carries the flip to
// the phone, and a camera or a capture device sees it arrive. The difference is the latency of
// that app, measured the same way for every app, because nothing here is inside any of them.
//
// Randomised intervals matter: a fixed cadence can beat against a capture frame rate and hide
// in one phase of it forever.
//
// Usage: flashboard [trials] [log]
//   F,<index>,<mach_ns>,<1 white | 0 black>

import AppKit
import QuartzCore

let trials = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 120 : 120
let logPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/Volumes/yuh/business/.scratch/bench/board.log"

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func nowNanos() -> UInt64 { mach_absolute_time() * UInt64(timebase.numer) / UInt64(timebase.denom) }

try? FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: logPath, contents: nil)
let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
let logQueue = DispatchQueue(label: "flashboard.log")
func log(_ line: String) { logQueue.async { handle.write((line + "\n").data(using: .utf8)!) } }

final class BoardView: NSView {
    var white = false
    override var isOpaque: Bool { true }
    override func draw(_ rect: NSRect) {
        (white ? NSColor.white : NSColor.black).setFill()
        rect.fill()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// BENCH_WINDOW=<width>x<height> flashes in a window instead of over the whole screen, for a
// smoke test that does not take the Mac away from whoever is using it, and for measuring an app
// that streams a single window.
let screen = NSScreen.main!
var frame = screen.frame
if let spec = ProcessInfo.processInfo.environment["BENCH_WINDOW"] {
    let parts = spec.split(separator: "x").compactMap { Double($0) }
    if parts.count == 2 { frame = NSRect(x: screen.frame.midX - parts[0] / 2, y: screen.frame.midY - parts[1] / 2, width: parts[0], height: parts[1]) }
}
let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.level = .screenSaver
window.isOpaque = true
window.backgroundColor = .black
let view = BoardView(frame: frame)
window.contentView = view
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

var index = 0
// The moment the flip reaches the glass is the moment the frame containing it is displayed, not
// the moment we asked for it. CADisplayLink gives us that: stamp inside the callback that
// follows the redraw, which is within one refresh of the photons.
var pendingFlip: Bool? = nil
var link: CADisplayLink?

func scheduleNext() {
    guard index < trials * 2 else {
        log("DONE,\(index),\(nowNanos()),0")
        logQueue.sync {}
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.terminate(nil) }
        return
    }
    // 0.7 to 1.4 s, uniform, so flips land in every phase of any capture frame rate
    let delay = Double.random(in: 0.7...1.4)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        view.white.toggle()
        view.needsDisplay = true
        pendingFlip = view.white
    }
}

final class Ticker {
    @objc func tick(_ sender: CADisplayLink) {
        if let white = pendingFlip {
            pendingFlip = nil
            log("F,\(index),\(nowNanos()),\(white ? 1 : 0)")
            index += 1
            scheduleNext()
        }
    }
}
let ticker = Ticker()
link = view.displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
link?.add(to: .main, forMode: .common)

FileHandle.standardError.write("flashboard: \(trials) trials, log \(logPath)\n".data(using: .utf8)!)
scheduleNext()
app.run()
