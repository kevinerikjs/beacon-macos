// vpad-spike — standalone validation tool for the Beam virtual gamepad (BEAM-16).
//
// Creates the same virtual HID gamepad Beacon creates (descriptor kept in sync with
// BeamHost/Network/VirtualGamepad.swift), then:
//   1. reports whether GameController (GCController) picks it up and with which profile,
//   2. feeds a demo input pattern (left stick circle, button/d-pad/trigger cycle) for 120s
//      so it can be observed live in a game, Gamepad Tester, or a GCController app.
//
// Build:  swiftc -O -framework IOKit -framework GameController -o vpad-spike main.swift
//
// FINDING (2026-07-16, macOS 26 / Darwin 25): the com.apple.developer.hid.virtual.device
// entitlement is enforced unconditionally — running as root does NOT bypass it (all
// creation attempts return nil under sudo), and ad-hoc signing a binary with the
// entitlement gets it SIGKILLed by AMFI. There is no pre-approval test path; the
// capability must be granted by Apple to the team.
//
// This tool remains useful AFTER the capability is granted: sign it with the
// entitlement + a real signing identity, run it, and it validates that the gamepad
// descriptor is accepted and that GCController picks the pad up, then feeds demo
// input for observation in a game or gamepad tester. It also serves as a diagnostic
// (attempt matrix distinguishes descriptor rejection from entitlement denial).
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

print("Creating virtual gamepad (VID 0x1209, PID 0xBEA0)… (euid=\(geteuid()))")

func attempt(_ label: String, _ props: [String: Any]) -> IOHIDUserDevice? {
    let d = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, props as CFDictionary, 0)
    print("  [\(label)] \(d == nil ? "❌ nil" : "✅ created")")
    return d
}

var device = attempt("gamepad descriptor + full properties", properties)

if device == nil {
    // Diagnose: descriptor problem vs entitlement enforcement.
    device = attempt("gamepad descriptor only", [kIOHIDReportDescriptorKey: Data(reportDescriptor)])
    if device == nil {
        // Canonical minimal descriptor (2-axis, 2-button joystick straight from the HID spec).
        // If THIS also fails, the block is entitlement/AMFI, not our descriptor.
        let canonical: [UInt8] = [
            0x05, 0x01, 0x09, 0x04, 0xA1, 0x01, 0xA1, 0x00,
            0x05, 0x09, 0x19, 0x01, 0x29, 0x02, 0x15, 0x00, 0x25, 0x01,
            0x95, 0x02, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x06, 0x81, 0x03,
            0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81, 0x25, 0x7F,
            0x75, 0x08, 0x95, 0x02, 0x81, 0x02, 0xC0, 0xC0,
        ]
        device = attempt("canonical joystick descriptor", [kIOHIDReportDescriptorKey: Data(canonical)])
    }
}

guard let device else {
    print("❌ All creation attempts failed (euid=\(geteuid())).")
    print("   The hid.virtual.device entitlement is enforced unconditionally on this macOS")
    print("   (root does not bypass; ad-hoc signing is AMFI-killed). The capability must be")
    print("   granted by Apple, then this tool must be signed with the entitlement to run.")
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
