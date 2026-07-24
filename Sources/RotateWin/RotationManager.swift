import AppKit
import ScreenCaptureKit

/// Manages one rotation session per window so several windows can be rotated
/// at once.
@MainActor
final class RotationManager {
    private(set) var sessions: [RotationSession] = []

    /// Notified whenever sessions change so the menu can refresh.
    var onStateChange: (() -> Void)?

    var isEmpty: Bool { sessions.isEmpty }

    /// Starts rotating `window` at the given initial activation choice (a
    /// preset angle, or free), or brings its existing session to the front.
    func rotate(window: SCWindow, choice: ActivationChoice) {
        guard AccessibilityWindowMover.ensureTrusted() else {
            warn("Accessibility permission is required to hide the source window.")
            return
        }
        if sessions.contains(where: { $0.windowID == window.windowID }) { return }

        let session = RotationSession(window: window, degrees: choice.initialDegrees)
        session.onExternalStop = { [weak self] session in
            self?.remove(session)
        }
        if let reason = session.start() {
            warn(reason)
            return
        }
        sessions.append(session)
        onStateChange?()
    }

    func stop(_ session: RotationSession) {
        session.stop()
        remove(session)
    }

    func stopAll() {
        sessions.forEach { $0.stop() }
        sessions.removeAll()
        onStateChange?()
    }

    // MARK: - Private

    private func remove(_ session: RotationSession) {
        sessions.removeAll { $0 === session }
        onStateChange?()
    }

    private func warn(_ message: String) {
        NSLog("RotateWin: \(message)")
        let alert = NSAlert()
        alert.messageText = "Rotate Window"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
