// StreamServer.swift
// TCP listener that accepts Beam client connections and orchestrates the streaming pipeline.
// Each connected client gets its own StreamSession.

import Network
import ScreenCaptureKit
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "StreamServer")

/// Default port the stream server listens on.
let kBeamDefaultPort: UInt16 = 7979

final class StreamServer {

    private(set) var listeningPort: UInt16 = kBeamDefaultPort

    private weak var appState: AppState?
    private var listener: NWListener?
    private var activeSessions: [String: StreamSession] = [:]  // keyed by session UUID
    /// Serialises all reads/writes of activeSessions across the listener queue,
    /// session sendQueues, and encoder callbacks (which all run on different threads).
    private let sessionsQueue = DispatchQueue(label: "com.beam.server.sessions")

    /// Most-recent SPS/PPS blob, sent immediately to each newly-authenticated session.
    private var cachedSpsPps: Data? = nil

    // Pipeline components (shared across sessions; one capture, multiple outputs)
    private let screenCapture: ScreenCapture
    private let videoEncoder: VideoEncoder
    private let audioEncoder: AudioEncoder
    private let qualityManager: VideoQualityManager

    private var captureStarted = false
    private var lastVideoInputFrameAt: Date = .distantPast
    private var isRecoveringCapture = false
    private var pendingWindowSelection: SCWindow? = nil
    private var currentAudioFormat: (sampleRate: Double, channels: Int)? = nil

    /// Tracks when each device last disconnected so we can detect same-device reconnects
    /// even when the old session has already been cleaned up (e.g. heartbeat timeout).
    /// Protected by sessionsQueue.
    private var lastDisconnectedByDeviceID: [String: Date] = [:]

    init(appState: AppState, qualityManager: VideoQualityManager) {
        self.appState = appState
        self.qualityManager = qualityManager

        // Init encoder with quality manager's initial preset
        let preset = qualityManager.activePreset
        videoEncoder = VideoEncoder(
            width: Int32(preset.width),
            height: Int32(preset.height),
            frameRate: preset.fps,
            bitrateMbps: preset.bitrateMbps
        )
        audioEncoder = AudioEncoder()
        screenCapture = ScreenCapture()

        videoEncoder.delegate = self
        audioEncoder.delegate = self
        screenCapture.delegate = self

        qualityManager.onPresetChanged = { [weak self] preset in
            self?.applyQualityPreset(preset)
        }
    }

    // MARK: - Start / Stop

    func start() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true

            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: listeningPort) ?? 7979)

            // Advertise via Bonjour on the same listener — avoids the two-listener port conflict.
            let deviceName = Host.current().localizedName ?? "Beacon"
            listener?.service = NWListener.Service(name: deviceName, type: kBeamServiceType, domain: "local.")
            listener?.serviceRegistrationUpdateHandler = { change in
                switch change {
                case .add(let endpoint):
                    logger.info("Bonjour service registered: \(String(describing: endpoint))")
                case .remove(let endpoint):
                    logger.info("Bonjour service removed: \(String(describing: endpoint))")
                @unknown default:
                    break
                }
            }

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener?.port?.rawValue {
                        self?.listeningPort = port
                        logger.info("StreamServer listening on port \(port) with Bonjour advertising")
                    }
                case .failed(let error):
                    logger.error("StreamServer listener failed: \(error)")
                    self?.scheduleRestart()
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener?.start(queue: .global(qos: .userInteractive))
        } catch {
            logger.error("Failed to create stream server listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        Task { await stopCaptureForced() }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        logger.info("New connection from \(String(describing: connection.endpoint))")
        let session = StreamSession(connection: connection, server: self)
        sessionsQueue.sync { activeSessions[session.id] = session }
        session.start()
    }

    /// Called by a session after it completes authentication.
    func sessionAuthenticated(_ session: StreamSession, deviceName: String) {
        // If this device reconnects while an old session is still hanging around,
        // drop the stale duplicate so only one stream session remains for it.
        let duplicateSessions = sessionsQueue.sync {
            activeSessions.values.filter {
                $0.id != session.id && $0.authenticatedDeviceID == session.authenticatedDeviceID
            }
        }
        duplicateSessions.forEach { $0.disconnect() }

        // If a live duplicate existed, the pipeline may be associated with the dying session —
        // reset the stale tracker so the restart check below always fires.
        if !duplicateSessions.isEmpty {
            lastVideoInputFrameAt = .distantPast
        }

        // Check if this device recently disconnected (handles the heartbeat-timeout path
        // where the old session is already gone before the new one arrives).
        let deviceID = session.authenticatedDeviceID ?? ""
        let wasRecentlyDisconnected = sessionsQueue.sync { () -> Bool in
            guard let t = lastDisconnectedByDeviceID[deviceID] else { return false }
            lastDisconnectedByDeviceID.removeValue(forKey: deviceID)
            return Date().timeIntervalSince(t) < 60
        }

        // Whether any OTHER authenticated sessions (not this one, not the duplicates we just
        // disconnected) are currently active. If so, don't restart their pipeline.
        let duplicateIDs = Set(duplicateSessions.map { $0.id })
        let hasOtherSessions = sessionsQueue.sync {
            activeSessions.values.contains {
                $0.id != session.id && !duplicateIDs.contains($0.id) && $0.authenticatedDeviceID != nil
            }
        }

        Task { @MainActor in
            appState?.isStreaming = true
            appState?.connectedDeviceName = deviceName
        }

        qualityManager.sessionStarted()

        // Tell iOS what quality is currently active
        session.sendQualityChanged(qualityManager.activePreset)
        if let audioFormat = currentAudioFormat {
            session.sendAudioFormatChanged(sampleRate: audioFormat.sampleRate, channels: audioFormat.channels)
        }

        // Start (or restart) the capture pipeline.
        // On a same-device reconnect with no other active sessions, always restart to ensure
        // a clean pipeline — the stale-frame check alone misses cases where the pipeline
        // appears running but delivers no frames (SCStream silently wedged).
        Task {
            let isReconnect = !duplicateSessions.isEmpty || wasRecentlyDisconnected
            if captureStarted && isReconnect && !hasOtherSessions {
                logger.info("Same-device reconnect (\(deviceID)) — restarting capture pipeline for clean state")
                await restartCapturePipeline()
            } else if captureStarted && Date().timeIntervalSince(lastVideoInputFrameAt) > 4 {
                logger.warning("Capture appears stalled; restarting pipeline before streaming session \(session.id)")
                await restartCapturePipeline()
            } else {
                await startCaptureIfNeeded()
            }

            // Send cached SPS/PPS so the new client can decode immediately,
            // then force an IDR so it doesn't have to wait up to 2 seconds for the next keyframe.
            if let cached = cachedSpsPps {
                session.send(spsPps: cached)
            }
            videoEncoder.requestKeyframe()
        }
        session.beginReceivingStream(videoEncoder: videoEncoder, audioEncoder: audioEncoder)
    }

    /// Called by a session when it disconnects.
    func sessionDisconnected(_ session: StreamSession) {
        let remaining: Int? = sessionsQueue.sync {
            guard activeSessions[session.id] != nil else { return nil }
            activeSessions.removeValue(forKey: session.id)
            if let deviceID = session.authenticatedDeviceID {
                lastDisconnectedByDeviceID[deviceID] = Date()
            }
            return activeSessions.count
        }
        guard let remaining else { return }  // Already removed — nothing to do
        logger.info("Session disconnected: \(session.id). Active sessions: \(remaining)")

        if remaining == 0 {
            qualityManager.sessionEnded()
            Task {
                // Use the guarded stop — if a client reconnected during this async gap,
                // the stop is skipped so the new session's pipeline stays alive.
                await stopCapture()

                // Re-check before publishing streaming = false to avoid clearing UI
                // state that belongs to an already-reconnected client.
                let stillEmpty = sessionsQueue.sync { activeSessions.isEmpty }
                if stillEmpty {
                    await MainActor.run {
                        appState?.isStreaming = false
                        appState?.connectedDeviceName = nil
                    }
                }
            }
        }
    }

    func disconnectAllClients() {
        let sessions = sessionsQueue.sync { () -> [StreamSession] in
            let all = Array(activeSessions.values)
            activeSessions.removeAll()
            return all
        }
        sessions.forEach { $0.disconnect() }
        qualityManager.sessionEnded()
        Task { @MainActor in
            appState?.isStreaming = false
            appState?.connectedDeviceName = nil
        }
        // Use forced stop — activeSessions was cleared above so the guarded
        // version would also pass, but forced is explicit about intent here.
        Task { await stopCaptureForced() }
    }

    /// Notify a specific device that it has been unpaired, then disconnect it.
    func notifyUnpaired(deviceID: String) {
        let session = sessionsQueue.sync {
            activeSessions.values.first { $0.authenticatedDeviceID == deviceID }
        }
        if let session {
            session.sendUnpaired()
            // Give the message a moment to send before closing the connection
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                session.disconnect()
            }
        }
    }

    // MARK: - Quality

    func handleQualityFeedback(_ quality: Double) {
        qualityManager.receiveQualityFeedback(quality)
    }

    func handleQualityRequest(_ preset: StreamQualityPreset) {
        qualityManager.handleQualityRequest(preset)
    }

    func broadcastQualityChanged(_ preset: StreamQualityPreset) {
        let sessions = sessionsQueue.sync { Array(activeSessions.values) }
        sessions.forEach { $0.sendQualityChanged(preset) }
        logger.info("Quality broadcast → \(preset.rawValue)")
    }

    func broadcastAudioFormatChanged(sampleRate: Double, channels: Int) {
        let sessions = sessionsQueue.sync { Array(activeSessions.values) }
        sessions.forEach { $0.sendAudioFormatChanged(sampleRate: sampleRate, channels: channels) }
        logger.info("Audio format broadcast → \(sampleRate, format: .fixed(precision: 0)) Hz, \(channels)ch")
    }

    private func applyQualityPreset(_ preset: StreamQualityPreset) {
        videoEncoder.reconfigure(preset: preset)
        Task {
            try? await screenCapture.updateConfiguration(preset: preset)
            broadcastQualityChanged(preset)
        }
        logger.info("Applying quality preset: \(preset.rawValue)")
    }

    // MARK: - Capture Pipeline

    private func startCaptureIfNeeded() async {
        guard !captureStarted else { return }
        guard let display = await MainActor.run(body: { appState?.selectedDisplay }) else {
            logger.error("No display selected for capture")
            return
        }

        let preset = qualityManager.activePreset
        let hadPendingWindowSelection = pendingWindowSelection != nil
        let resolvedPendingWindow = await resolvePendingWindowSelection()
        do {
            try await screenCapture.start(
                display: display,
                width: preset.width,
                height: preset.height,
                frameRate: preset.fps,
                initialWindow: resolvedPendingWindow,
                initialLockedViewport: nil
            )
            try videoEncoder.start()
            try audioEncoder.start()

            if hadPendingWindowSelection {
                if let resolvedPendingWindow {
                    pendingWindowSelection = resolvedPendingWindow
                    logger.info("Applied pending window mode on capture start: \(resolvedPendingWindow.title ?? "unknown")")
                } else {
                    pendingWindowSelection = nil
                    logger.warning("Pending window selection was unavailable on capture start; falling back to full display")
                    await MainActor.run {
                        self.appState?.isWindowMode = false
                    }
                }
            }

            captureStarted = true
            lastVideoInputFrameAt = Date()
            logger.info("Capture pipeline started")
        } catch {
            logger.error("Failed to start capture pipeline: \(error)")
        }
    }

    /// Stop the capture pipeline, but only if no clients are currently connected.
    /// This prevents the common reconnect race where a deferred stop (from an old
    /// disconnect task) arrives after a new client has already authenticated and
    /// started receiving — killing the pipeline under a live session.
    private func stopCapture() async {
        guard captureStarted else { return }
        let hasReconnected = sessionsQueue.sync { !activeSessions.isEmpty }
        if hasReconnected {
            logger.warning("Capture stop skipped — \(self.activeSessions.count) client(s) reconnected before deferred stop ran")
            return
        }
        await stopCaptureForced()
    }

    /// Unconditionally tear down the capture pipeline.
    /// Use for restarts, server shutdown, and SCStream error recovery — not for
    /// ordinary session-end cleanup (use stopCapture() there instead).
    private func stopCaptureForced() async {
        guard captureStarted else { return }
        await screenCapture.stop()
        videoEncoder.stop()
        audioEncoder.stop()
        captureStarted = false
        cachedSpsPps = nil          // Force fresh SPS/PPS for the next client
        lastVideoInputFrameAt = .distantPast
        logger.info("Capture pipeline stopped")
    }

    private func restartCapturePipeline() async {
        // Use forced stop even though sessions may be active (caller already handled them).
        await stopCaptureForced()
        await startCaptureIfNeeded()
    }

    // MARK: - Display Switch

    /// Hot-swap the captured display without dropping existing connections.
    func switchDisplay() async {
        guard captureStarted,
              let display = await MainActor.run(body: { appState?.selectedDisplay }) else { return }
        do {
            try await screenCapture.updateDisplay(display)
            videoEncoder.requestKeyframe()  // new display → need fresh IDR
            logger.info("Switched capture display to \(display.displayID)")
        } catch {
            logger.error("Failed to switch display: \(error)")
        }
    }

    // MARK: - Window Streaming

    func switchToWindowMode(window: SCWindow) async {
        pendingWindowSelection = window
        guard captureStarted else {
            logger.info("Stored window mode selection for next capture start: \(window.title ?? "unknown")")
            return
        }

        let targetWindow = await resolveWindowSelection(from: window) ?? window
        do {
            try await screenCapture.startWindowMode(window: targetWindow)
            pendingWindowSelection = targetWindow
            videoEncoder.requestKeyframe()
            logger.info("Switched to window mode: \(targetWindow.title ?? "unknown")")
        } catch {
            logger.error("Failed to switch to window mode: \(error)")
        }
    }

    func switchToDisplayMode() async {
        pendingWindowSelection = nil
        guard captureStarted,
              let display = await MainActor.run(body: { appState?.selectedDisplay }) else { return }
        do {
            try await screenCapture.stopWindowMode(display: display)
            videoEncoder.requestKeyframe()
            logger.info("Returned to full display mode")
        } catch {
            logger.error("Failed to return to display mode: \(error)")
        }
    }

    // MARK: - Restart

    private func scheduleRestart() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.stop()
            self?.start()
        }
    }

    private func resolvePendingWindowSelection() async -> SCWindow? {
        guard let pendingWindowSelection else { return nil }
        return await resolveWindowSelection(from: pendingWindowSelection)
    }

    private func resolveWindowSelection(from requestedWindow: SCWindow) async -> SCWindow? {
        let windows = await ScreenCapture.availableWindows()
        guard !windows.isEmpty else { return requestedWindow }

        if let exact = windows.first(where: { $0.windowID == requestedWindow.windowID }) {
            return exact
        }

        let requestedTitle = requestedWindow.title ?? ""
        let requestedAppName = requestedWindow.owningApplication?.applicationName ?? ""
        if !requestedTitle.isEmpty || !requestedAppName.isEmpty {
            if let fallback = windows.first(where: {
                ($0.title ?? "") == requestedTitle
                    && ($0.owningApplication?.applicationName ?? "") == requestedAppName
            }) {
                return fallback
            }
        }

        return nil
    }
}

// MARK: - ScreenCaptureDelegate

extension StreamServer: ScreenCaptureDelegate {
    func screenCapture(_ capture: ScreenCapture, didOutputVideoFrame frame: CMSampleBuffer) {
        lastVideoInputFrameAt = Date()
        videoEncoder.encode(sampleBuffer: frame)
    }

    func screenCapture(_ capture: ScreenCapture, didOutputAudioFrame frame: CMSampleBuffer) {
        audioEncoder.encode(sampleBuffer: frame)
    }

    func screenCapture(_ capture: ScreenCapture, didFailWithError error: Error) {
        logger.error("Screen capture error: \(error)")
        guard !isRecoveringCapture else { return }
        isRecoveringCapture = true

        Task {
            disconnectAllClients()
            await restartCapturePipeline()
            isRecoveringCapture = false
        }
    }
}

// MARK: - VideoEncoderDelegate

extension StreamServer: VideoEncoderDelegate {
    func videoEncoder(_ encoder: VideoEncoder, didEncodeFrame data: Data, presentationTime: CMTime, isKeyframe: Bool) {
        let sessions = sessionsQueue.sync { Array(activeSessions.values) }
        sessions.forEach { $0.send(videoData: data, pts: presentationTime, isKeyframe: isKeyframe) }
    }

    func videoEncoder(_ encoder: VideoEncoder, didEncodeParameterSets spsData: Data, ppsData: Data) {
        let combined = spsData + ppsData
        cachedSpsPps = combined
        let sessions = sessionsQueue.sync { Array(activeSessions.values) }
        sessions.forEach { $0.send(spsPps: combined) }
    }
}

// MARK: - AudioEncoderDelegate

extension StreamServer: AudioEncoderDelegate {
    func audioEncoder(_ encoder: AudioEncoder, didEncodeChunk data: Data, presentationTime: CMTime) {
        let sessions = sessionsQueue.sync { Array(activeSessions.values) }
        sessions.forEach { $0.send(audioData: data, pts: presentationTime) }
    }

    func audioEncoder(_ encoder: AudioEncoder, didUpdateSampleRate sampleRate: Double, channels: Int) {
        currentAudioFormat = (sampleRate: sampleRate, channels: channels)
        broadcastAudioFormatChanged(sampleRate: sampleRate, channels: channels)
    }
}
