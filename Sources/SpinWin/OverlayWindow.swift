import AppKit

/// A borderless, transparent window that draws the captured frames at an
/// arbitrary rotation (or continuously spinning) on top of where the real
/// (now hidden) window used to be. Drag the background to reposition; drag
/// the small handle to rotate freely to any angle.
final class OverlayWindow: NSWindow, NSWindowDelegate {
    private let imageLayer = CALayer()
    private let handle = RotationHandleView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
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
    /// Called continuously while the rotation handle is dragged (degrees).
    var onFreeRotate: ((Double) -> Void)?
    /// Called once the handle drag ends, so callers can trigger a settle.
    var onFreeRotateEnd: ((Double) -> Void)?
    /// Called when the background is clicked (not dragged) while spinning,
    /// with the angle (degrees) it froze at.
    var onSpinStoppedByClick: ((Double) -> Void)?

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
        // Dragging is now handled manually by BackgroundDragView (so a plain
        // click, as opposed to a drag, can be distinguished and used to stop
        // a spin) rather than via the automatic background-drag machinery.
        isMovableByWindowBackground = false
        delegate = self

        let container = NSView()

        let hosting = BackgroundDragView()
        hosting.owner = self
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        imageLayer.contentsGravity = .resize
        // Render on a background thread so a slow frame never stalls the UI.
        imageLayer.drawsAsynchronously = true
        hosting.layer?.addSublayer(imageLayer)

        container.addSubview(hosting)
        container.addSubview(handle) // added after -> hit-tested first
        contentView = container

        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]

        handle.owner = self
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

        imageLayer.removeAnimation(forKey: "rotate")

        // No meaningful turn (e.g. freezing a spin in place): set it directly
        // instead of adding a spring that would animate nothing.
        if abs(delta) < 0.0001 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.transform = CATransform3DMakeRotation(newRotationRadians, 0, 0, 1)
            CATransaction.commit()
        } else {
            let animation = CASpringAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = currentRotationRadians
            animation.toValue = newRotationRadians
            animation.mass = 1
            animation.stiffness = 180
            animation.damping = 14
            animation.initialVelocity = 0
            animation.duration = animation.settlingDuration
            imageLayer.transform = CATransform3DMakeRotation(newRotationRadians, 0, 0, 1)
            imageLayer.add(animation, forKey: "rotate")
        }

        currentRotationRadians = newRotationRadians
        handle.isHidden = false
        updateHandlePosition()
    }

    /// Sets the angle directly with no animation, for continuous handle
    /// dragging (each intermediate value would otherwise fight the spring).
    func setFixedImmediate(degrees: Double) {
        self.degrees = degrees
        spinning = false
        imageLayer.removeAnimation(forKey: "spin")
        imageLayer.removeAnimation(forKey: "rotate")
        applyGeometry(boxSize: diagonalBoxSize)

        let radians = CGFloat(degrees * .pi / 180)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.transform = CATransform3DMakeRotation(radians, 0, 0, 1)
        CATransaction.commit()
        currentRotationRadians = radians
        updateHandlePosition()
    }

    /// Continuously spins the content at the given revolutions per minute,
    /// continuing smoothly from whatever angle is currently showing.
    func startSpin(rpm: Double, direction: SpinDirection) {
        self.rpm = rpm
        applyGeometry(boxSize: diagonalBoxSize)

        if !spinning, let presented = imageLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat {
            currentRotationRadians = presented
        }
        spinning = true
        imageLayer.removeAnimation(forKey: "rotate")
        handle.isHidden = true // dragging a handle mid-spin has no fixed target

        let start = currentRotationRadians
        imageLayer.transform = CATransform3DMakeRotation(start, 0, 0, 1)

        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = start
        animation.toValue = start + direction.signedTurn * 2 * Double.pi
        animation.duration = max(0.1, 60.0 / rpm)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        imageLayer.add(animation, forKey: "spin")
    }

    /// Stops a continuous spin at whatever angle it's currently showing,
    /// freezing in place (no further animation) rather than snapping to a
    /// preset. Returns the angle it froze at, or nil if not spinning.
    @discardableResult
    func stopSpin() -> Double? {
        guard spinning else { return nil }
        let presented = (imageLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat)
            ?? currentRotationRadians
        let presentedDegrees = Double(presented * 180 / .pi)
        setFixed(degrees: presentedDegrees) // from == to at the presented value: locks in place, no bounce
        return presentedDegrees
    }

    /// Repositions the overlay (used for manual background dragging).
    func moveTo(origin: CGPoint) {
        setFrameOrigin(origin)
    }

    var currentOrigin: CGPoint { frame.origin }

    /// Current logical center (Cocoa coords), tracking wherever the user has
    /// dragged the overlay, independent of the box/handle geometry around it.
    var currentCenter: CGPoint { center }

    fileprivate func backgroundWasClicked() {
        if let degrees = stopSpin() {
            onSpinStoppedByClick?(degrees)
        }
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

    /// Moves the drag handle to just outside the content's current "top"
    /// (rotating with it), so it always affords grabbing to adjust further.
    private func updateHandlePosition() {
        let margin: CGFloat = 22
        let theta = currentRotationRadians
        let radius = unrotatedSize.height / 2 + margin
        let dx = -radius * sin(theta)
        let dy = radius * cos(theta)
        let size = handle.frame.width
        handle.frame.origin = CGPoint(
            x: frame.width / 2 + dx - size / 2,
            y: frame.height / 2 + dy - size / 2
        )
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

    // AppKit's default -setFrame:display: (used by applyGeometry) silently
    // constrains the proposed frame to keep the window mostly on-screen,
    // which is exactly what stopped drags a short way past the top edge.
    // Disable that entirely so the window can hang off any edge as far as
    // the user drags it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosts the captured content and distinguishes a plain click (stops a spin)
/// from a drag (repositions the overlay), replacing the automatic
/// isMovableByWindowBackground behavior so the two can be told apart.
private final class BackgroundDragView: NSView {
    weak var owner: OverlayWindow?

    private var totalMovement: CGFloat = 0
    private var didDrag = false
    private var pointerDetached = false
    private static let dragThreshold: CGFloat = 4

    override var mouseDownCanMoveWindow: Bool { false }

    // Without this, the first click while the overlay isn't yet key is
    // consumed just to activate/focus it (standard AppKit "click-through"
    // behavior) and never reaches mouseDown at all — exactly why the handle
    // and background needed a second click/drag to do anything.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        totalMovement = 0
        didDrag = false
        pointerDetached = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let owner else { return }
        totalMovement += hypot(event.deltaX, event.deltaY)
        if !didDrag, totalMovement > Self.dragThreshold {
            didDrag = true
            // Detach + hide the cursor for the rest of the drag. The window
            // then tracks raw motion deltas (which, unlike the cursor, aren't
            // clamped to the screen edge, so it can hang off any edge), and
            // with no visible cursor there's nothing to appear to "drift".
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
            pointerDetached = true
        }
        if didDrag {
            let current = owner.currentOrigin
            owner.moveTo(origin: CGPoint(x: current.x + event.deltaX, y: current.y - event.deltaY))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            owner?.backgroundWasClicked()
        }
        if pointerDetached {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
            pointerDetached = false
        }
        didDrag = false
    }
}

/// Small draggable knob that rotates the overlay to whatever angle the mouse
/// currently makes with the window's center, for arbitrary/free rotation.
private final class RotationHandleView: NSView {
    weak var owner: OverlayWindow?
    private var lastDegrees: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = frameRect.width / 2
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 2
        toolTip = "Drag to rotate freely"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    // The window's isMovableByWindowBackground otherwise treats a mouseDown
    // here as a background-drag trigger (checked independently of whether we
    // override mouseDown), which is why dragging the handle was moving the
    // whole window instead of rotating.
    override var mouseDownCanMoveWindow: Bool { false }

    // Without this, the first click/drag while the overlay isn't yet key is
    // consumed just to activate it and never reaches mouseDown/mouseDragged —
    // why the handle needed a second attempt to actually rotate anything.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Just needs to be recognized so mouseDragged fires; no state to set.
    }

    override func mouseDragged(with event: NSEvent) {
        guard let owner else { return }
        let point = event.locationInWindow
        let dx = point.x - owner.frame.width / 2
        let dy = point.y - owner.frame.height / 2
        // Angle from the window's "up" direction, matching the CCW rotation
        // convention used for the content layer.
        let theta = -atan2(dx, dy)
        let degrees = Double(theta * 180 / .pi)
        lastDegrees = degrees
        owner.setFixedImmediate(degrees: degrees)
        owner.onFreeRotate?(degrees)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.onFreeRotateEnd?(lastDegrees)
    }
}
