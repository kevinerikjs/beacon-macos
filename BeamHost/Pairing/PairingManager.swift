// PairingManager.swift
// Manages the pairing flow: generates codes, validates them, and saves shared secrets.
// Pairing uses a 6-digit code displayed on macOS that the user enters on iPhone.
// After pairing, devices share a random 32-byte secret stored in Keychain.

import SwiftUI
import CryptoKit
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "PairingManager")

@Observable
final class PairingManager {

    static let shared = PairingManager()

    // MARK: - State

    /// The current 6-digit pairing code displayed in the QR / code window.
    var currentCode: String? = nil

    /// Whether a pairing session is in progress.
    var isPairingActive: Bool = false

    // Pending pairing session
    private var pendingDeviceID: String?
    private var pendingDeviceName: String?
    private var pendingSession: StreamSession?
    private var codeExpiryTask: Task<Void, Never>?

    private init() {}

    // MARK: - Begin Pairing

    /// Called when an iPhone sends a "hello" message requesting pairing.
    func beginPairing(deviceID: String, deviceName: String, session: StreamSession) {
        // Cancel any existing pairing attempt
        cancelPairing()

        pendingDeviceID = deviceID
        pendingDeviceName = deviceName
        pendingSession = session

        // Generate 6-digit code
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        currentCode = code
        isPairingActive = true

        // Send challenge to iPhone so it knows a code has been issued
        let challenge = BeamPairingMessage(
            type: .challenge,
            deviceName: Host.current().localizedName,
            deviceID: nil,
            code: nil,  // Don't send the code over the wire - user types it manually
            sharedSecret: nil,
            error: nil
        )
        session.sendPairingResponse(challenge)

        // Show pairing window on macOS
        Task { @MainActor in
            PairingWindowController.shared.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Auto-expire after 5 minutes
        codeExpiryTask = Task {
            try? await Task.sleep(for: .seconds(300))
            if !Task.isCancelled { await self.expirePairing() }
        }

        logger.info("Pairing started for device '\(deviceName)' with code \(code)")
    }

    // MARK: - Verify Code

    /// Called when the iPhone sends back the code the user entered on macOS.
    func verifyCode(_ code: String) {
        guard isPairingActive,
              let expectedCode = currentCode,
              let deviceID = pendingDeviceID,
              let deviceName = pendingDeviceName,
              let session = pendingSession else {
            logger.warning("verifyCode called with no active pairing session")
            return
        }

        guard code == expectedCode else {
            logger.warning("Pairing code mismatch: expected \(expectedCode), got \(code)")
            let failMsg = BeamPairingMessage(
                type: .pairFailed, deviceName: nil, deviceID: nil,
                code: nil, sharedSecret: nil, error: "Incorrect code"
            )
            session.sendPairingResponse(failMsg)
            return
        }

        // Generate shared secret
        let secretBytes = SymmetricKey(size: .bits256)
        let secretData = secretBytes.withUnsafeBytes { Data($0) }
        let secretHex = secretData.map { String(format: "%02x", $0) }.joined()

        // Save to Keychain
        let device = PairedDevice(
            id: deviceID,
            name: deviceName,
            sharedSecret: secretData,
            lastSeen: Date()
        )
        KeyStore.shared.addPairedDevice(device)

        // Update AppState
        Task { @MainActor in
            AppState.shared?.pairedDevices = KeyStore.shared.loadPairedDevices()
        }

        // Send success to iPhone with the shared secret
        let successMsg = BeamPairingMessage(
            type: .pairSuccess,
            deviceName: Host.current().localizedName,
            deviceID: nil,
            code: nil,
            sharedSecret: secretHex,
            error: nil,
            // Hand the phone our tailnet address at pair time so away-from-home streaming
            // works later without the user configuring anything (BEAM-19). nil when this Mac
            // has no Tailscale — the phone then simply has no remote fallback.
            tailscaleHosts: TailscaleAddress.advertisedHosts(),
            supportsRemoteAccess: true
        )
        session.sendPairingResponse(successMsg)

        logger.info("Pairing complete for '\(deviceName)' (id: \(deviceID))")
        cancelPairing()
    }

    // MARK: - Cancel / Expire

    func cancelPairing() {
        codeExpiryTask?.cancel()
        codeExpiryTask = nil
        currentCode = nil

        isPairingActive = false
        pendingDeviceID = nil
        pendingDeviceName = nil
        pendingSession = nil

        Task { @MainActor in
            PairingWindowController.shared.close()
        }
    }

    @MainActor
    private func expirePairing() {
        logger.info("Pairing code expired")
        cancelPairing()
    }
}
