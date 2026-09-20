// StreamSession.swift
// Represents one connected Beam client (iPhone).
// Handles the pairing/authentication handshake over TCP, then sends video/audio data.
//
// The transport is PhorosNetwork.PhorosLegacyTransport behind the PhorosRealtimeTransport
// seam: framing, fragmentation, scheduling, shedding, the link probe and bitrate control,
// heartbeats and the radio keep-awake all live there. Authentication, video hold and the
// heartbeat timeout come from PhorosSession. Controller input is replayed by
// PhorosInput.VirtualGamepad. What stays here is Beacon glue: KeyStore lookup, the
// force-PCM escape hatch, the preferred audio sample rate, and forwarding to StreamServer.

import CoreMedia
import Foundation
import Network
import OSLog
import Phoros
import PhorosInput
import PhorosNetwork
import PhorosSession
import PhorosCore

private let logger = Logger(subsystem: "com.beam.beacon", category: "StreamSession")

final class StreamSession {

    let id: String = UUID().uuidString

    private let transport: PhorosLegacyTransport
    private weak var server: StreamServer?

    /// Experimental second transport (BEACON_EXP=rtc, BEAM-54): ICE, DTLS and SCTP over
    /// UDP through PhorosCore. Offered after authentication; once it connects, media and
    /// input move to it and control stays on TCP.
    private var rtcPeer: RealtimePeer?
    private var rtcTransport: PhorosPeerTransport?
    private var rtcReady = false
    private var rtcEverReady = false

    private(set) var isAuthenticated = false

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
    /// The client's `maximumFrameRate`, or nil for the preset's own rate.
    private(set) var maximumFrameRate: Double?

    private(set) var authenticatedDeviceID: String?
    private var isTerminated = false

    private var hold = VideoHold()
    private var heartbeat = HeartbeatMonitor()
    /// One virtual pad per session. Beacon streams to one client at a time.
    private let gamepad = VirtualGamepad(profile: GamepadProfile.selected)
    private var heartbeatTimer: DispatchSourceTimer?

    private let stateQueue = DispatchQueue(label: "com.beam.session.state", qos: .userInteractive)

    init(connection: NWConnection, server: StreamServer) {
        transport = PhorosLegacyTransport(
            accepting: connection,
            options: LegacyTransportOptions(role: .host, keepAwakeInterval: Harness.experiment["nokeep"] == nil ? 0.02 : 0,
                                            readsLinkBacklog: Harness.experiment["nokq"] == nil),
            queue: stateQueue
        )
        self.server = server
    }

    // MARK: - Lifecycle

    func start() {
        transport.onReady = { [weak self] in
            guard let self else { return }
            logger.info("Session TCP connection ready from \(String(describing: self.transport.link.connection.endpoint))")
        }
        transport.onInbound = { [weak self] inbound in self?.handleInbound(inbound, via: "tcp") }
        transport.onKeyframeNeeded = { [weak self] in
            // A shed or refused delta frame leaves the decoder with a broken reference chain
            // until the next keyframe. Ask for one now instead of waiting for the periodic one.
            self?.server?.requestKeyframeForRecovery()
        }
        transport.onBitrateChange = { [weak self] bitrate in
            guard let self else { return }
            logger.info("Link queue \(Int(self.transport.metrics.queueDelay * 1000)) ms, bitrate → \(bitrate / 1000) kbps")
            self.wantedBitrate = bitrate
            self.server?.session(self, wantsBitrate: bitrate)
        }
        if Harness.isEnabled {
            transport.onTrace = { trace in
                switch trace {
                case .videoQueued(let frame, let pts, let bytes): Harness.log("H6", Int(frame), extra: "\(pts),\(bytes)")
                case .videoHandedToLink(let frame, let backlog): Harness.log("H6D", Int(frame), extra: "\(backlog)")
                case .videoAcceptedByLink(let frame): Harness.log("H6C", Int(frame))
                case .probe(let rtt, let queueDelay, let bitrate, let counted):
                    if counted { Harness.log("RTT", Int(rtt * 1_000_000), extra: "\(Int(queueDelay * 1_000_000)),\(bitrate)") }
                    else { Harness.log("RTTK", Int(rtt * 1_000_000)) }
                case .linkSample(let backlog, let queued, let drainRate, let budget):
                    Harness.log("SNDBUF", backlog, extra: "0,\(queued),\(Int(drainRate)),\(budget)")
                }
            }
        }
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
        transport.onEnd = { [weak self] reason in
            guard let self else { return }
            switch reason as? PhorosConnectionEnd {
            case .transportFailed(let error): logger.error("Session TCP failed: \(error)")
            case .protocolViolation(let violation): logger.error("Session \(self.id) protocol violation: \(String(describing: violation))")
            case .closedByPeer: logger.info("Session \(self.id) peer closed connection")
            case .cancelled, .none: break
            }
            self.server?.sessionDisconnected(self)
        }
        transport.start()
    }

    func disconnect() {
        guard !isTerminated else { return }
        isTerminated = true
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        gamepad.release()
        rtcTransport?.cancel()
        transport.cancel()
        logger.info("Session \(self.id) disconnected")
    }

    // MARK: - Inbound

    private var lastInputSequence: UInt16?

    private func handleInbound(_ inbound: RealtimeInbound, via pipe: String = "tcp") {
        heartbeat.heard()
        switch inbound {
        case .input(let report, let connected):
            // Ignored until the client authenticates.
            guard isAuthenticated, ControllerPassthrough.isEnabled else { return }
            // A client sending on two transports numbers its reports: the first copy wins,
            // a copy that is not newer than what was applied is dropped.
            if let sequence = report.sequence {
                if let last = lastInputSequence, !ControllerReport.isNewer(sequence, than: last) {
                    if Harness.isEnabled { Harness.log("H2X", Int(sequence), extra: pipe) }   // the late copy
                    return
                }
                lastInputSequence = sequence
                if Harness.isEnabled { Harness.log("H2W", Int(sequence), extra: pipe) }   // the copy that won
            }
            if Harness.isEnabled { Harness.inputReceived(report) }
            gamepad.handle(report, connected: connected)
            if Harness.isEnabled { Harness.inputPosted() }
        case .control(let message):
            handleControlMessage(message)
        case .unknownControl(let name):
            // A newer client. Ignoring is the contract; see Phoros docs/compatibility.md.
            logger.info("Ignoring unknown control message '\(name)' from a newer client")
        case .message(let json):
            if let message = try? JSONDecoder().decode(PairingMessage.self, from: json) {
                handlePairingMessage(message)
            } else {
                logger.error("Failed to decode incoming message")
            }
        case .heartbeat, .video, .videoParameterSets, .audio:
            break  // client to host never carries media
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
            maximumFrameRate = session.peer.maximumFrameRate
            transport.setSendPolicy(Harness.sendPolicy(base: session.audioCodec == .pcmFloat32 ? .pcmAudio : SendPolicy()))
            isAuthenticated = true
            transport.setStreaming(true)
            authenticatedDeviceID = session.deviceID
            sendPairingResponse(session.reply)

            let deviceName = pairedDevices.first { $0.id == session.deviceID }?.name ?? session.deviceID
            server?.sessionAuthenticated(self, deviceName: deviceName)
            if Harness.experiment["rtc"] != nil { offerRTC() }
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
            supportsControllerInput: ControllerPassthrough.isEnabled,
            supportsClockSync: true
        )
    }

    /// Host-to-client handshake messages always travel inside a .control packet so the
    /// phone's receive loop, which parses a packet header first, dispatches them correctly.
    func sendPairingResponse(_ message: PairingMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        transport.sendMessage(data)
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
        case .pong, .ping:
            break  // the transport measures the round trip and answers pings
        case .transportOffer:
            break  // a host never receives offers
        case .transportAnswer(let answer):
            guard answer.kind == "rtc2", let peer = rtcPeer else { return }
            logger.info("rtc2 answer from \(answer.address)")
            peer.setRemote(info: answer.info, address: answer.address, nowMicros: 0)
        case .clockProbe(let probe):
            // Both host times on the clock video timestamps use, so the client can turn a
            // frame's presentation timestamp into an age.
            let received = CMClockGetTime(CMClockGetHostTimeClock()).microseconds
            sendControl(.clockReply(ClockReply(id: probe.id, sentAt: probe.sentAt, receivedAt: received,
                                               repliedAt: CMClockGetTime(CMClockGetHostTimeClock()).microseconds)))
        case .clockReply:
            break  // a host never sends probes
        case .videoPause:
            // Connection warm-up (BEAM-33): hold video so Tailscale's path discovery can
            // finish, keep audio flowing. Queued video is stale by the time it resumes.
            hold.pause()
            transport.setStreaming(false)
            transport.dropQueuedVideo()
            logger.info("Video paused by client (connection warmup)")
        case .videoResume:
            // Releasing the hold is not enough on its own (BEAM-21): the encoder dropped
            // everything during the hold, including the IDR, and considers its parameter
            // sets sent. VideoHold spells out the repair; StreamServer performs both steps.
            _ = hold.resume()
            transport.setStreaming(true)
            logger.info("Video resumed by client")
            server?.clientReleasedVideoHold(self)
        case .streamStop:
            logger.info("Client requested stream stop")
            disconnect()
        case .qualityFeedback(let quality):
            server?.handleQualityFeedback(quality)
        case .qualityRequest(let preset):
            server?.handleQualityRequest(preset)
        case .bitrateCapRequest(let bitsPerSecond):
            clientBitrateCap = bitsPerSecond.map { max(500_000, $0) }
            logger.info("Client bitrate cap: \(bitsPerSecond.map { "\($0 / 1_000_000) Mbps" } ?? "none")")
            if let presetBitrate { setMaximumBitrate(presetBitrate) }
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
        transport.sendControl(message)
    }

    // MARK: - Streaming

    func beginReceivingStream(videoEncoder: HostVideoEncoder, audioEncoder: HostAudioEncoder) {
        logger.info("Session \(self.id) ready for streaming")
        startHeartbeat()
    }

    /// The bitrate this session's link can carry right now, as the transport's controller
    /// sees it. Mirrored so the server can read it from any queue.
    private(set) var wantedBitrate: Int {
        get { wantedBitrateLock.withLock { _wantedBitrate } }
        set { wantedBitrateLock.withLock { _wantedBitrate = newValue } }
    }
    private var _wantedBitrate = Int.max
    private let wantedBitrateLock = NSLock()

    /// A new preset: the controller's ceiling follows it, and it reports where it starts.
    /// The client's own ceiling (Phoros 1.4.1 `bitrateCapRequest`), applied under the preset's.
    private var clientBitrateCap: Int?
    private var presetBitrate: Int?

    func setMaximumBitrate(_ bitsPerSecond: Int) {
        presetBitrate = bitsPerSecond
        transport.setMaximumBitrate(min(bitsPerSecond, clientBitrateCap ?? .max))
    }

    /// Whether the transport has room for another encoded frame. Read from the capture
    /// thread before the encode, so a frame the link cannot take is skipped for free.
    var acceptsVideoFrame: Bool {
        guard isAuthenticated, !hold.isHeld else { return true }
        return media.acceptsVideoFrame
    }

    /// The heartbeat timeout is Beacon's policy; the packets themselves come from the transport.
    private func startHeartbeat() {
        heartbeat = HeartbeatMonitor()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.isAuthenticated else { return }
            if self.heartbeat.isTimedOut() {
                logger.warning("Heartbeat timeout for session \(self.id) (\(Int(Date().timeIntervalSince(self.heartbeat.lastHeard)))s without traffic)")
                self.disconnect()
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    // MARK: - rtc2 (experimental)

    /// Binds a UDP peer on the interface this client reached us on and offers it.
    private func offerRTC() {
        var host = "127.0.0.1"
        if let local = transport.link.connection.currentPath?.localEndpoint, case .hostPort(let h, _) = local {
            host = "\(h)".split(separator: "%").first.map(String.init) ?? host
        }
        let address = "\(host):7981"
        guard let peer = RealtimePeer(isHost: true, localAddress: address) else { return }
        let media = PhorosPeerTransport(peer: peer, queue: stateQueue)
        media.onReady = { [weak self] in
            guard let self else { return }
            self.stateQueue.async {
                self.rtcReady = true
                self.rtcEverReady = true
                logger.info("rtc2 connected, media moves to it")
                // The decoder on the other side starts fresh: parameter sets and a keyframe.
                self.server?.requestKeyframeForRecovery()
            }
        }
        media.onInbound = { [weak self] inbound in self?.handleInbound(inbound, via: "rtc") }
        // A radio stall long enough for ICE to give up must not end the session: video goes
        // back to TCP until the link is up again, each switch starting with a keyframe.
        media.onLinkStateChange = { [weak self] up in
            guard let self else { return }
            self.stateQueue.async {
                guard self.rtcTransport != nil, self.rtcReady != up, self.rtcEverReady || up else { return }
                self.rtcReady = up
                self.rtcEverReady = true
                logger.info("rtc2 link \(up ? "up: media back on it" : "down: media falls back to TCP")")
                self.server?.requestKeyframeForRecovery()
            }
        }
        media.onKeyframeNeeded = { [weak self] in self?.server?.requestKeyframeForRecovery() }
        media.onTrace = transport.onTrace
        rtcPeer = peer
        rtcTransport = media
        // PHOROS_UDP_CLASS=0|3|4: the peer socket's service class (harness experiment)
        if let c = ProcessInfo.processInfo.environment["PHOROS_UDP_CLASS"].flatMap(Int32.init) { peer.setServiceClass(c) }
        guard peer.runOwnSocket() == 0 else { rtcPeer = nil; rtcTransport = nil; return }
        transport.sendControl(.transportOffer(TransportOffer(kind: "rtc2", address: address, info: peer.localInfo)))
        logger.info("rtc2 offered at \(address)")
    }

    // MARK: - Send Video

    func send(spsPps data: Data, codec: VideoCodecID) {
        guard isAuthenticated else { return }
        media.sendVideoParameterSets(data, codec: codec)
    }

    func send(videoData: Data, pts: CMTime, isKeyframe: Bool) {
        guard isAuthenticated, !hold.isHeld else { return }
        media.sendVideo(videoData, presentationTimestamp: pts.microseconds, isKeyframe: isKeyframe)
    }

    /// The transport carrying media right now: rtc2 once it is connected, TCP otherwise.
    private var media: PhorosRealtimeTransport {
        if rtcReady, let rtcTransport { return rtcTransport }
        return transport
    }

    // MARK: - Send Audio

    func send(audioData: Data, codec: AudioCodecID, pts: CMTime) {
        // Belt and braces: StreamServer already fans each representation out only to the
        // sessions that negotiated it, but a fan-out bug must never be able to put AAC
        // bytes on a legacy wire: that is white noise into someone's headphones.
        guard isAuthenticated, wantsAudio, codec == negotiatedAudioCodec else { return }
        media.sendAudio(audioData, codec: codec, presentationTimestamp: pts.microseconds)
    }
}
