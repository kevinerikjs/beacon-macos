// StreamSession.swift
// Represents one connected Beam client (iPhone).
// Handles pairing/authentication handshake over TCP, then sends video/audio data.

import Network
import CoreMedia
import CryptoKit
import OSLog

private let logger = Logger(subsystem: "com.beam.host", category: "StreamSession")

/// Max UDP payload size (safe for most networks; keeps under typical MTU of 1500)
private let kMaxUDPPayload = 1400

final class StreamSession {

    let id: String = UUID().uuidString

    private let connection: NWConnection
    private weak var server: StreamServer?

    private var udpConnection: NWConnection?
    private var clientUDPEndpoint: NWEndpoint?

    private var isAuthenticated = false
    private var sharedSecret: SymmetricKey?

    // Sequence tracking
    private var videoFrameNumber: UInt32 = 0
    private var audioSequenceNumber: UInt32 = 0

    private let sendQueue = DispatchQueue(label: "com.beam.session.send", qos: .userInteractive)
    private var heartbeatTimer: DispatchSourceTimer?

    init(connection: NWConnection, server: StreamServer) {
        self.connection = connection
        self.server = server
    }

    // MARK: - Lifecycle

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionStateChange(state)
        }
        connection.start(queue: sendQueue)
        receiveNextMessage()
    }

    func disconnect() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        connection.cancel()
        udpConnection?.cancel()
        logger.info("Session \(self.id) disconnected")
    }

    // MARK: - Authentication

    private func handleConnectionStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("Session TCP connection ready from \(String(describing: self.connection.endpoint))")
        case .failed(let error):
            logger.error("Session TCP failed: \(error)")
            server?.sessionDisconnected(self)
        case .cancelled:
            server?.sessionDisconnected(self)
        default:
            break
        }
    }

    private func receiveNextMessage() {
        // Read 4-byte length prefix first
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { logger.error("Receive error: \(error)"); return }
            guard let data, data.count == 4 else { return }

            let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            self.connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] payload, _, _, error in
                guard let self else { return }
                if let error { logger.error("Receive payload error: \(error)"); return }
                guard let payload else { return }

                self.handleIncomingMessage(payload)
                self.receiveNextMessage()
            }
        }
    }

    private func handleIncomingMessage(_ data: Data) {
        do {
            let message = try JSONDecoder().decode(BeamPairingMessage.self, from: data)
            handlePairingMessage(message)
        } catch {
            // Try control message
            if let message = try? JSONDecoder().decode(BeamControlMessage.self, from: data) {
                handleControlMessage(message)
            } else {
                logger.error("Failed to decode incoming message")
            }
        }
    }

    private func handlePairingMessage(_ message: BeamPairingMessage) {
        switch message.type {
        case .authRequest:
            handleAuthRequest(message)
        case .hello:
            handleHello(message)
        default:
            logger.warning("Unexpected pairing message type: \(message.type.rawValue)")
        }
    }

    private func handleAuthRequest(_ message: BeamPairingMessage) {
        guard let deviceID = message.deviceID,
              let secretHex = message.sharedSecret,
              let secretData = Data(hexEncoded: secretHex) else {
            sendPairingResponse(BeamPairingMessage(
                type: .authFailed, deviceName: nil, deviceID: nil,
                code: nil, sharedSecret: nil, error: "Invalid auth request"
            ))
            return
        }

        // Look up the device in paired devices
        let pairedDevices = KeyStore.shared.loadPairedDevices()
        guard let device = pairedDevices.first(where: { $0.id == deviceID }) else {
            sendPairingResponse(BeamPairingMessage(
                type: .authFailed, deviceName: nil, deviceID: nil,
                code: nil, sharedSecret: nil, error: "Device not paired"
            ))
            return
        }

        // Verify the secret matches
        guard device.sharedSecret == secretData else {
            sendPairingResponse(BeamPairingMessage(
                type: .authFailed, deviceName: nil, deviceID: nil,
                code: nil, sharedSecret: nil, error: "Authentication failed"
            ))
            return
        }

        // Success
        isAuthenticated = true
        sharedSecret = SymmetricKey(data: device.sharedSecret)

        sendPairingResponse(BeamPairingMessage(
            type: .authSuccess, deviceName: Host.current().localizedName,
            deviceID: nil, code: nil, sharedSecret: nil, error: nil
        ))

        server?.sessionAuthenticated(self, deviceName: device.name)
        logger.info("Session authenticated for device '\(device.name)'")
    }

    private func handleHello(_ message: BeamPairingMessage) {
        // New pairing request - forward to PairingManager
        guard let deviceID = message.deviceID, let deviceName = message.deviceName else { return }
        PairingManager.shared.beginPairing(deviceID: deviceID, deviceName: deviceName, session: self)
    }

    // MARK: - Pairing responses

    func sendPairingResponse(_ message: BeamPairingMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        sendTCP(data.lengthPrefixed())
    }

    // MARK: - Control Messages

    private func handleControlMessage(_ message: BeamControlMessage) {
        guard isAuthenticated else { return }

        switch message.type {
        case .mediaKey:
            if case .mediaKey(let payload) = message.payload {
                MediaKeyDispatcher.send(payload.key)
            }
        case .ping:
            let pong = BeamControlMessage(type: .pong, payload: nil)
            if let data = try? JSONEncoder().encode(pong) {
                sendTCP(data.lengthPrefixed())
            }
        case .streamStop:
            logger.info("Client requested stream stop")
            server?.sessionDisconnected(self)
        default:
            break
        }
    }

    // MARK: - Streaming

    func beginReceivingStream(videoEncoder: VideoEncoder, audioEncoder: AudioEncoder) {
        logger.info("Session \(self.id) ready for streaming")
        startHeartbeat()
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, isAuthenticated else { return }
            // Send a raw heartbeat packet; iOS responds with a pong (keeps connection alive)
            let header = BeamPacketHeader(type: .heartbeat, flags: 0, payloadLength: 0)
            sendTCP(header.serialized().lengthPrefixed())
        }
        timer.resume()
        heartbeatTimer = timer
    }

    // MARK: - Send Video

    func send(spsPps data: Data) {
        guard isAuthenticated else { return }
        sendUDP(type: .spsPps, flags: 0, payload: data)
    }

    func send(videoData: Data, pts: CMTime, isKeyframe: Bool) {
        guard isAuthenticated else { return }

        let frameNum = videoFrameNumber
        videoFrameNumber &+= 1

        let videoHeader = BeamVideoPayloadHeader(
            frameNumber: frameNum,
            fragmentIndex: 0,
            totalFragments: 1,
            presentationTimestamp: pts.microseconds
        )

        // Fragment large frames
        let maxPayload = kMaxUDPPayload - BeamVideoPayloadHeader.size
        if videoData.count <= maxPayload {
            var payload = videoHeader.serialized()
            payload.append(videoData)
            sendUDP(type: isKeyframe ? .videoIDR : .video, flags: 0, payload: payload)
        } else {
            let fragments = videoData.chunked(into: maxPayload)
            let totalFragments = UInt16(fragments.count)
            for (index, fragment) in fragments.enumerated() {
                let fragHeader = BeamVideoPayloadHeader(
                    frameNumber: frameNum,
                    fragmentIndex: UInt16(index),
                    totalFragments: totalFragments,
                    presentationTimestamp: pts.microseconds
                )
                var payload = fragHeader.serialized()
                payload.append(fragment)
                sendUDP(type: isKeyframe ? .videoIDR : .video, flags: 0, payload: payload)
            }
        }
    }

    // MARK: - Send Audio

    func send(audioData: Data, pts: CMTime) {
        guard isAuthenticated else { return }

        let seqNum = audioSequenceNumber
        audioSequenceNumber &+= 1

        let audioHeader = BeamAudioPayloadHeader(
            sequenceNumber: seqNum,
            presentationTimestamp: pts.microseconds
        )
        var payload = audioHeader.serialized()
        payload.append(audioData)
        sendUDP(type: .audio, flags: 0, payload: payload)
    }

    // MARK: - Network Send Helpers

    private func sendTCP(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { logger.error("TCP send error: \(error)") }
        })
    }

    private func sendUDP(type: BeamPacketType, flags: UInt8, payload: Data) {
        let header = BeamPacketHeader(type: type, flags: flags, payloadLength: UInt32(payload.count))
        var packet = header.serialized()
        packet.append(payload)

        // Send over the TCP connection using the framing layer for reliability
        // In v2 we can upgrade to actual UDP; for MVP TCP is simpler and sufficient on LAN
        sendTCP(packet.lengthPrefixed())
    }
}

// MARK: - Data Extension

private extension Data {
    func chunked(into size: Int) -> [Data] {
        stride(from: 0, to: count, by: size).map {
            self[$0..<Swift.min($0 + size, count)]
        }
    }

    init?(hexEncoded hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
