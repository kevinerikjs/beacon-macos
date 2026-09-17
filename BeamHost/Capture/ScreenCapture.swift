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
    /// Actual encoded frame size. Equals the preset's size on a full display; in window mode
    /// it takes the window's aspect ratio (BEAM-38) so a tall window streams tall instead of
    /// letterboxed inside a 16:9 frame.
    private var currentWidth: Int = 1920
    private var currentHeight: Int = 1080
    /// The quality preset's nominal size: the pixel budget the frame is derived from.
    private var presetWidth: Int = 1920
    private var presetHeight: Int = 1080

    var currentFrameSize: CGSize { CGSize(width: currentWidth, height: currentHeight) }

    /// Frame size for a source aspect within the current preset's budget (BEAM-38). The preset's
    /// long edge caps the frame's long edge; the other side follows the source aspect. Both are
    /// rounded to multiples of 16 for the encoder. Full display keeps the preset size verbatim
    /// so nothing changes for the common case.
    func frameSize(for window: SCWindow?, preset: StreamQualityPreset? = nil, lock: CGRect? = nil) -> CGSize {
        let pw = preset?.width ?? presetWidth
        let ph = preset?.height ?? presetHeight
        let source: CGSize
        if let window, window.frame.width > 0, window.frame.height > 0 {
            source = window.frame.size
        } else if let lock, let display = currentDisplay, display.width > 0, display.height > 0 {
            source = CGSize(width: display.width, height: display.height)
        } else {
            return CGSize(width: pw, height: ph)
        }
        // A locked region is the source now: the frame takes its pixel aspect.
        let aspect: CGFloat
        if let lock, lock.width > 0, lock.height > 0 {
            aspect = (lock.width * source.width) / (lock.height * source.height)
        } else {
            aspect = source.width / source.height
        }
        let longEdge = CGFloat(max(pw, ph))
        var w: CGFloat, h: CGFloat
        if aspect >= 1 {
            w = longEdge; h = longEdge / aspect
        } else {
            h = longEdge; w = longEdge * aspect
        }
        func snap(_ v: CGFloat) -> Int { max(128, Int((v / 16).rounded()) * 16) }
        return CGSize(width: snap(w), height: snap(h))
    }

    private func applyFrameSize(_ size: CGSize) {
        currentWidth = Int(size.width)
        currentHeight = Int(size.height)
    }
    private var currentFrameRate: Double = 30
    /// Viewport lock in source-normalised space (0...1 of the window or display). Converted
    /// from the phone's frame-normalised rect once, at lock time, against the frame the phone
    /// was looking at; after that the frame itself takes the lock's aspect (BEAM-38), so the
    /// locked region streams edge to edge instead of being forced back into the window's shape.
    private(set) var sourceLockedViewport: CGRect? = nil

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
        presetWidth = width
        presetHeight = height
        currentFrameRate = frameRate
        currentWindow = initialWindow
        applyFrameSize(frameSize(for: initialWindow))
        if let initialLockedViewport {
            sourceLockedViewport = sourceRect(forFrameNormalized: initialLockedViewport)
            applyFrameSize(frameSize(for: initialWindow, lock: sourceLockedViewport))
        } else {
            sourceLockedViewport = nil
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
        } catch {
            logger.error("Failed to stop capture stream: \(error)")
        }
        // Always nil out regardless of error — a failed stop leaves the stream unusable,
        // and keeping self.stream non-nil would block the next start() call (guard stream == nil).
        self.stream = nil
        self.currentWindow = nil
        self.currentDisplay = nil
        self.sourceLockedViewport = nil
        logger.info("Screen capture stopped")
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
        presetWidth = preset.width
        presetHeight = preset.height
        currentFrameRate = preset.fps
        applyFrameSize(frameSize(for: currentWindow, lock: sourceLockedViewport))
        try await stream.updateConfiguration(makeConfiguration(captureAudio: true))
        logger.info("ScreenCapture updated → \(self.currentWidth)x\(self.currentHeight) @\(Int(preset.fps))fps")
    }

    /// Switch to capturing a specific window. Call after start().
    func startWindowMode(window: SCWindow) async throws {
        guard let stream else { return }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        try await stream.updateContentFilter(filter)
        currentWindow = window
        applyFrameSize(frameSize(for: window))
        // Apply destinationRect centering for the new window
        try await stream.updateConfiguration(makeConfiguration(captureAudio: true))
        logger.info("ScreenCapture switched to window: \(window.title ?? "unknown") → \(self.currentWidth)x\(self.currentHeight)")
    }

    /// Return to capturing the full display.
    func stopWindowMode(display: SCDisplay) async throws {
        guard let stream else { return }
        currentDisplay = display
        currentWindow = nil  // Clear before makeConfiguration so destinationRect is not applied
        applyFrameSize(frameSize(for: nil))
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        try await stream.updateContentFilter(filter)
        try await stream.updateConfiguration(makeConfiguration(captureAudio: true))
        logger.info("ScreenCapture returned to full display")
    }

    /// Sample rate the client asked for at auth (BEAM-29), applied to every capture
    /// configuration. Defaults to 48kHz, which is what ScreenCaptureKit delivers anyway and
    /// what iPhone hardware runs natively, so the common case needs no negotiation at all.
    private(set) var requestedAudioSampleRate: Double = 48_000

    /// Applies a client-requested rate. Only takes effect on the next capture configuration,
    /// which is deliberate: changing it under a live SCStream would force the client to
    /// renegotiate its engine, which is the exact churn this is meant to remove.
    func setRequestedAudioSampleRate(_ rate: Double) {
        guard rate != requestedAudioSampleRate else { return }
        requestedAudioSampleRate = rate
    }

    /// Convert a phone-side lock (normalised to the frame the phone is currently showing) into
    /// source-normalised space, compensating for any letterbox in the current frame. nil when
    /// there is no source yet or the rect is degenerate.
    func sourceRect(forFrameNormalized rect: CGRect) -> CGRect? {
        let clamped = CGRect(
            x: rect.origin.x.clamped(to: 0...1),
            y: rect.origin.y.clamped(to: 0...1),
            width: rect.width.clamped(to: 0.05...1),
            height: rect.height.clamped(to: 0.05...1)
        )
        let sourceSize: CGSize
        if let currentWindow {
            sourceSize = currentWindow.frame.size
        } else if let display = currentDisplay {
            sourceSize = CGSize(width: display.width, height: display.height)
        } else {
            return nil
        }
        let mapped = sourceNormalizedViewport(
            fromFrameNormalizedRect: clamped,
            sourceSize: sourceSize,
            frameSize: CGSize(width: currentWidth, height: currentHeight)
        )
        return mapped.isNull ? nil : mapped
    }

    /// Crop capture to a source-normalised viewport rect (from `sourceRect(forFrameNormalized:)`)
    /// and resize the frame to that region's aspect. Pass nil to return to the uncropped source.
    /// The caller reconfigures the encoder to `frameSize(for:lock:)` BEFORE this so the SPS
    /// describes the frames that follow.
    func setLockedViewport(source: CGRect?) async throws {
        guard let stream else { return }
        sourceLockedViewport = source
        applyFrameSize(frameSize(for: currentWindow, lock: source))
        try await stream.updateConfiguration(makeConfiguration(captureAudio: true))
        logger.info("ScreenCapture viewport lock updated: \(source != nil) → \(self.currentWidth)x\(self.currentHeight)")
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
        // 48kHz, not 44.1kHz: it is what ScreenCaptureKit actually delivers regardless of what
        // we ask for, AND it is the iPhone's native hardware rate. Matching them end to end
        // means the sample rate is never converted anywhere in the chain — not by SCK, not by
        // the AAC encoder, not by AVAudioEngine on the client. Asking for 44100 only created a
        // mismatch between stated intent and reality.
        config.sampleRate = Int(requestedAudioSampleRate)
        config.channelCount = 2

        if let sourceNormalizedRect = sourceLockedViewport {
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

            let requestedRect = CGRect(
                x: (sourceNormalizedRect.origin.x * sourceWidth).clamped(to: 0...sourceWidth),
                y: (sourceNormalizedRect.origin.y * sourceHeight).clamped(to: 0...sourceHeight),
                width: (sourceNormalizedRect.width * sourceWidth).clamped(to: 64...sourceWidth),
                height: (sourceNormalizedRect.height * sourceHeight).clamped(to: 64...sourceHeight)
            ).intersection(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))

            let lockedRect = constrainedRect(
                from: requestedRect,
                within: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
                aspect: CGFloat(currentWidth) / CGFloat(currentHeight)
            )
            if !lockedRect.isNull, lockedRect.width > 10, lockedRect.height > 10 {
                config.sourceRect = lockedRect
            }
        } else if let currentWindow {
            // No lock in window mode: explicitly center the window content in the output frame.
            //
            // By default SCKit aligns window content to the top-left of the output buffer,
            // producing an asymmetric black region (e.g. all black at the bottom for a wide window).
            // Centering via destinationRect gives symmetric letterbox/pillarbox AND makes the
            // coordinate math in sourceNormalizedViewport (which assumes centered content) correct,
            // so viewport lock selections map to the right source region.
            let sourceWidth = currentWindow.frame.width
            let sourceHeight = currentWindow.frame.height
            if sourceWidth > 0, sourceHeight > 0 {
                let windowAspect = sourceWidth / sourceHeight
                let frameAspect = CGFloat(currentWidth) / CGFloat(currentHeight)
                let scaledW: CGFloat
                let scaledH: CGFloat
                if windowAspect >= frameAspect {
                    // Wider than output — fit to width, letterbox vertically
                    scaledW = CGFloat(currentWidth)
                    scaledH = (CGFloat(currentWidth) / windowAspect).rounded()
                } else {
                    // Taller than output — fit to height, pillarbox horizontally
                    scaledH = CGFloat(currentHeight)
                    scaledW = (CGFloat(currentHeight) * windowAspect).rounded()
                }
                let offsetX = ((CGFloat(currentWidth) - scaledW) / 2).rounded()
                let offsetY = ((CGFloat(currentHeight) - scaledH) / 2).rounded()
                config.destinationRect = CGRect(x: offsetX, y: offsetY, width: scaledW, height: scaledH)
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

    /// Fits `rect` to the encoded frame's aspect (16:9 on a full display; the window's aspect in
    /// window mode, BEAM-38) so a lock never reintroduces letterboxing.
    private func constrainedRect(from rect: CGRect, within bounds: CGRect, aspect targetAspect: CGFloat) -> CGRect {
        guard !rect.isNull, rect.width > 0, rect.height > 0, targetAspect > 0 else { return .null }

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

        // Keep a minimum footprint while preserving the aspect.
        if height < 64 {
            height = 64
            width = height * targetAspect
        }

        // Clamp to bounds while preserving the aspect.
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
