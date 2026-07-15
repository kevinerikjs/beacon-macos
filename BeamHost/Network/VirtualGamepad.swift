// VirtualGamepad.swift
// Creates a virtual HID game controller on the Mac and replays controller state
// received from the iPhone into it, so games see a real gamepad (full analog).
//
// Uses the public IOHIDUserDevice API (macOS 13+), which requires the
// `com.apple.developer.hid.virtual.device` entitlement (see BeamHost.entitlements).
// One virtual pad exists per host — Beam streams to a single client at a time.

import Foundation
import IOKit.hid
import Network
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "VirtualGamepad")

final class VirtualGamepad {

    static let shared = VirtualGamepad()
    private init() {}

    private var device: IOHIDUserDevice?
    private let queue = DispatchQueue(label: "com.beam.virtual-gamepad", qos: .userInteractive)

    /// HID report descriptor: Generic Desktop / Gamepad.
    /// Report layout (9 bytes, no report ID):
    ///   [0]   buttons 1-8:  A, B, X, Y, LB, RB, LThumb, RThumb
    ///   [1]   buttons 9-16: Menu, Options, Home, (5 unused)
    ///   [2]   hat switch (d-pad) in low nibble, 0-7 clockwise from up, 8 = released
    ///   [3-6] X, Y, Z, Rz — left stick X/Y, right stick X/Y (0-255, center 128, HID down = positive)
    ///   [7-8] Rx, Ry — left/right trigger (0-255)
    private static let reportDescriptor: [UInt8] = [
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x05,        // Usage (Gamepad)
        0xA1, 0x01,        // Collection (Application)
        //   16 buttons
        0x05, 0x09,        //   Usage Page (Button)
        0x19, 0x01,        //   Usage Minimum (1)
        0x29, 0x10,        //   Usage Maximum (16)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x01,        //   Logical Maximum (1)
        0x75, 0x01,        //   Report Size (1)
        0x95, 0x10,        //   Report Count (16)
        0x81, 0x02,        //   Input (Data, Variable, Absolute)
        //   Hat switch (d-pad)
        0x05, 0x01,        //   Usage Page (Generic Desktop)
        0x09, 0x39,        //   Usage (Hat Switch)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x07,        //   Logical Maximum (7)
        0x35, 0x00,        //   Physical Minimum (0)
        0x46, 0x3B, 0x01,  //   Physical Maximum (315)
        0x65, 0x14,        //   Unit (Degrees)
        0x75, 0x04,        //   Report Size (4)
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x42,        //   Input (Data, Variable, Absolute, Null State)
        0x75, 0x04,        //   Report Size (4) — padding
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x03,        //   Input (Constant)
        //   Sticks: X, Y, Z, Rz
        0x05, 0x01,        //   Usage Page (Generic Desktop)
        0x09, 0x30,        //   Usage (X)
        0x09, 0x31,        //   Usage (Y)
        0x09, 0x32,        //   Usage (Z)
        0x09, 0x35,        //   Usage (Rz)
        0x15, 0x00,        //   Logical Minimum (0)
        0x26, 0xFF, 0x00,  //   Logical Maximum (255)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x04,        //   Report Count (4)
        0x81, 0x02,        //   Input (Data, Variable, Absolute)
        //   Triggers: Rx, Ry
        0x09, 0x33,        //   Usage (Rx)
        0x09, 0x34,        //   Usage (Ry)
        0x15, 0x00,        //   Logical Minimum (0)
        0x26, 0xFF, 0x00,  //   Logical Maximum (255)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x02,        //   Report Count (2)
        0x81, 0x02,        //   Input (Data, Variable, Absolute)
        0xC0,              // End Collection
    ]

    // MARK: - Public API

    /// Feed one controller state report. Creates the virtual device on first use;
    /// `connected == false` tears it down (games see the controller unplug).
    func handle(_ state: BeamControllerState, connected: Bool) {
        queue.async { [self] in
            guard connected else {
                teardownLocked()
                return
            }
            if device == nil {
                createLocked()
            }
            let report = Self.report(for: state)
            guard let device else {
                #if DEBUG
                // Dev-only fallback while the hid.virtual.device entitlement is pending
                // Apple approval: forward reports to `sudo vpad-spike --bridge`, which
                // owns the virtual pad as root. See tools/vpad-spike.
                bridgeSendLocked(report)
                #endif
                return
            }
            let result = report.withUnsafeBufferPointer { buf in
                IOHIDUserDeviceHandleReportWithTimeStamp(
                    device, mach_absolute_time(), buf.baseAddress!, buf.count
                )
            }
            if result != kIOReturnSuccess {
                logger.warning("HID report submission failed: \(String(format: "0x%08X", result))")
            }
        }
    }

    /// Tear down the virtual device (e.g. when the streaming session ends).
    func teardown() {
        queue.async { [self] in teardownLocked() }
    }

    // MARK: - Device lifecycle (on queue)

    private func createLocked() {
        let properties: [String: Any] = [
            kIOHIDReportDescriptorKey: Data(Self.reportDescriptor),
            kIOHIDVendorIDKey: 0x1209,          // pid.codes open-source VID
            kIOHIDProductIDKey: 0xBEA0,
            kIOHIDVersionNumberKey: 1,
            kIOHIDProductKey: "Beam Controller",
            kIOHIDManufacturerKey: "Beam",
            kIOHIDTransportKey: "Virtual",
            kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDPrimaryUsageKey: kHIDUsage_GD_GamePad,
        ]
        guard let created = IOHIDUserDeviceCreateWithProperties(
            kCFAllocatorDefault, properties as CFDictionary, 0
        ) else {
            logger.error("Failed to create virtual gamepad — is the com.apple.developer.hid.virtual.device entitlement present?")
            return
        }
        device = created
        logger.info("Virtual gamepad created")
    }

    private func teardownLocked() {
        #if DEBUG
        bridge?.cancel()
        bridge = nil
        #endif
        guard device != nil else { return }
        device = nil  // releasing the last reference removes the HID device
        logger.info("Virtual gamepad removed")
    }

    #if DEBUG
    // MARK: - vpad-spike bridge (dev only, on queue)

    private var bridge: NWConnection?
    private var bridgeAnnounced = false
    static let bridgePort: UInt16 = 3398

    private func bridgeSendLocked(_ report: [UInt8]) {
        if bridge == nil {
            let conn = NWConnection(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: Self.bridgePort)!,
                using: .udp
            )
            conn.start(queue: queue)
            bridge = conn
        }
        if !bridgeAnnounced {
            bridgeAnnounced = true
            logger.info("Virtual pad unavailable (entitlement pending) — forwarding reports to vpad-spike bridge on 127.0.0.1:\(Self.bridgePort). Run: sudo vpad-spike --bridge")
        }
        bridge?.send(content: Data(report), completion: .idempotent)
    }
    #endif

    // MARK: - Report building

    private static func report(for state: BeamControllerState) -> [UInt8] {
        var b0: UInt8 = 0
        if state.buttons.contains(.a)             { b0 |= 1 << 0 }
        if state.buttons.contains(.b)             { b0 |= 1 << 1 }
        if state.buttons.contains(.x)             { b0 |= 1 << 2 }
        if state.buttons.contains(.y)             { b0 |= 1 << 3 }
        if state.buttons.contains(.leftShoulder)  { b0 |= 1 << 4 }
        if state.buttons.contains(.rightShoulder) { b0 |= 1 << 5 }
        if state.buttons.contains(.leftThumb)     { b0 |= 1 << 6 }
        if state.buttons.contains(.rightThumb)    { b0 |= 1 << 7 }

        var b1: UInt8 = 0
        if state.buttons.contains(.menu)    { b1 |= 1 << 0 }
        if state.buttons.contains(.options) { b1 |= 1 << 1 }
        if state.buttons.contains(.home)    { b1 |= 1 << 2 }

        return [
            b0,
            b1,
            hat(for: state.buttons),
            axisByte(state.leftX),
            axisByte(state.leftY, inverted: true),   // HID Y: down = positive
            axisByte(state.rightX),
            axisByte(state.rightY, inverted: true),
            state.leftTrigger,
            state.rightTrigger,
        ]
    }

    /// Hat switch: 0-7 clockwise starting at up; 8 = null (released).
    private static func hat(for buttons: BeamControllerState.Buttons) -> UInt8 {
        let up = buttons.contains(.dpadUp), down = buttons.contains(.dpadDown)
        let left = buttons.contains(.dpadLeft), right = buttons.contains(.dpadRight)
        switch (up, right, down, left) {
        case (true, false, false, false):  return 0
        case (true, true, false, false):   return 1
        case (false, true, false, false):  return 2
        case (false, true, true, false):   return 3
        case (false, false, true, false):  return 4
        case (false, false, true, true):   return 5
        case (false, false, false, true):  return 6
        case (true, false, false, true):   return 7
        default:                           return 8
        }
    }

    /// Maps a GameController axis (-32767...32767, up/right positive) to a HID
    /// axis byte (0-255, center ~128).
    private static func axisByte(_ value: Int16, inverted: Bool = false) -> UInt8 {
        let v = inverted ? -Int(value) : Int(value)
        return UInt8(clamping: (v + 32767) >> 8)
    }
}
