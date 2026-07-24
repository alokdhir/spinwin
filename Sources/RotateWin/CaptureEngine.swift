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
        // Capture at 2x so the rotated overlay stays crisp on Retina displays.
        let scale = 2
        config.width = Int(window.frame.width) * scale
        config.height = Int(window.frame.height) * scale
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

    func stop() {
        guard let stream else { return }
        self.stream = nil
        onSurface = nil
        Task { try? await stream.stopCapture() }
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
