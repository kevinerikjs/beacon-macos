// StreamSession.swift
// Represents one connected Beam client (iPhone).
// Handles the pairing/authentication handshake over TCP, then sends video/audio data.
//
// The transport is PhorosNetwork.PhorosConnection. Authentication, send scheduling,
// video hold and heartbeat policy come from PhorosSession. Controller input is replayed
// by PhorosInput.VirtualGamepad. What stays here is Beacon glue: KeyStore lookup, the
// force-PCM escape hatch, the preferred audio sample rate, and forwarding to StreamServer.

import CoreMedia
import Foundation
import Network
import OSLog
import Phoros
import PhorosInput
import PhorosNetwork
import PhorosSession

private let logger = Logger(subsystem: "com.beam.beacon", category: "StreamSession")

/// Largest media payload we put in one packet. Under a typical 1500-byte MTU.
private let kMaxMediaPayload = 1400

final class StreamSession {

    let id: String = UUID().uuidString

    private let link: PhorosConnection
    private weak var server: StreamServer?

    private var isAuthenticated = false

    /// Codec this session's client can actually decode. Defaults to .pcmFloat32 and is only
    /// ever raised by an explicit advertisement in this connection's authRequest. It is a
    /// per-connection property: never derived from a prior connection, a stored capability,
    /// or the paired-device record.
    private(set) var negotiatedAudioCodec: AudioCodecID = .pcmFloat32
    /// The video codec this client can decode, resolved at auth. HEVC only if the client
    /// advertised it, else H.264. The shared encoder aggregates this across all sessions
    /// (see StreamServer.desiredVideoCodec), so it is a capability, not a guarantee.
    private(set) var negotiatedVideoCodec: VideoCodecID = .h264
    /// Whether this client wants audio at all (BEAM-34). Set from `wantsAudio` at auth and
    /// flipped by `audio_enable_request` mid-session. Per-connection, like the codecs.
    private(set) var wantsAudio = true

    private(set) var authenticatedDeviceID: String?
    private var isTerminated = false

    private var videoFrameNumber: UInt32 = 0
    private var audioSequenceNumber: UInt32 = 0

    // MARK: - Send scheduling
    //
    // Everything travels over the one TCP connection. On a constrained link TCP never drops,
    // so once the encoder outpaces the link every frame queues and latency grows without
    // bound (BEAM-21). SendScheduler drops late video, keeps audio ahead of video (BEAM-31),
    // sheds audio only on its own backlog and never for long (BEAM-24), and re-anchors its
    // counters whenever the connection drains so an accounting slip can never silence a
    // stream. All access is serialised on `stateQueue`.
    private var scheduler = SendScheduler()
    private var hold = VideoHold()
    private var heartbeat = HeartbeatMonitor()
    /// One virtual pad per session. Beacon streams to one client at a time.
    private let gamepad = VirtualGamepad(profile: GamepadProfile.selected)
    private var heartbeatTimer: DispatchSourceTimer?
    private var probeTimer: DispatchSourceTimer?
    private var probe = RoundTripProbe(staleAfter: 1)
    private var bitrate = BitrateController(maximum: 6_000_000)
    private var lastDropLogAt = Date.distantPast

    private let stateQueue = DispatchQueue(label: "com.beam.session.state", qos: .userInteractive)

    init(connection: NWConnection, server: StreamServer) {
        link = PhorosConnection(accepting: connection, queue: stateQueue)
        self.server = server
    }

    // MARK: - Lifecycle

    func start() {
        link.onReady = { [weak self] in
            guard let self else { return }
            logger.info("Session TCP connection ready from \(String(describing: self.link.connection.endpoint))")
        }
        link.onFrame = { [weak self] frame in self?.handleFrame(frame) }
        gamepad.onEvent = { [id] event in
            switch event {
            case .created: logger.info("Session \(id) virtual gamepad created as \(GamepadProfile.selected.rawValue, privacy: .public)")
            case .released: logger.info("Session \(id) virtual gamepad removed")
            case .creationFailed:
                logger.error("Session \(id) failed to create the virtual gamepad: the com.apple.developer.hid.virtual.device entitlement is missing from this build. Controller input will be dropped.")
            case .reportRejected(let status):
                logger.warning("Session \(id) HID report rejected: \(String(format: "0x%08X", status))")
            }
        }
        link.onEnd = { [weak self] reason in
            guard let self else { return }
            switch reason {
            case .transportFailed(let error): logger.error("Session TCP failed: \(error)")
            case .protocolViolation(let violation): logger.error("Session \(self.id) protocol violation: \(String(describing: violation))")
            case .closedByPeer: logger.info("Session \(self.id) peer closed connection")
            case .cancelled: break
            }
            self.server?.sessionDisconnected(self)
        }
        link.start()
    }

    func disconnect() {
        guard !isTerminated else { return }
        isTerminated = true
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        probeTimer?.cancel()
        probeTimer = nil
        gamepad.release()
        link.cancel()
        logger.info("Session \(self.id) disconnected")
    }

    // MARK: - Inbound

    private func handleFrame(_ frame: Frame) {
        heartbeat.heard()
        switch frame {
        case .packet(let packet) where packet.type == .input:
            // Binary, routed by packet type before any JSON decode: at 60 Hz a fall-through
            // to the JSON path would flood the log. Ignored until the client authenticates.
            guard isAuthenticated, ControllerPassthrough.isEnabled,
                  let report = ControllerReport.parse(from: packet.payload) else { return }
            if Harness.isEnabled { Harness.inputReceived(report) }
            gamepad.handle(report, connected: packet.flags & ControllerReport.connectedFlag != 0)
            if Harness.isEnabled { Harness.inputPosted() }
        case .packet(let packet):
            handleJSONMessage(packet.payload)
        case .message(let json):
            handleJSONMessage(json)
        }
    }

    private func handleJSONMessage(_ data: Data) {
        if let message = try? JSONDecoder().decode(PairingMessage.self, from: data) {
            handlePairingMessage(message)
            return
        }
        do {
            handleControlMessage(try JSONDecoder().decode(ControlMessage.self, from: data))
        } catch ControlMessageError.unknownType(let name) {
            // A newer client. Ignoring is the contract; see Phoros docs/compatibility.md.
            logger.info("Ignoring unknown control message '\(name)' from a newer client")
        } catch {
            logger.error("Failed to decode incoming message: \(error)")
        }
    }

    // MARK: - Authentication

    private func handlePairingMessage(_ message: PairingMessage) {
        switch message.type {
        case .authRequest:
            handleAuthRequest(message)
        case .hello:
            guard let deviceID = message.deviceID, let deviceName = message.deviceName else { return }
            PairingManager.shared.beginPairing(deviceID: deviceID, deviceName: deviceName, session: self)
        case .codeVerify:
            if let code = message.code {
                PairingManager.shared.verifyCode(code)
            }
        default:
            logger.warning("Unexpected pairing message type: \(message.type.rawValue)")
        }
    }

    private func handleAuthRequest(_ message: PairingMessage) {
        // Honour the client's requested audio rate so it never has to renegotiate mid-session
        // (BEAM-29). Clamped to rates ScreenCaptureKit will actually produce; anything else
        // falls back to the existing behaviour of the host choosing.
        if let requested = message.preferredAudioSampleRate, [44_100.0, 48_000.0].contains(requested) {
            server?.setPreferredAudioSampleRate(requested)
            logger.info("Client requested audio sample rate \(Int(requested))Hz")
        }

        // The force-PCM default is Beacon's escape hatch for a bad AAC release.
        let forcePCM = UserDefaults.standard.bool(forKey: AudioCodecID.forcePCMDefaultsKey)
        let pairedDevices = KeyStore.shared.loadPairedDevices()
        let outcome = HostAuthenticator.authenticate(
            message,
            storedSecret: { deviceID in
                if Harness.isEnabled, deviceID == Harness.deviceID { return SharedSecret(hex: Harness.secretHex) }
                return pairedDevices.first { $0.id == deviceID }.flatMap { SharedSecret(bytes: $0.sharedSecret) }
            },
            // Re-advertise our tailnet address on every auth, not just at pairing: this is
            // how the phone's stored remote address self-heals if our Tailscale IP ever
            // changes (BEAM-19).
            capabilities: Self.hostCapabilities(),
            audioPreferences: forcePCM ? [.pcmFloat32] : [.aacLC, .pcmFloat32]
        )

        switch outcome {
        case .rejected(let reply):
            sendPairingResponse(reply)
        case .authenticated(let session):
            negotiatedAudioCodec = session.audioCodec
            negotiatedVideoCodec = session.videoCodec
            wantsAudio = session.peer.wantsAudio
            scheduler.policy = Harness.sendPolicy(base: session.audioCodec == .pcmFloat32 ? .pcmAudio : SendPolicy())
            isAuthenticated = true
            authenticatedDeviceID = session.deviceID
            sendPairingResponse(session.reply)

            let deviceName = pairedDevices.first { $0.id == session.deviceID }?.name ?? session.deviceID
            server?.sessionAuthenticated(self, deviceName: deviceName)
            logger.info("Session authenticated for device '\(deviceName)' — audio \(self.wantsAudio ? self.negotiatedAudioCodec.wireName : "off"), video \(self.negotiatedVideoCodec.wireName)")
        }
    }

    /// Everything this Beacon advertises about itself. Shared with PairingManager so
    /// pair_success and auth_success never disagree.
    static func hostCapabilities() -> HostCapabilities {
        HostCapabilities(
            deviceName: Host.current().localizedName,
            remoteHosts: TailscaleAddress.advertisedHosts() ?? [],
            supportsRemoteAccess: true,
            supportsVideoHold: true,
            supportsAudioToggle: true,
            supportsWindowSelection: true,
            controls: PhoneControlsStore.shared.wireControls(),
            supportsControllerInput: ControllerPassthrough.isEnabled
        )
    }

    /// Host-to-client handshake messages always travel inside a .control packet so the
    /// phone's receive loop, which parses a packet header first, dispatches them correctly.
    func sendPairingResponse(_ message: PairingMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        enqueue(Packet.encode(.control, payload: data), lane: .control)
    }

    // MARK: - Control Messages

    private func handleControlMessage(_ message: ControlMessage) {
        guard isAuthenticated else { return }

        switch message {
        case .mediaKey(let command):
            if Harness.isEnabled, let id = command.controlID.flatMap({ $0.hasPrefix("harness.press.") ? Int($0.dropFirst("harness.press.".count)) : nil }) {
                Harness.press(id: id)
                return
            }
            MediaKeyDispatcher.send(command)
        case .pong:
            // heartbeat.heard() already ran for this frame. The round trip of this pong is
            // the link's queueing delay: the ping waited behind every queued video byte.
            if let rtt = probe.receivedPong() {
                bitrate.observe(roundTrip: rtt)
                if Harness.isEnabled { Harness.log("RTT", Int(rtt * 1_000_000), extra: "\(Int(bitrate.queueDelay * 1_000_000)),\(bitrate.current)") }
                if let next = bitrate.evaluate() {
                    logger.info("Link queue \(Int(self.bitrate.queueDelay * 1000)) ms, bitrate → \(next / 1000) kbps")
                    wantedBitrate = next
                    server?.session(self, wantsBitrate: next)
                }
            }
        case .ping:
            sendControl(.pong)
        case .videoPause:
            // Connection warm-up (BEAM-33): hold video so Tailscale's path discovery can
            // finish, keep audio flowing. Queued video is stale by the time it resumes.
            hold.pause()
            scheduler.dropQueuedVideo()
            logger.info("Video paused by client (connection warmup)")
        case .videoResume:
            // Releasing the hold is not enough on its own (BEAM-21): the encoder dropped
            // everything during the hold, including the IDR, and considers its parameter
            // sets sent. VideoHold spells out the repair; StreamServer performs both steps.
            _ = hold.resume()
            logger.info("Video resumed by client")
            server?.clientReleasedVideoHold(self)
        case .streamStop:
            logger.info("Client requested stream stop")
            disconnect()
        case .qualityFeedback(let quality):
            server?.handleQualityFeedback(quality)
        case .qualityRequest(let preset):
            server?.handleQualityRequest(preset)
        case .viewportLockRequest(let lock):
            server?.handleViewportLockRequest(lock)
        case .windowListRequest:
            server?.handleWindowListRequest(from: self)
        case .windowSelectRequest(let windowID):
            server?.handleWindowSelectRequest(windowID: windowID)
        case .audioEnableRequest(let enabled):
            guard enabled != wantsAudio else { return }
            wantsAudio = enabled
            logger.info("Audio \(enabled ? "enabled" : "disabled") by client")
            server?.sessionAudioPreferenceChanged(self)
        case .streamRequest, .qualityChanged, .audioFormatChanged, .windowList, .captureModeChanged:
            break  // host-to-client, or not acted on by this host
        }
    }

    func sendQualityChanged(_ preset: QualityPreset) {
        sendControl(.qualityChanged(preset))
    }

    /// Reply to a window_list_request (BEAM-35). Authenticated sessions only — the guard in
    /// handleControlMessage already enforces that, and this is only ever called from there.
    func sendWindowList(_ windows: [WindowInfo]) {
        sendControl(.windowList(windows))
    }

    func sendCaptureMode(_ mode: CaptureMode) {
        guard isAuthenticated else { return }
        sendControl(.captureModeChanged(mode))
    }

    func sendAudioFormatChanged(sampleRate: Double, channels: Int) {
        sendControl(.audioFormatChanged(AudioFormat(sampleRate: sampleRate, channels: channels)))
    }

    func sendUnpaired() {
        sendPairingResponse(PairingMessage(type: .unpaired))
    }

    private func sendControl(_ message: ControlMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        enqueue(Packet.encode(.control, payload: data), lane: .control)
    }

    // MARK: - Streaming

    func beginReceivingStream(videoEncoder: HostVideoEncoder, audioEncoder: HostAudioEncoder) {
        logger.info("Session \(self.id) ready for streaming")
        startHeartbeat()
        startLinkProbe()
    }

    /// The bitrate this session's link can carry right now, as the controller sees it.
    /// Mirrored out of `stateQueue` so the server can read it from any queue without
    /// blocking on the session (the controller reports from `stateQueue` itself).
    private(set) var wantedBitrate: Int {
        get { wantedBitrateLock.withLock { _wantedBitrate } }
        set { wantedBitrateLock.withLock { _wantedBitrate = newValue } }
    }
    private var _wantedBitrate = Int.max
    private let wantedBitrateLock = NSLock()

    /// A new preset: the controller's ceiling follows it.
    func setMaximumBitrate(_ bitsPerSecond: Int) {
        stateQueue.async { [self] in
            bitrate.setMaximum(bitsPerSecond)
            wantedBitrate = bitrate.current
        }
    }

    /// Whether the transport has room for another encoded frame. Read from the capture
    /// thread before the encode, so a frame the link cannot take is skipped for free.
    var acceptsVideoFrame: Bool { stateQueue.sync { !isAuthenticated || hold.isHeld || scheduler.shouldEncodeVideo() } }

    /// Pings the client five times a second while streaming. The reply's round trip feeds
    /// the bitrate controller; the client already answers pings for its own probe.
    private func startLinkProbe() {
        guard Harness.experiment["noabr"] == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, self.isAuthenticated, !self.hold.isHeld, self.probe.shouldSend() else { return }
            self.sendControl(.ping)
        }
        timer.resume()
        probeTimer = timer
    }

    private func startHeartbeat() {
        heartbeat = HeartbeatMonitor()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.isAuthenticated else { return }
            if self.heartbeat.isTimedOut() {
                logger.warning("Heartbeat timeout for session \(self.id) (\(Int(Date().timeIntervalSince(self.heartbeat.lastHeard)))s without traffic)")
                self.disconnect()
                return
            }
            self.enqueueLocked(Packet.encode(.heartbeat), lane: .control)
        }
        timer.resume()
        heartbeatTimer = timer
    }

    // MARK: - Send Video

    func send(spsPps data: Data, codec: VideoCodecID) {
        guard isAuthenticated else { return }
        enqueue(Packet.encode(.parameterSets, flags: codec.packetFlags, payload: data), lane: .video)
    }

    func send(videoData: Data, pts: CMTime, isKeyframe: Bool) {
        stateQueue.async { [self] in
            guard isAuthenticated, !hold.isHeld else { return }
            guard scheduler.admitVideo(isKeyframe: isKeyframe) else {
                logDropIfDue("Dropping video to keep latency bounded (\(scheduler.droppedVideoFrames) frames, backlog \(scheduler.backlog.total / 1024)KB)")
                return
            }
            let frameNumber = videoFrameNumber
            videoFrameNumber &+= 1
            // One write per frame: the packets stay identical on the wire, the transport just
            // gets them together instead of forty separate sends.
            let packets = VideoFragmentHeader.fragment(
                videoData, frameNumber: frameNumber, presentationTimestamp: pts.microseconds, maximumPayloadLength: kMaxMediaPayload
            ).map { Packet.encode(isKeyframe ? .videoKeyframe : .video, payload: $0).lengthPrefixed() }
            scheduler.enqueueVideoFrame(packets, isKeyframe: isKeyframe)
            drain()
            if Harness.isEnabled { Harness.log("H6", Int(frameNumber), extra: "\(pts.microseconds),\(videoData.count)") }
        }
    }

    // MARK: - Send Audio

    func send(audioData: Data, codec: AudioCodecID, pts: CMTime) {
        stateQueue.async { [self] in
            // Belt and braces: StreamServer already fans each representation out only to the
            // sessions that negotiated it, but a fan-out bug must never be able to put AAC
            // bytes on a legacy wire — that is white noise into someone's headphones.
            guard isAuthenticated, wantsAudio, codec == negotiatedAudioCodec else { return }
            guard scheduler.admitAudio() else {
                logDropIfDue("Dropping audio, link saturated (\(scheduler.droppedAudioChunks) chunks, audio backlog \(scheduler.backlog.audio / 1024)KB)")
                return
            }
            let sequence = audioSequenceNumber
            audioSequenceNumber &+= 1
            var payload = AudioChunkHeader(sequenceNumber: sequence, presentationTimestamp: pts.microseconds).serialized()
            payload.append(audioData)
            // Audio has no fragmentation path; an over-cap payload would be mis-framed at the
            // receiver, so drop it instead.
            guard payload.count <= kMaxMediaPayload else {
                logger.error("Dropping oversized audio payload (\(payload.count) B > \(kMaxMediaPayload))")
                return
            }
            enqueueLocked(Packet.encode(.audio, flags: codec.packetFlags, payload: payload), lane: .audio)
        }
    }

    // MARK: - Scheduler plumbing

    private func enqueue(_ packet: Data, lane: SendLane) {
        stateQueue.async { [self] in enqueueLocked(packet, lane: lane) }
    }

    /// stateQueue only.
    private func enqueueLocked(_ packet: Data, lane: SendLane) {
        scheduler.enqueue(packet.lengthPrefixed(), lane: lane)
        drain()
    }

    /// stateQueue only. Hands writes to the transport, control first, then audio, then video.
    private func drain() {
        defer {
            // A shed or refused delta frame leaves the decoder with a broken reference chain
            // until the next keyframe. Ask for one now instead of waiting up to two seconds.
            if scheduler.needsKeyframe { server?.requestKeyframeForRecovery() }
        }
        while let write = scheduler.dequeue() {
            link.connection.send(content: write.data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.stateQueue.async {
                    self.scheduler.completed(write)
                    if let error {
                        logger.error("TCP send error: \(error)")
                        self.disconnect()
                        return
                    }
                    self.drain()
                }
            })
        }
    }

    private func logDropIfDue(_ message: String) {
        let now = Date()
        guard now.timeIntervalSince(lastDropLogAt) >= 5 else { return }
        lastDropLogAt = now
        logger.info("\(message)")
    }
}
