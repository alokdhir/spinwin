import AppKit
import ScreenCaptureKit

/// Wraps an SCStream that continuously captures a single window and delivers
/// each frame's IOSurface (zero-copy) to the main actor for display.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.rotatewin.capture")
    private var onSurface: ((IOSurface) -> Void)?
    /// Called on the main thread if capture stops on its own (e.g. the user
    /// clicks the system "Stop Sharing" menu bar control).
    var onStop: (() -> Void)?

    /// Starts capturing `window`. `handler` is called on the main thread for
    /// every new frame with the frame's IOSurface.
    func start(window: SCWindow, handler: @escaping (IOSurface) -> Void) async throws {
        onSurface = handler

        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        // Match the window's actual display scale: Retina stays crisp, but a
        // plain 1x display isn't upscaled 4x for no visual gain.
        let scale = backingScale(for: window.frame)
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        // 30 fps is plenty and far cheaper than 60.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Backing scale factor of the display containing `cgFrame` (CoreGraphics
    /// top-left coordinates), so capture resolution matches the window's real
    /// pixel density instead of assuming Retina. Falls back to 2 if no screen
    /// contains it (e.g. a window straddling displays or off-screen).
    private func backingScale(for cgFrame: CGRect) -> CGFloat {
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main)?.frame.height ?? cgFrame.maxY
        let cocoaCenter = CGPoint(x: cgFrame.midX, y: primaryHeight - cgFrame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(cocoaCenter) }
        return screen?.backingScaleFactor ?? 2
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        onSurface = nil
        // Remove ourselves as the stream's output so SCStream drops its strong
        // reference back to this engine; otherwise the two can keep each other
        // alive (along with any in-flight frame's IOSurface) past stop.
        Task {
            try? stream.removeStreamOutput(self, type: .screen)
            try? await stream.stopCapture()
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream != nil else { return }
            self.stream = nil
            self.onSurface = nil
            self.onStop?()
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // Only render frames flagged as complete.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        // Keep the pixel buffer alive across the hop to main so its backing
        // IOSurface stays valid until CoreAnimation retains it.
        let retainedBuffer = pixelBuffer
        DispatchQueue.main.async { [weak self] in
            guard let surface = CVPixelBufferGetIOSurface(retainedBuffer)?.takeUnretainedValue() else { return }
            self?.onSurface?(surface)
            _ = retainedBuffer // extend lifetime through the closure
        }
    }
}
