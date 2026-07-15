// vpad-spike — standalone validation tool for the Beam virtual gamepad (BEAM-16).
//
// Creates the same virtual HID gamepad Beacon creates (descriptor kept in sync with
// BeamHost/Network/VirtualGamepad.swift), then:
//   1. reports whether GameController (GCController) picks it up and with which profile,
//   2. feeds a demo input pattern (left stick circle, button/d-pad/trigger cycle) for 120s
//      so it can be observed live in a game, Gamepad Tester, or a GCController app.
//
// Build:  swiftc -O -framework IOKit -framework GameController -o vpad-spike main.swift
// Run:    sudo ./vpad-spike     (root bypasses the com.apple.developer.hid.virtual.device
//         entitlement, which is Apple-approval-gated; Beacon itself needs the entitlement)
//
// Bridge mode:  sudo ./vpad-spike --bridge
// Instead of demo input, listens on UDP 127.0.0.1:3398 for 9-byte HID reports.
// Debug builds of Beacon forward controller reports here when they can't create the
// virtual pad themselves — full end-to-end passthrough testing before Apple approval.
//
// Success criteria: "GCController connected" is printed with an extendedGamepad profile,
// and the demo inputs are visible in a gamepad tester. If GCController does NOT pick it
// up, the fallback is emulating a known controller (DualShock 4 descriptor + VID/PID).

import Foundation
import GameController
import IOKit

// Keep in sync with VirtualGamepad.reportDescriptor in BeamHost.
let reportDescriptor: [UInt8] = [
    0x05, 0x01, 0x09, 0x05, 0xA1, 0x01,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x10, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x10, 0x81, 0x02,
    0x05, 0x01, 0x09, 0x39, 0x15, 0x00, 0x25, 0x07, 0x35, 0x00, 0x46, 0x3B, 0x01, 0x65, 0x14,
    0x75, 0x04, 0x95, 0x01, 0x81, 0x42, 0x75, 0x04, 0x95, 0x01, 0x81, 0x03,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35,
    0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x04, 0x81, 0x02,
    0x09, 0x33, 0x09, 0x34, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02,
    0xC0,
]

let properties: [String: Any] = [
    kIOHIDReportDescriptorKey: Data(reportDescriptor),
    kIOHIDVendorIDKey: 0x1209,
    kIOHIDProductIDKey: 0xBEA0,
    kIOHIDVersionNumberKey: 1,
    kIOHIDProductKey: "Beam Controller",
    kIOHIDManufacturerKey: "Beam",
    kIOHIDTransportKey: "Virtual",
    kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
    kIOHIDPrimaryUsageKey: kHIDUsage_GD_GamePad,
]

print("Creating virtual gamepad (VID 0x1209, PID 0xBEA0)…")
guard let device = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties as CFDictionary, 0) else {
    print("❌ IOHIDUserDeviceCreateWithProperties failed.")
    print("   Not running as root and no hid.virtual.device entitlement → expected failure.")
    print("   Re-run with: sudo ./vpad-spike")
    exit(1)
}
print("✅ Virtual HID device created.")

// --- GCController detection ---
var seenByGameController = false
NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
    guard let c = note.object as? GCController else { return }
    seenByGameController = true
    let profile = c.extendedGamepad != nil ? "extendedGamepad ✅"
                : c.microGamepad != nil ? "microGamepad (partial ⚠️)"
                : "unknown profile ⚠️"
    print("🎮 GCController connected: \"\(c.vendorName ?? "?")\" — profile: \(profile)")
}
GCController.startWirelessControllerDiscovery {}

// --- Bridge mode: replay reports forwarded by a Debug build of Beacon ---
if CommandLine.arguments.contains("--bridge") {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { print("❌ socket() failed"); exit(1) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(3398).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { print("❌ bind(127.0.0.1:3398) failed — already running?"); exit(1) }
    print("🌉 Bridge mode: replaying HID reports from Beacon (UDP 127.0.0.1:3398). Ctrl-C to quit.")
    var reportCount = 0
    Thread.detachNewThread {
        var buf = [UInt8](repeating: 0, count: 16)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            guard n == 9 else { continue }
            _ = IOHIDUserDeviceHandleReportWithTimeStamp(device, mach_absolute_time(), buf, 9)
            reportCount += 1
            if reportCount == 1 { print("📥 First report received from Beacon — passthrough is live.") }
            if reportCount % 600 == 0 { print("📥 \(reportCount) reports replayed") }
        }
    }
    RunLoop.main.run()
    exit(0)
}

// --- Demo input loop (~120 s) ---
func report(buttons b0: UInt8, b1: UInt8 = 0, hat: UInt8 = 8,
            lx: UInt8 = 128, ly: UInt8 = 128, rx: UInt8 = 128, ry: UInt8 = 128,
            lt: UInt8 = 0, rt: UInt8 = 0) {
    var bytes: [UInt8] = [b0, b1, hat, lx, ly, rx, ry, lt, rt]
    let r = IOHIDUserDeviceHandleReportWithTimeStamp(device, mach_absolute_time(), &bytes, bytes.count)
    if r != kIOReturnSuccess { print("⚠️ report failed: 0x\(String(r, radix: 16))") }
}

var tick = 0
let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
    tick += 1
    let t = Double(tick) / 60.0
    let lx = UInt8(clamping: Int(128 + 100 * cos(t * 2 * .pi / 3)))   // left stick: slow circle
    let ly = UInt8(clamping: Int(128 + 100 * sin(t * 2 * .pi / 3)))
    let phase = (tick / 60) % 8
    let b0: UInt8 = phase < 4 ? (1 << UInt8(phase)) : 0                // A,B,X,Y one per second
    let hat: UInt8 = phase >= 4 ? UInt8((phase - 4) * 2) : 8           // then d-pad U,R,D,L
    let lt = UInt8(clamping: Int(127 + 127 * sin(t * 2 * .pi / 4)))    // triggers: slow pulse
    report(buttons: b0, hat: hat, lx: lx, ly: ly, lt: lt, rt: 255 - lt)

    if tick == 120 {  // after 2 s, report GCController verdict
        if !seenByGameController {
            print("⚠️ No GCControllerDidConnect after 2 s — games using GameController may not")
            print("   see this pad. Raw-HID games/testers may still work. If so, plan the")
            print("   DualShock 4 descriptor fallback.")
        }
        print("Feeding demo input for ~2 min — watch it in a gamepad tester (e.g. hardwaretester.com/gamepad) or a game.")
    }
    if tick >= 120 * 60 { exit(0) }
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
