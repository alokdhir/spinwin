import AppKit
import ScreenCaptureKit

/// One rotated window: hides the real window off-screen, captures it, and draws
/// rotated (or spinning) frames in its own overlay. Each session is independent.
@MainActor
final class RotationSession {
    let windowID: CGWindowID
    let title: String

    private(set) var degrees: Double
    private(set) var spinning: Bool
    private(set) var rpm: Double
    private(set) var spinDirection: SpinDirection
    private(set) var isRunning = false

    /// Called when this session stops on its own (e.g. system "Stop Sharing").
    var onExternalStop: ((RotationSession) -> Void)?
    /// Called with a human-readable reason when the session fails *after*
    /// `start()` already returned success (capture can only fail asynchronously),
    /// so the failure is shown instead of vanishing into the log while the user
    /// watches their window disappear and come back for no apparent reason.
    var onFailure: ((String) -> Void)?
    /// Called when rotation state changes from something other than a menu
    /// action (free-drag settling, click-to-stop-spin), so the menu checkmarks
    /// can be refreshed.
    var onChanged: (() -> Void)?

    private let window: SCWindow
    private let capture = CaptureEngine()
    private let mover = AccessibilityWindowMover()
    private var overlay: OverlayWindow?

    init(window: SCWindow, degrees: Double = 180, spinning: Bool = false, rpm: Double = 15, spinDirection: SpinDirection = .clockwise) {
        self.window = window
        self.windowID = window.windowID
        self.degrees = degrees
        self.spinning = spinning
        self.rpm = rpm
        self.spinDirection = spinDirection

        let app = window.owningApplication?.applicationName ?? "Unknown"
        let name = (window.title?.isEmpty == false) ? window.title! : "(untitled)"
        self.title = "\(app) — \(name)"

        capture.onStop = { [weak self] in
            guard let self, self.isRunning else { return }
            self.stop()
            self.onExternalStop?(self)
        }
    }

    // MARK: - Control

    /// Returns nil on success, or a human-readable failure reason.
    func start() -> String? {
        guard let pid = window.owningApplication?.processID else {
            return "The selected window has no owning application."
        }
        guard mover.hide(pid: pid, windowID: windowID, frame: window.frame) else {
            return mover.lastFailure ?? "Could not hide the selected window (it may not be movable)."
        }

        let cgFrame = window.frame
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main)?.frame.height ?? cgFrame.maxY
        let center = CGPoint(x: cgFrame.midX, y: primaryHeight - cgFrame.midY)

        let overlay = OverlayWindow()
        overlay.place(unrotatedSize: cgFrame.size, center: center)
        overlay.onEscape = { [weak self] in
            guard let self, self.isRunning else { return }
            self.stop()
            self.onExternalStop?(self)
        }
        // The overlay's drag handle rotates the layer directly (no animation
        // needed while dragging); just keep our own state in sync so the menu
        // checkmarks and later spring transitions start from the right angle.
        overlay.onFreeRotate = { [weak self] degrees in
            self?.degrees = degrees
            self?.spinning = false
        }
        overlay.onFreeRotateEnd = { [weak self] degrees in
            self?.degrees = degrees
            self?.onChanged?()
        }
        overlay.onSpinStoppedByClick = { [weak self] degrees in
            guard let self else { return }
            self.degrees = degrees
            self.spinning = false
            self.onChanged?()
        }
        self.overlay = overlay
        applyRotation()
        overlay.orderFrontRegardless()
        isRunning = true

        Task { [weak self] in
            guard let self else { return }
            do {
                try await capture.start(window: window) { [weak self] surface in
                    self?.overlay?.update(surface: surface)
                }
            } catch {
                let reason = "Could not capture “\(title)”: \(error.localizedDescription)"
                NSLog("SpinWin: \(reason)")
                stop()
                onExternalStop?(self)
                onFailure?(reason)
            }
        }
        return nil
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        capture.stop()

        guard let overlay else {
            mover.restore()
            return
        }
        // Restore the source window wherever the overlay ended up (the user
        // may have dragged it while rotating/rotated) rather than snapping
        // back to where it was before rotation started. Computed now since
        // the spring-back-to-upright animation below doesn't move the
        // overlay's center, only its rotation.
        let targetPosition = restoredPosition(from: overlay)

        // Spring back to upright (stopping any spin) the same way rotation
        // is first applied, then swap back to the real window once the
        // overlay has visibly settled, instead of just vanishing.
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            overlay.orderOut(nil)
            if self.overlay === overlay { self.overlay = nil }
            self.mover.restore(to: targetPosition)
        }
        overlay.setFixed(degrees: 0)
        CATransaction.commit()
    }

    /// Re-hides the source window after a display change, which can otherwise
    /// pull it back into view alongside its own overlay.
    func repark() {
        guard isRunning else { return }
        mover.repark()
    }

    func setFixed(degrees: Double) {
        self.degrees = degrees
        spinning = false
        applyRotation()
    }

    func setSpin(rpm: Double) {
        self.rpm = rpm
        spinning = true
        applyRotation()
    }

    func setSpin(rpm: Double, direction: SpinDirection) {
        self.rpm = rpm
        self.spinDirection = direction
        spinning = true
        applyRotation()
    }

    /// Re-applies an activation choice to an already-running session (used when
    /// the same window is picked again).
    func apply(choice: ActivationChoice, direction: SpinDirection) {
        spinDirection = direction
        switch choice {
        case .angle(let degrees):
            setFixed(degrees: degrees)
        case .spin(let rpm):
            setSpin(rpm: rpm, direction: direction)
        case .free:
            // Keep the current angle; just make sure it isn't spinning so the
            // drag handle is available.
            setFixed(degrees: degrees)
        }
    }

    // MARK: - Private

    private func applyRotation() {
        guard let overlay else { return }
        if spinning {
            overlay.startSpin(rpm: rpm, direction: spinDirection)
        } else {
            overlay.setFixed(degrees: degrees)
        }
    }

    /// Converts the overlay's current center (Cocoa, bottom-left origin) back
    /// into the AX/CG position (top-left origin) the source window should be
    /// restored to, so it reappears wherever the user left the dragged proxy
    /// instead of snapping back to its pre-rotation spot.
    private func restoredPosition(from overlay: OverlayWindow) -> CGPoint {
        let cgFrame = window.frame
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main)?.frame.height ?? cgFrame.maxY
        let center = overlay.currentCenter
        return CGPoint(
            x: center.x - cgFrame.width / 2,
            y: primaryHeight - center.y - cgFrame.height / 2
        )
    }
}
