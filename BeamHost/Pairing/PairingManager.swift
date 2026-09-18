// PairingManager.swift
// Manages the pairing flow: shows the code, checks the client's answer, and saves the
// shared secret. The protocol side (challenge, verify, secret issue) is
// PhorosSession.PairingHost; this file is the window, the Keychain and AppState.

import OSLog
import Phoros
import PhorosSession
import SwiftUI

private let logger = Logger(subsystem: "com.beam.beacon", category: "PairingManager")

@Observable
final class PairingManager {

    static let shared = PairingManager()

    // MARK: - State

    /// The current 6-digit pairing code displayed in the QR / code window.
    var currentCode: String? = nil

    /// Whether a pairing session is in progress.
    var isPairingActive: Bool = false

    private var pairing: PairingHost?
    private var pendingSession: StreamSession?
    private var codeExpiryTask: Task<Void, Never>?

    private init() {}

    // MARK: - Begin Pairing

    /// Called when an iPhone sends a "hello" message requesting pairing.
    func beginPairing(deviceID: String, deviceName: String, session: StreamSession) {
        cancelPairing()

        var host = PairingHost(capabilities: StreamSession.hostCapabilities())
        let hello = PairingMessage(type: .hello, deviceName: deviceName, deviceID: deviceID)
        guard let (challenge, code) = host.begin(hello: hello) else { return }
        pairing = host
        pendingSession = session
        currentCode = code
        isPairingActive = true

        // The code goes through the person, never over the wire.
        session.sendPairingResponse(challenge)

        Task { @MainActor in
            PairingWindowController.shared.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        codeExpiryTask = Task {
            try? await Task.sleep(for: .seconds(300))
            if !Task.isCancelled { await self.expirePairing() }
        }

        logger.info("Pairing started for device '\(deviceName)' with code \(code)")
    }

    // MARK: - Verify Code

    /// Called when the iPhone sends back the code the user entered.
    func verifyCode(_ code: String) {
        guard var host = pairing, let session = pendingSession,
              let deviceID = host.peerDeviceID, let deviceName = host.peerDeviceName else {
            logger.warning("verifyCode called with no active pairing session")
            return
        }

        let outcome = host.verify(PairingMessage(type: .codeVerify, deviceID: deviceID, code: code))
        pairing = host

        switch outcome {
        case .ignored:
            logger.warning("Code arrived for an expired pairing attempt")
        case .rejected(let reply):
            logger.warning("Pairing code mismatch for '\(deviceName)'")
            session.sendPairingResponse(reply)
        case .paired(let secret, let reply):
            KeyStore.shared.addPairedDevice(PairedDevice(
                id: deviceID, name: deviceName, sharedSecret: secret.bytes, lastSeen: Date()
            ))
            Task { @MainActor in
                AppState.shared?.pairedDevices = KeyStore.shared.loadPairedDevices()
            }
            session.sendPairingResponse(reply)
            logger.info("Pairing complete for '\(deviceName)' (id: \(deviceID))")
            cancelPairing()
        }
    }

    // MARK: - Cancel / Expire

    func cancelPairing() {
        codeExpiryTask?.cancel()
        codeExpiryTask = nil
        currentCode = nil
        isPairingActive = false
        pairing = nil
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
