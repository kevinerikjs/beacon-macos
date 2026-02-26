// ScreenCapture.swift
// ScreenCaptureKit wrapper for capturing display content and system audio.
// Uses SCStream for hardware-accelerated capture.

import ScreenCaptureKit
import CoreMedia
import CoreVideo
import OSLog

private let logger = Logger(subsystem: "com.beam.host", category: "ScreenCapture")

// MARK: - Delegate Protocol

protocol ScreenCaptureDelegate: AnyObject {
    func screenCapture(_ capture: ScreenCapture, didOutputVideoFrame frame: CMSampleBuffer)
    func screenCapture(_ capture: ScreenCapture, didOutputAudioFrame frame: CMSampleBuffer)
    func screenCapture(_ capture: ScreenCapture, didFailWithError error: Error)
}

// MARK: - ScreenCapture

final class ScreenCapture: NSObject {

    weak var delegate: ScreenCaptureDelegate?

    private var stream: SCStream?
    private let captureQueue = DispatchQueue(
        label: "com.beam.host.capture",
        qos: .userInteractive
    )

    // MARK: - Permission

    /// Request Screen Recording permission. Returns true if currently authorized.
    /// On first call macOS will display the permission dialog.
    static func requestPermission() async -> Bool {
        do {
            // Calling SCShareableContent triggers the permission dialog if not yet granted
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            logger.error("Screen Recording permission denied or unavailable: \(error)")
            return false
        }
    }

    /// Returns all currently available displays.
    static func availableDisplays() async -> [SCDisplay] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return content.displays
        } catch {
            logger.error("Failed to enumerate displays: \(error)")
            return []
        }
    }

    // MARK: - Start / Stop

    /// Begin capturing the given display at the specified resolution and frame rate.
    func start(
        display: SCDisplay,
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Double = 30,
        captureAudio: Bool = true
    ) async throws {
        guard stream == nil else { return }

        // Build content filter: capture the whole display
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        // Stream configuration
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        config.showsCursor = true

        // Audio capture
        config.capturesAudio = captureAudio
        config.sampleRate = 44100
        config.channelCount = 2
        // Note: excludesCurrentProcessAudioFromCapture available on macOS 15+

        let captureStream = SCStream(filter: filter, configuration: config, delegate: self)

        // Add video output handler
        try captureStream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: captureQueue
        )

        // Add audio output handler
        if captureAudio {
            try captureStream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: captureQueue
            )
        }

        try await captureStream.startCapture()
        self.stream = captureStream
        logger.info("Screen capture started on display \(display.displayID)")
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
            self.stream = nil
            logger.info("Screen capture stopped")
        } catch {
            logger.error("Failed to stop capture stream: \(error)")
        }
    }

    /// Update the display being captured without restarting the full stream.
    func updateDisplay(_ display: SCDisplay) async throws {
        guard let stream else { return }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        try await stream.updateContentFilter(filter)
    }
}

// MARK: - SCStreamDelegate

extension ScreenCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("SCStream stopped with error: \(error)")
        delegate?.screenCapture(self, didFailWithError: error)
    }
}

// MARK: - SCStreamOutput

extension ScreenCapture: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }

        switch outputType {
        case .screen:
            delegate?.screenCapture(self, didOutputVideoFrame: sampleBuffer)
        case .audio:
            delegate?.screenCapture(self, didOutputAudioFrame: sampleBuffer)
        case .microphone:
            break  // Not used
        @unknown default:
            break
        }
    }
}
