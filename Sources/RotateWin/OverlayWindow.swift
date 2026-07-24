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

    /// Renders the content at a fixed angle (any degree value).
    func setFixed(degrees: Double) {
        self.degrees = degrees
        spinning = false
        imageLayer.removeAnimation(forKey: "spin")

        let radians = degrees * .pi / 180
        let boxW = abs(unrotatedSize.width * cos(radians)) + abs(unrotatedSize.height * sin(radians))
        let boxH = abs(unrotatedSize.width * sin(radians)) + abs(unrotatedSize.height * cos(radians))

        applyGeometry(boxSize: CGSize(width: boxW, height: boxH))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.transform = CATransform3DMakeRotation(radians, 0, 0, 1)
        CATransaction.commit()
    }

    /// Continuously spins the content at the given revolutions per minute.
    func startSpin(rpm: Double) {
        self.rpm = rpm
        spinning = true

        // A square of side = the rectangle's diagonal contains it at every
        // angle, so nothing clips mid-spin.
        let diag = sqrt(unrotatedSize.width * unrotatedSize.width +
                        unrotatedSize.height * unrotatedSize.height)
        applyGeometry(boxSize: CGSize(width: diag, height: diag))

        imageLayer.transform = CATransform3DIdentity
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = 2 * Double.pi
        animation.duration = max(0.1, 60.0 / rpm)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        imageLayer.add(animation, forKey: "spin")
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
