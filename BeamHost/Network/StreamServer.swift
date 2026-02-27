// StreamServer.swift
// TCP listener that accepts Beam client connections and orchestrates the streaming pipeline.
// Each connected client gets its own StreamSession.

import Network
import ScreenCaptureKit
import OSLog

private let logger = Logger(subsystem: "com.beam.host", category: "StreamServer")

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
    private let screenCapture = ScreenCapture()
    private let videoEncoder = VideoEncoder(width: 1920, height: 1080, frameRate: 30, bitrateMbps: 6)
    private let audioEncoder = AudioEncoder()

    private var captureStarted = false

    init(appState: AppState) {
        self.appState = appState
        videoEncoder.delegate = self
        audioEncoder.delegate = self
        screenCapture.delegate = self
    }

    // MARK: - Start / Stop

    func start() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true

            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: listeningPort) ?? 7979)

            // Advertise via Bonjour on the same listener — avoids the two-listener port conflict.
            let deviceName = Host.current().localizedName ?? "Beam"
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
        Task { await stopCapture() }
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
        Task { @MainActor in
            appState?.isStreaming = true
            appState?.connectedDeviceName = deviceName
        }

        // Send cached SPS/PPS so the new client can decode immediately,
        // then force an IDR so it doesn't have to wait up to 2 seconds for the next keyframe.
        if let cached = cachedSpsPps {
            session.send(spsPps: cached)
        }
        videoEncoder.requestKeyframe()

        // Start capture pipeline on first authenticated client
        Task { await startCaptureIfNeeded() }
        session.beginReceivingStream(videoEncoder: videoEncoder, audioEncoder: audioEncoder)
    }

    /// Called by a session when it disconnects.
    func sessionDisconnected(_ session: StreamSession) {
        let remaining = sessionsQueue.sync { () -> Int in
            activeSessions.removeValue(forKey: session.id)
            return activeSessions.count
        }
        logger.info("Session disconnected: \(session.id). Active sessions: \(remaining)")

        if remaining == 0 {
            Task {
                await stopCapture()
                await MainActor.run {
                    appState?.isStreaming = false
                    appState?.connectedDeviceName = nil
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
        Task { await stopCapture() }
    }

    // MARK: - Capture Pipeline

    private func startCaptureIfNeeded() async {
        guard !captureStarted else { return }
        guard let display = await MainActor.run(body: { appState?.selectedDisplay }) else {
            logger.error("No display selected for capture")
            return
        }

        do {
            try await screenCapture.start(display: display)
            try videoEncoder.start()
            try audioEncoder.start()
            captureStarted = true
            logger.info("Capture pipeline started")
        } catch {
            logger.error("Failed to start capture pipeline: \(error)")
        }
    }

    private func stopCapture() async {
        guard captureStarted else { return }
        await screenCapture.stop()
        videoEncoder.stop()
        audioEncoder.stop()
        captureStarted = false
        logger.info("Capture pipeline stopped")
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

    // MARK: - Restart

    private func scheduleRestart() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.stop()
            self?.start()
        }
    }
}

// MARK: - ScreenCaptureDelegate

extension StreamServer: ScreenCaptureDelegate {
    func screenCapture(_ capture: ScreenCapture, didOutputVideoFrame frame: CMSampleBuffer) {
        videoEncoder.encode(sampleBuffer: frame)
    }

    func screenCapture(_ capture: ScreenCapture, didOutputAudioFrame frame: CMSampleBuffer) {
        audioEncoder.encode(sampleBuffer: frame)
    }

    func screenCapture(_ capture: ScreenCapture, didFailWithError error: Error) {
        logger.error("Screen capture error: \(error)")
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
}
