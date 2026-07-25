import AppKit
import ScreenCaptureKit

/// A full-screen overlay that lets you click a window to select it, like the
/// macOS screenshot tool's window mode — including a bottom options band for
/// choosing the initial rotation (a preset angle, or free/manual rotation).
@MainActor
final class WindowPicker {
    private var pickerWindow: PickerWindow?
    private var completion: ((SCWindow?, ActivationChoice, SpinDirection) -> Void)?
    private var pendingChoice: ActivationChoice = .lastUsed
    private var pendingDirection: SpinDirection = .lastUsed
    /// True from the moment a pick starts until it finishes. Menubar buttons
    /// fire on every mouse-up, so a double-click would otherwise start a second
    /// pick and orphan the first shield window: nothing would hold a reference
    /// to order it out, leaving the screen permanently dimmed and unclickable.
    private var isPicking = false

    /// Whether a pick is in progress: the shield is up, or the window list is
    /// still being gathered before it goes up.
    var isActive: Bool { isPicking }

    /// Screen-coordinate regions that cancel the pick when clicked, used for the
    /// menubar icon. The shield sits above the menu bar and eats its clicks, so
    /// the status item never sees a second click of its own; the picker has to
    /// recognise the hit itself and back out.
    var cancelRegions: (() -> [NSRect])?

    func begin(completion: @escaping (SCWindow?, ActivationChoice, SpinDirection) -> Void) {
        guard !isPicking else { return }
        isPicking = true
        self.completion = completion
        self.pendingChoice = .lastUsed
        self.pendingDirection = .lastUsed
        Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let candidates = (content?.windows ?? []).filter {
                $0.owningApplication?.processID != ownPID &&
                $0.frame.width > 40 && $0.frame.height > 40
            }
            present(candidates: candidates)
        }
    }

    /// Abandons an in-progress pick exactly as Escape would. Note this can land
    /// while `begin` is still awaiting the window list, which is why `present`
    /// re-checks that the pick is still live before putting up the shield.
    func cancel() {
        guard isPicking else { return }
        finish(nil)
    }

    private func present(candidates: [SCWindow]) {
        guard isPicking else { return }
        guard !candidates.isEmpty else { finish(nil); return }

        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let window = PickerWindow(
            contentRect: union,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: union.size))

        let view = PickerView(frame: container.bounds)
        view.autoresizingMask = [.width, .height]
        view.candidates = candidates
        view.unionOrigin = union.origin
        view.onPick = { [weak self] window in self?.finish(window) }
        view.onCancel = { [weak self] in self?.finish(nil) }
        view.isCancelPoint = { [weak self] point in
            (self?.cancelRegions?() ?? []).contains { $0.contains(point) }
        }
        container.addSubview(view)

        let band = OptionsBandView(initialChoice: pendingChoice, initialDirection: pendingDirection)
        band.onSelect = { [weak self] choice in
            self?.pendingChoice = choice
            ActivationChoice.lastUsed = choice
        }
        band.onDirectionChange = { [weak self] direction in
            self?.pendingDirection = direction
            SpinDirection.lastUsed = direction
        }
        band.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(band)
        // Sit a fixed gap above the Dock rather than a fixed distance from the
        // screen edge, so a large Dock pushes the band up instead of hiding
        // behind it. Anchored to the Dock's own screen, which with multiple
        // displays is not necessarily the middle of the union.
        let anchor = Self.bandAnchor(in: union)
        NSLayoutConstraint.activate([
            band.centerXAnchor.constraint(equalTo: container.leadingAnchor, constant: anchor.centerX),
            band.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -anchor.bottomInset)
        ])

        window.contentView = container

        pickerWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        // Lay out first so the band knows its resting position, then spring it
        // in from there — otherwise the animation starts from a zero frame.
        container.layoutSubtreeIfNeeded()
        band.playEntranceAnimation()
    }

    /// Where the options band should sit, in `container` coordinates (origin at
    /// the bottom-left of the union of all screens).
    ///
    /// The band is placed relative to the Dock, not the screen edge: the gap is
    /// measured from the top of the Dock, so enlarging the Dock raises the band
    /// rather than letting the Dock cover it. With an auto-hidden Dock the
    /// thickness is zero and the gap falls back to the screen edge.
    private static func bandAnchor(in union: NSRect) -> (centerX: CGFloat, bottomInset: CGFloat) {
        let gap: CGFloat = 30

        // The screen that actually owns the Dock: a bottom Dock is the only
        // thing that insets visibleFrame from the bottom of frame.
        let dockScreen = NSScreen.screens.max { lhs, rhs in
            (lhs.visibleFrame.minY - lhs.frame.minY) < (rhs.visibleFrame.minY - rhs.frame.minY)
        }
        let screen = dockScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let dockThickness = max(0, screen.visibleFrame.minY - screen.frame.minY)

        return (
            centerX: screen.frame.midX - union.minX,
            bottomInset: (screen.frame.minY - union.minY) + dockThickness + gap
        )
    }

    private func finish(_ window: SCWindow?) {
        pickerWindow?.orderOut(nil)
        pickerWindow = nil
        isPicking = false
        let completion = self.completion
        self.completion = nil
        let choice = pendingChoice
        let direction = pendingDirection
        // Defer so the shield-level picker window is fully torn down before any
        // follow-up UI (e.g. an alert) appears; otherwise it can sit behind it.
        DispatchQueue.main.async { completion?(window, choice, direction) }
    }
}

/// Borderless window that can still become key so it receives Esc.
private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The floating "how should this rotate" control bar, styled like the
/// screenshot tool's bottom toolbar: preset angles plus a free-rotation
/// option, remembering the last choice as the default.
private final class OptionsBandView: NSView {
    var onSelect: ((ActivationChoice) -> Void)?
    var onDirectionChange: ((SpinDirection) -> Void)?
    private var buttons: [NSButton] = []
    private var directionButton: NSButton?
    private var direction: SpinDirection
    private var selectedChoice: ActivationChoice

    init(initialChoice: ActivationChoice, initialDirection: SpinDirection) {
        self.direction = initialDirection
        self.selectedChoice = initialChoice
        super.init(frame: .zero)
        // Layer-backed up front so the entrance animation has a layer with the
        // correct geometry once Auto Layout has positioned the band.
        wantsLayer = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 21
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        for choice in ActivationChoice.presets {
            // A thin divider between the angle, spin, and free clusters.
            if choice == ActivationChoice.spinPresets.first || choice == .free {
                stack.addView(Self.makeDivider(), in: .center)
            }
            let button = Self.makeButton(for: choice, target: self, action: #selector(tapped(_:)))
            buttons.append(button)
            stack.addView(button, in: .center)

            // The direction toggle belongs with the spin cluster, right after
            // its speed buttons.
            if choice == ActivationChoice.spinPresets.last {
                let toggle = Self.makeDirectionButton(target: self, action: #selector(directionTapped))
                directionButton = toggle
                stack.addView(toggle, in: .center)
            }
        }

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        select(initialChoice)
        updateDirectionButton()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Unfurls the band into place when the picker opens, as if it were poured
    /// up out of the Dock: it starts as a narrow pill directly below, then
    /// spreads horizontally and overshoots slightly before settling. Against the
    /// dimmed backdrop a static bar is easy to miss; the overshoot is the cue.
    func playEntranceAnimation() {
        guard let layer, layer.bounds.width > 1 else { return }

        // Respect the system setting: for anyone who has asked for less motion,
        // a plain fade conveys the same thing without the movement.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.22
            layer.add(fade, forKey: "entranceFade")
            return
        }

        // A view's backing layer is anchored at its bottom-left corner, and
        // AppKit resets anchorPoint/position on every commit, so they can't be
        // changed to move the scaling origin. Instead the transform itself
        // brackets the scale with translations to and from the center, which
        // makes it grow outward from the middle with the anchor left alone.
        let size = layer.bounds.size
        func centeredScale(x: CGFloat, y: CGFloat, rise: CGFloat) -> CATransform3D {
            var transform = CATransform3DMakeTranslation(0, rise, 0)
            transform = CATransform3DTranslate(transform, size.width / 2, size.height / 2, 0)
            transform = CATransform3DScale(transform, x, y, 1)
            return CATransform3DTranslate(transform, -size.width / 2, -size.height / 2, 0)
        }

        // Start at the width of a narrow spout. The band's 21pt corner radius
        // means that at this width it already reads as a rounded pill, so the
        // spread looks like one continuous pour.
        let pillWidth: CGFloat = 46
        let startScaleX = min(1, pillWidth / size.width)

        // Under-damped on purpose: the overshoot *is* the attention cue.
        let spread = CASpringAnimation(keyPath: "transform")
        spread.fromValue = NSValue(caTransform3D: centeredScale(x: startScaleX, y: 0.62, rise: -10))
        spread.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spread.mass = 1
        spread.stiffness = 220
        spread.damping = 13
        spread.initialVelocity = 0
        spread.duration = spread.settlingDuration
        spread.fillMode = .backwards
        layer.add(spread, forKey: "entranceSpread")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.14
        layer.add(fade, forKey: "entranceFade")
    }

    private static func makeButton(for choice: ActivationChoice, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: choice.label, target: target, action: action)
        if let symbolName = choice.symbolName {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: choice.tooltip)?
                .withSymbolConfiguration(config)
            button.image = image
            button.imagePosition = .imageLeading
        }
        button.tag = ActivationChoice.presets.firstIndex(of: choice) ?? 0
        button.bezelStyle = .rounded
        // pushOnPushOff gives a native, always-visible highlighted/pressed
        // look for the "on" state — plain rounded buttons paint their own
        // bezel over any custom background tint, which is why a manually
        // drawn "selected" background wasn't actually visible.
        button.setButtonType(.pushOnPushOff)
        button.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        button.toolTip = choice.tooltip
        return button
    }

    private static func makeDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return box
    }

    /// A single button that toggles between clockwise/counterclockwise for
    /// the spin presets, rather than two separate direction buttons.
    private static func makeDirectionButton(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: target, action: action)
        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        return button
    }

    @objc private func tapped(_ sender: NSButton) {
        guard ActivationChoice.presets.indices.contains(sender.tag) else { return }
        let choice = ActivationChoice.presets[sender.tag]
        select(choice)
        onSelect?(choice)
    }

    @objc private func directionTapped() {
        direction.toggle()
        updateDirectionButton()
        onDirectionChange?(direction)
    }

    private func updateDirectionButton() {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        directionButton?.image = NSImage(systemSymbolName: direction.symbolName, accessibilityDescription: direction.tooltip)?
            .withSymbolConfiguration(config)
        directionButton?.toolTip = direction.tooltip
        // Only relevant while a spin speed is selected.
        directionButton?.isEnabled = selectedChoice.initialSpinning
    }

    private func select(_ choice: ActivationChoice) {
        selectedChoice = choice
        for (index, button) in buttons.enumerated() {
            button.state = (ActivationChoice.presets[index] == choice) ? .on : .off
        }
        updateDirectionButton()
    }
}

/// Draws the dimmed backdrop, highlights the hovered window, and reports clicks.
private final class PickerView: NSView {
    var candidates: [SCWindow] = []
    var unionOrigin: CGPoint = .zero
    var onPick: ((SCWindow) -> Void)?
    var onCancel: (() -> Void)?
    var isCancelPoint: ((NSPoint) -> Bool)?

    private var hovered: SCWindow?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let window = windowUnderCursor()
        if window?.windowID != hovered?.windowID {
            hovered = window
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        if isCancelPoint?(NSEvent.mouseLocation) == true { onCancel?(); return }
        if let window = windowUnderCursor() { onPick?(window) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Esc
    }

    /// Returns the frontmost normal application window under the cursor.
    private func windowUnderCursor() -> SCWindow? {
        let cocoa = NSEvent.mouseLocation
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main)?.frame.height ?? 0
        let point = CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let byID = Dictionary(candidates.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })

        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // Front-to-back. Only layer 0 = ordinary app windows; this skips the
        // Dock/wallpaper, Stage Manager, menu bar, and Control Center.
        for info in infoList {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else { continue }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &bounds),
                  bounds.contains(point) else { continue }
            if let window = byID[id] { return window }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.25)

        guard let hovered else {
            dim.setFill()
            bounds.fill()
            drawHint()
            return
        }

        // Dim everything except the hovered window (four surrounding bands),
        // then tint + outline it so it clearly reads as selected.
        let rect = viewRect(for: hovered.frame).intersection(bounds)
        dim.setFill()
        NSBezierPath(rect: NSRect(x: bounds.minX, y: rect.maxY, width: bounds.width, height: bounds.maxY - rect.maxY)).fill()
        NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: rect.minY - bounds.minY)).fill()
        NSBezierPath(rect: NSRect(x: bounds.minX, y: rect.minY, width: rect.minX - bounds.minX, height: rect.height)).fill()
        NSBezierPath(rect: NSRect(x: rect.maxX, y: rect.minY, width: bounds.maxX - rect.maxX, height: rect.height)).fill()

        NSColor.controlAccentColor.withAlphaComponent(0.06).setFill()
        rect.fill()

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        border.stroke()

        drawHint()
    }

    private func drawHint() {
        let text = "Click a window to rotate   ·   Esc to cancel" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 80)
        let pad: CGFloat = 10
        let bg = NSRect(x: point.x - pad, y: point.y - pad / 2,
                        width: size.width + pad * 2, height: size.height + pad)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        text.draw(at: point, withAttributes: attrs)
    }

    /// Converts a window's CoreGraphics (top-left) frame to this view's coords.
    private func viewRect(for cgFrame: CGRect) -> NSRect {
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main)?.frame.height ?? 0
        let cocoaGlobal = NSRect(
            x: cgFrame.minX,
            y: primaryHeight - cgFrame.maxY,
            width: cgFrame.width,
            height: cgFrame.height
        )
        return cocoaGlobal.offsetBy(dx: -unionOrigin.x, dy: -unionOrigin.y)
    }
}
