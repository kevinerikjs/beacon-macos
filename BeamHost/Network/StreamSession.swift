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

    /// Codec this session's client can actually decode. Defaults to .pcmFloat32 and is only
    /// ever raised by an explicit advertisement in this connection's authRequest. It is a
    /// per-connection property: never derived from a prior connection, a stored capability,
    /// or the paired-device record.
    private(set) var negotiatedAudioCodec: BeamAudioCodec = .pcmFloat32

    private var sharedSecret: SymmetricKey?
    private(set) var authenticatedDeviceID: String?
    private var isTerminated = false

    // Sequence tracking
    private var videoFrameNumber: UInt32 = 0
    private var audioSequenceNumber: UInt32 = 0

    private let sendQueue = DispatchQueue(label: "com.beam.session.send", qos: .userInteractive)

    // MARK: - Send backpressure (BEAM-21)
    //
    // All media travels over the TCP control connection (see sendUDP, a misnomer). On a LAN
    // that is harmless because bandwidth vastly exceeds bitrate. Over a constrained link —
    // cellular, or a DERP-relayed tailnet — it is fatal: TCP never drops, so once the encoder
    // outpaces the link every frame is queued rather than discarded. Latency then grows
    // without bound and NEVER recovers, because the backlog has to be drained before anything
    // current is displayed. That is the "2 fps from 10 seconds ago" failure, and it is also
    // why lowering the quality preset didn't help — a lower bitrate doesn't drain a backlog
    // that has already formed.
    //
    // Live video must drop late frames rather than buffer them. We track bytes handed to the
    // Network framework but not yet written, and once that exceeds roughly a second of the
    // current bitrate we discard non-keyframe video instead of enqueueing it.
    //
    // ACCOUNTING (BEAM-24): the counters below are mutated from at least three threads — the
    // VideoToolbox output callback (video sends), AudioEncoder.encoderQueue (audio sends) and
    // sendQueue (send completions). The old code asserted they all ran on sendQueue and used a
    // bare `+=`; they do not, and a lost decrement permanently inflated the backlog, which with
    // the old shared-counter gate meant audio was switched off for the rest of the session.
    // Every read and write now goes through `backlogLock`, and the counters are re-anchored to
    // zero whenever nothing is outstanding so drift can never accumulate.
    private let backlogLock = NSLock()
    private var inFlightBytes = 0        // total (video + audio + control), guarded
    private var inFlightAudioBytes = 0   // audio only, guarded
    private var outstandingSends = 0     // guarded
    private var droppedFrames = 0
    private var lastDropLogAt = Date.distantPast
    /// Wall-clock time of the last audio chunk actually handed to the connection. Audio must
    /// never be silent for longer than `maxAudioDropWindow` while the encoder is producing,
    /// no matter what the backlog counters say — see `send(audioData:codec:pts:)`.
    private var lastAudioSentAt = Date.distantPast
    private let maxAudioDropWindow: TimeInterval = 1.0

    /// Backlog above which non-keyframe video is dropped. ~192 KB is about a second at
    /// 1.5 Mbps and a quarter-second at 6 Mbps, so it stays small enough to keep latency
    /// bounded without dropping on brief, normal bursts.
    private let maxQueuedMediaBytes = 192 * 1024

    /// Audio gets its own, higher ceiling and is checked separately.
    ///
    /// HISTORY (BEAM-21): audio used to be uncompressed Float32 stereo PCM — 44100 x 2ch x 4B =
    /// 352,800 B/s = 2.82 Mbps, constant and completely independent of the video preset. At
    /// 360p30 that was 65% of everything we sent. Because sendTCP counts every byte but only
    /// video consulted the counter, 0.56s of PCM was enough to pin inFlightBytes above the
    /// video threshold permanently: every delta frame was dropped for the rest of the session
    /// while forced IDRs kept flowing — the 2 fps keyframe slideshow.
    ///
    /// Clients that advertise AAC-LC now get ~128 kbps instead, so audio is a few percent of
    /// the link rather than the majority of it. That also means this ceiling is ~17 s of AAC
    /// rather than 0.8 s of PCM, i.e. AAC sessions effectively never shed audio — which is
    /// correct at that share of the link. Legacy PCM sessions keep the old behaviour.
    ///
    /// BEAM-24: that reasoning was only ever true against an AUDIO-ONLY counter, and this
    /// ceiling used to be checked against the SHARED one, which is ~97% video bytes. Video's
    /// own drop gate is a control loop whose set point is `maxQueuedMediaBytes` (192 KB), so on
    /// any link that cannot absorb the encoder instantly the shared counter parks at ~192 KB —
    /// three times this ceiling. Audio was then dropped on every single call, indefinitely,
    /// while video kept flowing: total silence with perfect video, recovered only by a
    /// reconnect. This is now compared against `inFlightAudioBytes` only.
    private var maxQueuedAudioBytes: Int {
        negotiatedAudioCodec == .aacLC ? 64 * 1024 : 288 * 1024
    }
    private var droppedAudioChunks = 0
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastPongReceivedAt = Date()
    /// Heartbeat grace before the host kills a session.
    ///
    /// Was 12s, which killed healthy sessions every 30-60s on a congested remote link:
    /// heartbeats and pongs travel on the SAME TCP connection as media, so when a backlog
    /// forms the pong queues behind video frames (head-of-line blocking) and arrives late
    /// even though the client is alive and streaming. The host then disconnected, the client
    /// reconnected, and the cycle repeated — which is what the diagnostic logs show.
    ///
    /// 30s is still well inside the client's own stall detection (8s foreground / 22s PiP),
    /// so genuinely dead connections are still caught quickly, just by the side that can tell
    /// the difference between "silent" and "slow".
    private let heartbeatTimeout: TimeInterval = 30

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
        VirtualGamepad.shared.teardown()
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
        // Binary packets (controller input) carry a BeamPacketHeader; JSON messages
        // never start with the "BEAM" magic, so this check is unambiguous and cheap.
        if let header = BeamPacketHeader.parse(from: data), header.type == .input {
            guard isAuthenticated,
                  let state = BeamControllerState.parse(from: data.dropFirst(BeamPacketHeader.size)) else { return }
            VirtualGamepad.shared.handle(state, connected: header.flags & BeamControllerState.connectedFlag != 0)
            return
        }
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

        // Audio codec negotiation (BEAM-22). Absence of the field means a client that predates
        // negotiation and can only decode Float32 PCM — feeding it AAC bytes would be
        // full-scale white noise, so absence is never treated optimistically. An empty array
        // means exactly the same thing as ["pcm_f32le"], never "anything goes".
        // Honour the client's requested audio rate so it never has to renegotiate mid-session
        // (BEAM-29). Clamped to rates ScreenCaptureKit will actually produce; anything else
        // falls back to the existing behaviour of the host choosing.
        if let requested = message.preferredAudioSampleRate,
           [44_100.0, 48_000.0].contains(requested) {
            server?.setPreferredAudioSampleRate(requested)
            logger.info("Client requested audio sample rate \(Int(requested))Hz")
        }

        let advertised = message.supportedAudioCodecs ?? []
        let forcePCM = UserDefaults.standard.bool(forKey: BeamAudioCodec.forcePCMDefaultsKey)
        negotiatedAudioCodec = (!forcePCM && advertised.contains(BeamAudioCodec.aacLC.wireName))
            ? .aacLC : .pcmFloat32

        // Success
        isAuthenticated = true
        sharedSecret = SymmetricKey(data: device.sharedSecret)
        authenticatedDeviceID = deviceID

        // Re-advertise our tailnet address on every auth, not just at pairing: this is how the
        // phone's stored remote address self-heals if our Tailscale IP ever changes (BEAM-19).
        sendPairingResponse(BeamPairingMessage(
            type: .authSuccess, deviceName: Host.current().localizedName,
            deviceID: nil, code: nil, sharedSecret: nil, error: nil,
            tailscaleHosts: TailscaleAddress.advertisedHosts(),
            supportsRemoteAccess: true,
            selectedAudioCodec: negotiatedAudioCodec.wireName
        ))

        server?.sessionAuthenticated(self, deviceName: device.name)
        logger.info("Session authenticated for device '\(device.name)' — audio codec \(self.negotiatedAudioCodec.wireName)")
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
        case .videoPause:
            videoPaused = true
            // Drop anything already queued: it is stale by the time video resumes, and holding
            // it defeats the point of quieting the link.
            backlogLock.lock(); pendingVideo.removeAll(); backlogLock.unlock()
            logger.info("Video paused by client (connection warmup)")
        case .videoResume:
            videoPaused = false
            logger.info("Video resumed by client")
        case .ping:
            // Must be wrapped in a BeamPacketHeader like every other control message. This
            // previously sent bare JSON, which the client discards outright: its receive loop
            // parses a packet header first and drops anything whose magic doesn't match. The
            // pong therefore never arrived, so the client's RTT probe never completed and its
            // link-quality badge sat on "Connecting…" forever.
            let pong = BeamControlMessage(type: .pong, payload: nil)
            if let data = try? JSONEncoder().encode(pong) {
                let header = BeamPacketHeader(type: .control, flags: 0, payloadLength: UInt32(data.count))
                var packet = header.serialized()
                packet.append(data)
                sendTCP(packet.lengthPrefixed())
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
                server?.handleViewportLockRequest(payload)
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
        guard isAuthenticated, !videoPaused else { return }

        // Drop rather than queue when the link is already behind. Keyframes are exempt:
        // dropping one strands the decoder until the next IDR, which is a far worse artefact
        // than a skipped delta frame.
        // Video yields to the TOTAL backlog (it is the bulk of it, and it is what must give way
        // so audio and control keep flowing).
        if !isKeyframe, currentBacklog().total > maxQueuedMediaBytes {
            droppedFrames += 1
            let now = Date()
            if now.timeIntervalSince(lastDropLogAt) >= 5 {
                lastDropLogAt = now
                logger.info("Dropping video to keep latency bounded (\(self.droppedFrames) frames, backlog \(self.currentBacklog().total / 1024)KB)")
            }
            return
        }

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

    func send(audioData: Data, codec: BeamAudioCodec, pts: CMTime) {
        // Belt and braces: StreamServer already fans each representation out only to the
        // sessions that negotiated it, but a fan-out bug must never be able to put AAC bytes
        // on a legacy wire — that is white noise into someone's headphones, not a glitch.
        guard isAuthenticated, codec == negotiatedAudioCodec else { return }

        // Audio must be able to shed load too, or it starves video off the link entirely.
        // Its ceiling is deliberately higher than video's: dropped audio splices rather than
        // gapping (the receiver reorders by sequence but never inserts silence), so it should
        // only ever give way when the link is genuinely unable to carry it.
        //
        // Gated on the AUDIO backlog only (BEAM-24). At 128 kbps AAC, 64 KB is ~4 s of audio,
        // so this only ever fires on a link that genuinely cannot carry 128 kbps at all.
        let backlog = currentBacklog()
        let now = Date()
        if backlog.audio > maxQueuedAudioBytes {
            // Hard liveness guarantee: audio may be shed, but never for longer than
            // `maxAudioDropWindow`. Admitting ~128 kbps onto a saturated link cannot recreate
            // the BEAM-21 latency blowup (that was 2.82 Mbps of PCM), and it makes "audio dead
            // for the rest of the session" structurally impossible on the host side.
            if now.timeIntervalSince(lastAudioSentAt) <= maxAudioDropWindow {
                droppedAudioChunks += 1
                if now.timeIntervalSince(lastDropLogAt) >= 5 {
                    lastDropLogAt = now
                    logger.info("Dropping audio, link saturated (\(self.droppedAudioChunks) chunks, audio backlog \(backlog.audio / 1024)KB, total \(backlog.total / 1024)KB)")
                }
                return
            }
            logger.warning("Audio backlog \(backlog.audio / 1024)KB over ceiling but silent for >\(self.maxAudioDropWindow)s — sending anyway to guarantee liveness")
        }
        lastAudioSentAt = now

        let seqNum = audioSequenceNumber
        audioSequenceNumber &+= 1

        let audioHeader = BeamAudioPayloadHeader(
            sequenceNumber: seqNum,
            presentationTimestamp: pts.microseconds
        )
        var payload = audioHeader.serialized()
        payload.append(audioData)
        // Audio has no fragmentation path and none is being added; an over-cap payload would
        // be silently truncated/mis-framed at the receiver, so drop it instead.
        guard payload.count <= kMaxUDPPayload else {
            logger.error("Dropping oversized audio payload (\(payload.count) B > \(kMaxUDPPayload))")
            return
        }
        sendUDP(type: .audio, flags: codec.packetFlags, payload: payload)
    }

    // MARK: - Network Send Helpers

    /// Thread-safe snapshot of the send backlog.
    private func currentBacklog() -> (total: Int, audio: Int) {
        backlogLock.lock(); defer { backlogLock.unlock() }
        return (inFlightBytes, inFlightAudioBytes)
    }

    // MARK: - Priority send queue (BEAM-31)
    //
    // Everything shares one TCP connection, so ORDER IS LATENCY: a packet written after a
    // 100KB keyframe waits for all of it to drain. On a LAN that is microseconds. On a
    // constrained tailnet it is seconds, and audio inherits that delay.
    //
    // That is one half of why audio ran ~2s behind video remotely (the other half being that
    // video sheds frames under congestion while audio does not, so audio accumulates the
    // delay it could not deliver on time). Audio is ~96kbps against megabits of video, so
    // letting it jump the queue costs video almost nothing and stops the offset forming
    // rather than absorbing it after the fact.
    //
    // Writes are serialised through this queue so ordering is ours to decide, not a race
    // between call sites.
    /// While true the host holds video and keeps audio flowing (BEAM-33).
    ///
    /// Used during connection warmup: Tailscale always starts DERP-relayed and upgrades to a
    /// direct path using small discovery packets. Flooding the relay with video starves those
    /// packets, so the upgrade never completes and we stay on the slow path we created.
    /// Audio is ~96kbps and leaves the relay effectively idle, so it can flow throughout
    /// without preventing the upgrade.
    private var videoPaused = false

    private var pendingAudio: [Data] = []
    private var pendingVideo: [Data] = []
    /// Number of writes handed to the transport but not yet acknowledged.
    ///
    /// This was a single boolean, which made the send path stop-and-wait: one outstanding
    /// write at a time, each waiting for .contentProcessed before the next. A 1080p60 frame
    /// fragments into dozens of writes, so throughput collapsed and even a LAN backed up —
    /// Kevin's log went from clean to -10s drift on local. Allowing a window restores
    /// pipelining while still draining audio first, which was the actual goal.
    private var writesInFlight = 0
    private let maxConcurrentWrites = 8

    private func enqueueSend(_ data: Data, isAudio: Bool) {
        backlogLock.lock()
        if isAudio { pendingAudio.append(data) } else { pendingVideo.append(data) }
        backlogLock.unlock()
        drainSendQueue()
    }

    /// Writes one buffer at a time, audio first, so a queued keyframe can never delay audio.
    private func drainSendQueue() {
        while true {
            backlogLock.lock()
            guard writesInFlight < maxConcurrentWrites else { backlogLock.unlock(); return }
            // Audio first, always: that is the whole point of the queue.
            let isAudio = !pendingAudio.isEmpty
            guard let next = isAudio ? pendingAudio.first : pendingVideo.first else {
                backlogLock.unlock(); return
            }
            if isAudio { pendingAudio.removeFirst() } else { pendingVideo.removeFirst() }
            writesInFlight += 1
            backlogLock.unlock()

            sendTCP(next, isAudio: isAudio) { [weak self] in
                guard let self else { return }
                self.backlogLock.lock()
                self.writesInFlight -= 1
                self.backlogLock.unlock()
                self.drainSendQueue()
            }
        }
    }

    private func sendTCP(_ data: Data, isAudio: Bool = false, onComplete: (() -> Void)? = nil) {
        let byteCount = data.count
        backlogLock.lock()
        inFlightBytes += byteCount
        if isAudio { inFlightAudioBytes += byteCount }
        outstandingSends += 1
        backlogLock.unlock()

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.backlogLock.lock()
            self.inFlightBytes -= byteCount
            if isAudio { self.inFlightAudioBytes -= byteCount }
            self.outstandingSends -= 1
            // Re-anchor whenever the connection has fully drained. Any drift accumulated by a
            // torn read-modify-write (or a completion that never fired) is erased here, so the
            // counters can never latch above a drop threshold and silence a stream forever.
            defer { onComplete?() }
            if self.outstandingSends <= 0 {
                self.outstandingSends = 0
                self.inFlightBytes = 0
                self.inFlightAudioBytes = 0
            }
            self.backlogLock.unlock()

            if let error {
                logger.error("TCP send error: \(error)")
                self.disconnect()
            }
        })
    }

    private func sendUDP(type: BeamPacketType, flags: UInt8, payload: Data) {
        let header = BeamPacketHeader(type: type, flags: flags, payloadLength: UInt32(payload.count))
        var packet = header.serialized()
        packet.append(payload)

        // Media goes through the priority queue so audio is never stuck behind a keyframe.
        // Control messages keep writing directly: they are tiny, latency-critical in their own
        // right (heartbeats, auth), and must not be reordered behind queued media.
        enqueueSend(packet.lengthPrefixed(), isAudio: type == .audio)
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
