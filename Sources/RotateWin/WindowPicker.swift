import AppKit
import ScreenCaptureKit

/// A full-screen overlay that lets you click a window to select it, like the
/// macOS screenshot tool's window mode — including a bottom options band for
/// choosing the initial rotation (a preset angle, or free/manual rotation).
@MainActor
final class WindowPicker {
    private var pickerWindow: PickerWindow?
    private var completion: ((SCWindow?, ActivationChoice) -> Void)?
    private var pendingChoice: ActivationChoice = .lastUsed

    func begin(completion: @escaping (SCWindow?, ActivationChoice) -> Void) {
        self.completion = completion
        self.pendingChoice = .lastUsed
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

    private func present(candidates: [SCWindow]) {
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
        container.addSubview(view)

        let band = OptionsBandView(initialChoice: pendingChoice)
        band.onSelect = { [weak self] choice in
            self?.pendingChoice = choice
            ActivationChoice.lastUsed = choice
        }
        band.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(band)
        NSLayoutConstraint.activate([
            band.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            band.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -36)
        ])

        window.contentView = container

        pickerWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    private func finish(_ window: SCWindow?) {
        pickerWindow?.orderOut(nil)
        pickerWindow = nil
        let completion = self.completion
        self.completion = nil
        let choice = pendingChoice
        // Defer so the shield-level picker window is fully torn down before any
        // follow-up UI (e.g. an alert) appears; otherwise it can sit behind it.
        DispatchQueue.main.async { completion?(window, choice) }
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
    private var buttons: [NSButton] = []

    init(initialChoice: ActivationChoice) {
        super.init(frame: .zero)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        for choice in ActivationChoice.presets {
            let button = Self.makeButton(for: choice, target: self, action: #selector(tapped(_:)))
            buttons.append(button)
            stack.addView(button, in: .center)
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private static func makeButton(for choice: ActivationChoice, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: choice.label, target: target, action: action)
        if case .free = choice, let image = NSImage(systemSymbolName: choice.symbolName, accessibilityDescription: choice.tooltip) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        button.tag = ActivationChoice.presets.firstIndex(of: choice) ?? 0
        button.bezelStyle = .rounded
        button.toolTip = choice.tooltip
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        return button
    }

    @objc private func tapped(_ sender: NSButton) {
        guard ActivationChoice.presets.indices.contains(sender.tag) else { return }
        let choice = ActivationChoice.presets[sender.tag]
        select(choice)
        onSelect?(choice)
    }

    private func select(_ choice: ActivationChoice) {
        for (index, button) in buttons.enumerated() {
            let isSelected = ActivationChoice.presets[index] == choice
            button.contentTintColor = isSelected ? .controlAccentColor : nil
            button.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                : NSColor.clear.cgColor
        }
    }
}

/// Draws the dimmed backdrop, highlights the hovered window, and reports clicks.
private final class PickerView: NSView {
    var candidates: [SCWindow] = []
    var unionOrigin: CGPoint = .zero
    var onPick: ((SCWindow) -> Void)?
    var onCancel: (() -> Void)?

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
