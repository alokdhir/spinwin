import AppKit

/// A borderless, transparent window that draws the captured frames at an
/// arbitrary rotation (or continuously spinning) on top of where the real
/// (now hidden) window used to be. Drag it anywhere to reposition.
final class OverlayWindow: NSWindow, NSWindowDelegate {
    private let imageLayer = CALayer()
    private var unrotatedSize: CGSize = .zero
    /// Current on-screen center (Cocoa coords); updated as the user drags.
    private var center: CGPoint = .zero

    // Last-applied rotation state, reapplied after drags/resizes.
    private var degrees: Double = 180
    private var spinning = false
    private var rpm: Double = 15
    /// Unwrapped (not mod-360) radians actually applied to the layer, so
    /// repeated rotations keep spinning the same direction instead of
    /// snapping back through 0, and transitions always take the shortest turn.
    private var currentRotationRadians: CGFloat = 0

    /// Called when Escape is pressed while this overlay is the key window.
    var onEscape: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Normal level (not .floating) so it follows regular front/back
        // ordering: other apps' windows can come to the front over it. A
        // floating level would always stay above every app, blocking clicks
        // through to whatever is underneath.
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        isMovableByWindowBackground = true
        delegate = self

        let hosting = NSView()
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        imageLayer.contentsGravity = .resize
        // Render on a background thread so a slow frame never stalls the UI.
        imageLayer.drawsAsynchronously = true
        hosting.layer?.addSublayer(imageLayer)
        contentView = hosting
    }

    /// Sets the source size and initial position. Call once when starting.
    func place(unrotatedSize: CGSize, center: CGPoint) {
        self.unrotatedSize = unrotatedSize
        self.center = center
    }

    func update(surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = surface
        CATransaction.commit()
    }

    /// Renders the content at a fixed angle (any degree value), animating
    /// from the current angle with a slight ease-out overshoot/bounce settle
    /// rather than snapping instantly.
    func setFixed(degrees: Double) {
        self.degrees = degrees

        // Always use the diagonal-square footprint (same as spin) so the
        // overshoot mid-bounce never clips, regardless of start/end angle.
        applyGeometry(boxSize: diagonalBoxSize)

        // If we were mid-spin, continue smoothly from wherever it visually
        // was rather than snapping back to the stale (identity) model value.
        if spinning, let presented = imageLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat {
            currentRotationRadians = presented
        }
        spinning = false
        imageLayer.removeAnimation(forKey: "spin")

        let targetRadians = CGFloat(degrees * .pi / 180)
        let delta = Self.shortestDelta(from: currentRotationRadians, to: targetRadians)
        let newRotationRadians = currentRotationRadians + delta

        let animation = CASpringAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = currentRotationRadians
        animation.toValue = newRotationRadians
        animation.mass = 1
        animation.stiffness = 180
        animation.damping = 14
        animation.initialVelocity = 0
        animation.duration = animation.settlingDuration

        imageLayer.removeAnimation(forKey: "rotate")
        imageLayer.transform = CATransform3DMakeRotation(newRotationRadians, 0, 0, 1)
        imageLayer.add(animation, forKey: "rotate")

        currentRotationRadians = newRotationRadians
    }

    /// Continuously spins the content at the given revolutions per minute,
    /// continuing smoothly from whatever angle is currently showing.
    func startSpin(rpm: Double) {
        self.rpm = rpm
        applyGeometry(boxSize: diagonalBoxSize)

        if !spinning, let presented = imageLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat {
            currentRotationRadians = presented
        }
        spinning = true
        imageLayer.removeAnimation(forKey: "rotate")

        let start = currentRotationRadians
        imageLayer.transform = CATransform3DMakeRotation(start, 0, 0, 1)

        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = start
        animation.toValue = start + 2 * Double.pi
        animation.duration = max(0.1, 60.0 / rpm)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        imageLayer.add(animation, forKey: "spin")
    }

    /// Bounding box (in points) large enough to contain the unrotated content
    /// at any angle, including mid-bounce overshoot.
    private var diagonalBoxSize: CGSize {
        let diag = sqrt(unrotatedSize.width * unrotatedSize.width +
                        unrotatedSize.height * unrotatedSize.height)
        return CGSize(width: diag, height: diag)
    }

    /// Shortest signed angular step (radians, in (-π, π]) from `from`
    /// (mod 2π) to `to`, so callers can add it to an *unwrapped* running
    /// angle and always take the short way round.
    private static func shortestDelta(from: CGFloat, to: CGFloat) -> CGFloat {
        let twoPi = CGFloat.pi * 2
        var delta = (to - from).truncatingRemainder(dividingBy: twoPi)
        if delta > .pi { delta -= twoPi }
        if delta < -.pi { delta += twoPi }
        return delta
    }

    private func applyGeometry(boxSize: CGSize) {
        let origin = CGPoint(
            x: center.x - boxSize.width / 2,
            y: center.y - boxSize.height / 2
        )
        setFrame(NSRect(origin: origin, size: boxSize), display: true)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = CGRect(origin: .zero, size: unrotatedSize)
        imageLayer.position = CGPoint(x: boxSize.width / 2, y: boxSize.height / 2)
        CATransaction.commit()
    }

    // MARK: - NSWindowDelegate

    /// Keep our logical center in sync when the user drags the overlay so
    /// later rotation changes stay anchored where they left it.
    func windowDidMove(_ notification: Notification) {
        center = CGPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: - Key handling

    /// Allow the overlay to take key focus (e.g. after a click) so it can
    /// receive Escape to stop rotating. It carries no controls, so this only
    /// costs a focus ring-free activation.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
