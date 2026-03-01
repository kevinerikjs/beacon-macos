// ScreenCapture.swift
// ScreenCaptureKit wrapper for capturing display content and system audio.
// Uses SCStream for hardware-accelerated capture.

import ScreenCaptureKit
import CoreMedia
import CoreVideo
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "ScreenCapture")

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
        label: "com.beam.beacon.capture",
        qos: .userInteractive
    )

    // Track current window filter (nil = full display)
    private var currentWindow: SCWindow? = nil
    private var currentDisplay: SCDisplay?
    private var currentWidth: Int = 1920
    private var currentHeight: Int = 1080
    private var currentFrameRate: Double = 30
    private var normalizedLockedViewport: CGRect? = nil

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
        captureAudio: Bool = true,
        initialWindow: SCWindow? = nil,
        initialLockedViewport: CGRect? = nil
    ) async throws {
        guard stream == nil else { return }

        // Stream configuration
        currentDisplay = display
        currentWidth = width
        currentHeight = height
        currentFrameRate = frameRate
        currentWindow = initialWindow
        if let initialLockedViewport {
            normalizedLockedViewport = CGRect(
                x: initialLockedViewport.origin.x.clamped(to: 0...1),
                y: initialLockedViewport.origin.y.clamped(to: 0...1),
                width: initialLockedViewport.width.clamped(to: 0.1...1),
                height: initialLockedViewport.height.clamped(to: 0.1...1)
            )
        } else {
            normalizedLockedViewport = nil
        }

        let filter: SCContentFilter
        if let initialWindow {
            filter = SCContentFilter(desktopIndependentWindow: initialWindow)
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }

        let config = makeConfiguration(captureAudio: captureAudio)

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
        if let initialWindow {
            logger.info("Screen capture started in window mode: \(initialWindow.title ?? "unknown")")
        } else {
            logger.info("Screen capture started on display \(display.displayID)")
        }
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
            self.stream = nil
            self.currentWindow = nil
            self.currentDisplay = nil
            self.normalizedLockedViewport = nil
            logger.info("Screen capture stopped")
        } catch {
            logger.error("Failed to stop capture stream: \(error)")
        }
    }

    /// Update the display being captured without restarting the full stream.
    func updateDisplay(_ display: SCDisplay) async throws {
        guard let stream else { return }
        currentDisplay = display
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        try await stream.updateContentFilter(filter)
        if currentWindow == nil {
            try await stream.updateConfiguration(makeConfiguration(captureAudio: true))
        }
    }

    /// Update stream resolution and frame rate without restarting the stream.
    func updateConfiguration(preset: StreamQualityPreset) async throws {
        guard let stream else { return }
        currentWidth = preset.width
        currentHeight = preset.height
        currentFrameRate = preset.fps
        try await stream.updateConfiguration(makeConfiguration(captureAudio: true))
        logger.info("ScreenCapture updated → \(preset.width)x\(preset.height) @\(Int(preset.fps))fps")
    }

    /// Switch to capturing a specific window. Call after start().
    func startWindowMode(window: SCWindow) async throws {
        guard let stream else { return }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        try await stream.updateContentFilter(filter)
        currentWindow = window
        logger.info("ScreenCapture switched to window: \(window.title ?? "unknown")")
    }

    /// Return to capturing the full display.
    func stopWindowMode(display: SCDisplay) async throws {
        guard let stream else { return }
        currentDisplay = display
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        try await stream.updateContentFilter(filter)
        try await stream.updateConfiguration(makeConfiguration(captureAudio: true))
        currentWindow = nil
        logger.info("ScreenCapture returned to full display")
    }

    /// Crop full-display capture to a normalized viewport rect (0...1 space).
    /// Pass nil to return to uncropped full-display capture.
    func setLockedViewport(_ normalizedRect: CGRect?) async throws {
        guard let stream else { return }
        if let normalizedRect {
            normalizedLockedViewport = CGRect(
                x: normalizedRect.origin.x.clamped(to: 0...1),
                y: normalizedRect.origin.y.clamped(to: 0...1),
                width: normalizedRect.width.clamped(to: 0.1...1),
                height: normalizedRect.height.clamped(to: 0.1...1)
            )
        } else {
            normalizedLockedViewport = nil
        }
        try await stream.updateConfiguration(makeConfiguration(captureAudio: true))
        logger.info("ScreenCapture viewport lock updated: \(normalizedRect != nil)")
    }

    private func makeConfiguration(captureAudio: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = currentWidth
        config.height = currentHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(currentFrameRate))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        config.showsCursor = true
        config.capturesAudio = captureAudio
        config.sampleRate = 44100
        config.channelCount = 2

        if let normalizedLockedViewport {
            let sourceSize: CGSize
            if let currentWindow {
                sourceSize = CGSize(width: currentWindow.frame.width, height: currentWindow.frame.height)
            } else if let display = currentDisplay {
                sourceSize = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
            } else {
                return config
            }
            let sourceWidth = sourceSize.width
            let sourceHeight = sourceSize.height
            guard sourceWidth > 0, sourceHeight > 0 else { return config }
            let frameSize = CGSize(width: CGFloat(currentWidth), height: CGFloat(currentHeight))
            let sourceNormalizedRect = sourceNormalizedViewport(
                fromFrameNormalizedRect: normalizedLockedViewport,
                sourceSize: sourceSize,
                frameSize: frameSize
            )
            guard !sourceNormalizedRect.isNull else { return config }

            let requestedRect = CGRect(
                x: (sourceNormalizedRect.origin.x * sourceWidth).clamped(to: 0...sourceWidth),
                y: (sourceNormalizedRect.origin.y * sourceHeight).clamped(to: 0...sourceHeight),
                width: (sourceNormalizedRect.width * sourceWidth).clamped(to: 64...sourceWidth),
                height: (sourceNormalizedRect.height * sourceHeight).clamped(to: 64...sourceHeight)
            ).intersection(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))

            let lockedRect = constrained16x9Rect(
                from: requestedRect,
                within: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
            )
            if !lockedRect.isNull, lockedRect.width > 10, lockedRect.height > 10 {
                config.sourceRect = lockedRect
            }
        }
        return config
    }

    /// Convert iOS lock coordinates from encoded-frame normalized space into source-content normalized space.
    /// This compensates for letterbox/pillarbox introduced by `scalesToFit` when source and output aspect differ.
    private func sourceNormalizedViewport(
        fromFrameNormalizedRect frameRect: CGRect,
        sourceSize: CGSize,
        frameSize: CGSize
    ) -> CGRect {
        guard
            frameSize.width > 0, frameSize.height > 0,
            sourceSize.width > 0, sourceSize.height > 0
        else {
            return .null
        }

        let frameAspect = frameSize.width / frameSize.height
        let sourceAspect = sourceSize.width / sourceSize.height

        var contentRectInFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
        if sourceAspect > frameAspect {
            let contentHeight = (frameAspect / sourceAspect).clamped(to: 0.001...1)
            contentRectInFrame = CGRect(x: 0, y: (1 - contentHeight) / 2, width: 1, height: contentHeight)
        } else if sourceAspect < frameAspect {
            let contentWidth = (sourceAspect / frameAspect).clamped(to: 0.001...1)
            contentRectInFrame = CGRect(x: (1 - contentWidth) / 2, y: 0, width: contentWidth, height: 1)
        }

        let mapped = CGRect(
            x: (frameRect.minX - contentRectInFrame.minX) / contentRectInFrame.width,
            y: (frameRect.minY - contentRectInFrame.minY) / contentRectInFrame.height,
            width: frameRect.width / contentRectInFrame.width,
            height: frameRect.height / contentRectInFrame.height
        )

        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let normalized = mapped.intersection(unit)
        guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else { return .null }
        return normalized
    }

    private func constrained16x9Rect(from rect: CGRect, within bounds: CGRect) -> CGRect {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return .null }

        let targetAspect: CGFloat = 16.0 / 9.0
        let rectAspect = rect.width / rect.height
        let center = CGPoint(x: rect.midX, y: rect.midY)

        var width: CGFloat
        var height: CGFloat
        if rectAspect > targetAspect {
            height = rect.height
            width = height * targetAspect
        } else {
            width = rect.width
            height = width / targetAspect
        }

        // Keep a minimum footprint while preserving 16:9.
        if height < 64 {
            height = 64
            width = height * targetAspect
        }

        // Clamp to bounds while preserving 16:9.
        if width > bounds.width {
            width = bounds.width
            height = width / targetAspect
        }
        if height > bounds.height {
            height = bounds.height
            width = height * targetAspect
        }

        let originX = (center.x - width / 2).clamped(to: bounds.minX...(bounds.maxX - width))
        let originY = (center.y - height / 2).clamped(to: bounds.minY...(bounds.maxY - height))

        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Get all currently available on-screen windows (for the window picker menu).
    static func availableWindows() async -> [SCWindow] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return content.windows.filter { $0.frame.width > 100 && $0.frame.height > 100 }
        } catch {
            logger.error("Failed to enumerate windows: \(error)")
            return []
        }
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
