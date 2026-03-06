// StreamSession.swift
// Represents one connected Beam client (iPhone).
// Handles pairing/authentication handshake over TCP, then sends video/audio data.

import Network
import CoreMedia
import CryptoKit
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "StreamSession")

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
    private(set) var authenticatedDeviceID: String?
    private var isTerminated = false

    /// Per-session viewport lock rect (normalized 0-1 in video frame space).
    /// Applied client-side by iOS — not reflected in the shared SCStream sourceRect.
    private(set) var viewportRect: CGRect?

    // Sequence tracking
    private var videoFrameNumber: UInt32 = 0
    private var audioSequenceNumber: UInt32 = 0

    private let sendQueue = DispatchQueue(label: "com.beam.session.send", qos: .userInteractive)
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastPongReceivedAt = Date()
    private let heartbeatTimeout: TimeInterval = 12

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
        guard !isTerminated else { return }
        isTerminated = true
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
            if let error { logger.error("Receive error: \(error)"); self.disconnect(); return }
            if isComplete { logger.info("Session \(self.id) peer closed connection"); self.disconnect(); return }
            guard let data, data.count == 4 else { return }

            let length = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }

            self.connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] payload, _, isComplete, error in
                guard let self else { return }
                if let error { logger.error("Receive payload error: \(error)"); self.disconnect(); return }
                if isComplete { self.disconnect(); return }
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
        case .codeVerify:
            if let code = message.code {
                PairingManager.shared.verifyCode(code)
            }
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
        authenticatedDeviceID = deviceID

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
        // iOS receiveNextPacket() expects every inbound packet to start with a
        // BeamPacketHeader. Wrap auth/pairing responses in a .control header so
        // the magic-byte check passes and the payload is dispatched correctly.
        let header = BeamPacketHeader(type: .control, flags: 0, payloadLength: UInt32(data.count))
        var packet = header.serialized()
        packet.append(data)
        sendTCP(packet.lengthPrefixed())
    }

    // MARK: - Control Messages

    private func handleControlMessage(_ message: BeamControlMessage) {
        guard isAuthenticated else { return }

        switch message.type {
        case .mediaKey:
            if case .mediaKey(let payload) = message.payload {
                MediaKeyDispatcher.send(payload.key)
            }
        case .pong:
            lastPongReceivedAt = Date()
        case .ping:
            let pong = BeamControlMessage(type: .pong, payload: nil)
            if let data = try? JSONEncoder().encode(pong) {
                sendTCP(data.lengthPrefixed())
            }
        case .streamStop:
            logger.info("Client requested stream stop")
            disconnect()
        case .qualityFeedback:
            if case .qualityFeedback(let payload) = message.payload {
                server?.handleQualityFeedback(payload.quality)
            }
        case .qualityRequest:
            if case .qualityRequest(let payload) = message.payload {
                server?.handleQualityRequest(payload.preset)
            }
        case .viewportLockRequest:
            if case .viewportLock(let payload) = message.payload {
                viewportRect = payload.locked
                    ? CGRect(x: payload.x, y: payload.y, width: payload.width, height: payload.height)
                    : nil
                // Viewport is applied client-side by iOS; no SCStream crop needed here.
            }
        default:
            break
        }
    }

    // MARK: - Quality Changed

    func sendQualityChanged(_ preset: StreamQualityPreset) {
        let msg = BeamControlMessage(
            type: .qualityChanged,
            payload: .qualityChanged(BeamQualityPayload(preset: preset))
        )
        guard let data = try? JSONEncoder().encode(msg) else { return }
        let header = BeamPacketHeader(type: .control, flags: 0, payloadLength: UInt32(data.count))
        var packet = header.serialized()
        packet.append(data)
        sendTCP(packet.lengthPrefixed())
    }

    func sendAudioFormatChanged(sampleRate: Double, channels: Int) {
        let msg = BeamControlMessage(
            type: .audioFormatChanged,
            payload: .audioFormat(BeamAudioFormatPayload(sampleRate: sampleRate, channels: channels))
        )
        guard let data = try? JSONEncoder().encode(msg) else { return }
        let header = BeamPacketHeader(type: .control, flags: 0, payloadLength: UInt32(data.count))
        var packet = header.serialized()
        packet.append(data)
        sendTCP(packet.lengthPrefixed())
    }

    // MARK: - Unpair notification

    func sendUnpaired() {
        let msg = BeamPairingMessage(
            type: .unpaired, deviceName: nil, deviceID: nil,
            code: nil, sharedSecret: nil, error: nil
        )
        sendPairingResponse(msg)
    }

    // MARK: - Streaming

    func beginReceivingStream(videoEncoder: VideoEncoder, audioEncoder: AudioEncoder) {
        logger.info("Session \(self.id) ready for streaming")
        startHeartbeat()
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        lastPongReceivedAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, isAuthenticated else { return }
            let elapsed = Date().timeIntervalSince(lastPongReceivedAt)
            if elapsed > heartbeatTimeout {
                logger.warning("Heartbeat timeout for session \(self.id) (\(elapsed, format: .fixed(precision: 1))s without pong)")
                disconnect()
                return
            }
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
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                logger.error("TCP send error: \(error)")
                self?.disconnect()
            }
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
