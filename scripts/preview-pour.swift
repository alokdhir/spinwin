// Standalone preview for the options-bar "pour" entrance animation.
// Not part of the app: run it directly, watch, tune, quit.
//
//   swift scripts/preview-pour.swift
//
// Keys:
//   1-5          pick a variant (damping/stiffness/spout presets)
//   d            cycle simulated Dock thickness (incl. hidden + huge)
//   left/right   damping -/+        up/down   pour gap (rise) -/+
//   [ ]          stiffness -/+      space     replay now
//   r            toggle Reduce Motion fallback (plain fade)
//   q / esc      quit
//
// The animation loops so you can just watch it. Current values print to the
// HUD and to stdout, so you can tell the agent exactly what you settled on.
import AppKit
import QuartzCore

// MARK: - Config

struct Variant {
    let name: String
    let stiffness: CGFloat
    let damping: CGFloat
    let showSpout: Bool
    let pour: CFTimeInterval
}

let variants: [Variant] = [
    Variant(name: "Subtle",   stiffness: 220, damping: 18, showSpout: true,  pour: 0.16),
    Variant(name: "Balanced", stiffness: 220, damping: 13, showSpout: true,  pour: 0.16),
    Variant(name: "Bouncy",   stiffness: 220, damping: 9,  showSpout: true,  pour: 0.16),
    Variant(name: "No spout", stiffness: 220, damping: 13, showSpout: false, pour: 0.0),
    Variant(name: "Snappy",   stiffness: 340, damping: 15, showSpout: true,  pour: 0.10),
]

// Simulated Dock thicknesses (screen.frame.minY -> visibleFrame.minY):
// 0 = autohidden, 41 = small tiles, 61 = the machine's current Dock,
// 96/141 = large tiles. The pour must look right at every one of these.
let dockThicknesses: [CGFloat] = [0, 41, 61, 96, 141]

let bandCorner: CGFloat = 21
let bandHeight: CGFloat = 58
let spoutWidth: CGFloat = 46

// Button strip layout, measured once so the band is sized to fit its content
// rather than a guessed width (which left the last button hanging off the end).
struct FakeButton {
    let label: String
    let x: CGFloat
    let width: CGFloat
    let isDivider: Bool
}

let (fakeButtons, bandWidth): ([FakeButton], CGFloat) = {
    let labels = ["90°", "180°", "270°", "|", "6", "15", "30", "↻", "|", "Free"]
    var result: [FakeButton] = []
    var x: CGFloat = 16
    for label in labels {
        if label == "|" {
            result.append(FakeButton(label: label, x: x, width: 1, isDivider: true))
            x += 13
            continue
        }
        let width: CGFloat = label == "Free" ? 58 : (label.count > 2 ? 46 : 38)
        result.append(FakeButton(label: label, x: x, width: width, isDivider: false))
        x += width + 8
    }
    return (result, x - 8 + 16)
}()

let bandSize = CGSize(width: bandWidth, height: bandHeight)

// MARK: - Preview view

// NOTE: this preview draws the band as a raw CALayer, which anchors at its
// center. A real NSView's backing layer anchors at its bottom-left instead, so
// the shipping code must re-anchor before scaling or the bar expands rightward
// from its left edge rather than opening from the middle.
final class PourPreviewView: NSView {
    private let dock = CALayer()
    private let dockDivider = CALayer()
    private let band = CALayer()
    private let spout = CAShapeLayer()
    private let hud = CATextLayer()

    private var variantIndex = 1
    private var dockIndex = 2
    private var gap: CGFloat = 30          // distance poured, dock top -> band bottom
    private var dampingOverride: CGFloat?
    private var stiffnessOverride: CGFloat?
    private var reduceMotion = false
    private var timer: Timer?

    private var variant: Variant { variants[variantIndex] }
    private var damping: CGFloat { dampingOverride ?? variant.damping }
    private var stiffness: CGFloat { stiffnessOverride ?? variant.stiffness }
    private var dockThickness: CGFloat { dockThicknesses[dockIndex] }

    /// Top edge of the Dock in view coords; the pour always starts here.
    private var dockTop: CGFloat { dockThickness }
    /// Band's resting bottom edge: a fixed gap above the Dock, so a taller
    /// Dock pushes the whole band higher instead of overlapping it.
    private var bandBottom: CGFloat { dockTop + gap }
    private var bandCenterY: CGFloat { bandBottom + bandSize.height / 2 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        buildFakeDesktop()
        buildDock()
        buildBand()
        buildSpout()
        buildHUD()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Scenery

    /// A couple of fake app windows plus a dim wash, so the band is judged
    /// against the same busy/dimmed backdrop the real picker has.
    private func buildFakeDesktop() {
        for rect in [CGRect(x: 180, y: 380, width: 720, height: 480),
                     CGRect(x: 760, y: 240, width: 640, height: 560),
                     CGRect(x: 1180, y: 460, width: 560, height: 420)] {
            let win = CALayer()
            win.frame = rect
            win.cornerRadius = 10
            win.backgroundColor = NSColor(calibratedWhite: 0.42, alpha: 1).cgColor
            win.borderColor = NSColor(calibratedWhite: 0.6, alpha: 0.5).cgColor
            win.borderWidth = 1
            layer?.addSublayer(win)
        }
        let dim = CALayer()
        dim.frame = bounds
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        layer?.addSublayer(dim)
    }

    private func buildDock() {
        dock.backgroundColor = NSColor(calibratedWhite: 0.30, alpha: 0.92).cgColor
        dock.borderColor = NSColor(calibratedWhite: 0.75, alpha: 0.30).cgColor
        dock.borderWidth = 1
        layer?.addSublayer(dock)

        // Marks the Dock's top edge, the line the pour emerges through.
        dockDivider.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.5).cgColor
        layer?.addSublayer(dockDivider)
    }

    private func buildBand() {
        band.bounds = CGRect(origin: .zero, size: bandSize)
        band.cornerRadius = bandCorner
        band.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 0.92).cgColor
        band.borderColor = NSColor(calibratedWhite: 0.8, alpha: 0.22).cgColor
        band.borderWidth = 1
        band.opacity = 0
        band.shadowColor = NSColor.black.cgColor
        band.shadowOpacity = 0.45
        band.shadowRadius = 18
        band.shadowOffset = CGSize(width: 0, height: -6)
        layer?.addSublayer(band)
        addFakeButtons(to: band)
    }

    /// Mirrors the real band's content (angle presets | spin speeds + direction
    /// | free) so the width and visual weight match what ships.
    private func addFakeButtons(to host: CALayer) {
        for item in fakeButtons {
            if item.isDivider {
                let divider = CALayer()
                divider.frame = CGRect(x: item.x, y: (bandHeight - 26) / 2, width: 1, height: 26)
                divider.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.25).cgColor
                host.addSublayer(divider)
                continue
            }
            let button = CALayer()
            button.frame = CGRect(x: item.x, y: (bandHeight - 32) / 2, width: item.width, height: 32)
            button.cornerRadius = 7
            button.backgroundColor = NSColor(calibratedWhite: 0.42, alpha: 0.9).cgColor
            host.addSublayer(button)

            let text = CATextLayer()
            text.string = item.label
            text.fontSize = 14
            text.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            text.alignmentMode = .center
            text.foregroundColor = NSColor.white.cgColor
            text.contentsScale = 2
            text.frame = CGRect(x: 0, y: (32 - 18) / 2, width: item.width, height: 18)
            button.addSublayer(text)
        }
    }

    /// An actual spout shape, not a rectangle: wide where it leaves the Dock,
    /// tapering as it rises, with concave sides so it reads as a stream of
    /// liquid being drawn upward. Anchored at its bottom edge so scaling y
    /// grows it up out of the Dock instead of from its middle.
    private func buildSpout() {
        spout.anchorPoint = CGPoint(x: 0.5, y: 0)
        spout.fillColor = NSColor(calibratedWhite: 0.30, alpha: 0.95).cgColor
        spout.strokeColor = NSColor(calibratedWhite: 0.85, alpha: 0.30).cgColor
        spout.lineWidth = 1
        spout.opacity = 0
        layer?.addSublayer(spout)
    }

    /// Tapered stream, narrow where it leaves the Dock and flaring where it
    /// feeds the bar: liquid drawn *upward* is pinched at its source and widens
    /// as it spreads into what it's filling. Sides curve inward (concave) so it
    /// reads as a stream under tension rather than a solid wedge.
    private func spoutPath(height: CGFloat) -> CGPath {
        let bottom = spoutWidth * 0.42
        let top = spoutWidth
        let path = CGMutablePath()
        // Slight lip below zero so the base is hidden inside the Dock surface.
        path.move(to: CGPoint(x: -bottom / 2, y: -2))
        path.addCurve(
            to: CGPoint(x: -top / 2, y: height),
            control1: CGPoint(x: -bottom / 2, y: height * 0.55),
            control2: CGPoint(x: -top / 2, y: height * 0.72)
        )
        // Rounded meniscus bulging up into the bar it is filling.
        path.addQuadCurve(
            to: CGPoint(x: top / 2, y: height),
            control: CGPoint(x: 0, y: height + top * 0.22)
        )
        path.addCurve(
            to: CGPoint(x: bottom / 2, y: -2),
            control1: CGPoint(x: top / 2, y: height * 0.72),
            control2: CGPoint(x: bottom / 2, y: height * 0.55)
        )
        path.closeSubpath()
        return path
    }

    private func buildHUD() {
        hud.fontSize = 13
        hud.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        hud.foregroundColor = NSColor.white.cgColor
        hud.contentsScale = 2
        hud.isWrapped = true
        layer?.addSublayer(hud)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layer?.sublayers?.first(where: { $0.bounds.size == bounds.size })?.frame = bounds

        let dockWidth: CGFloat = min(bounds.width - 200, 60 + dockThickness * 11)
        dock.frame = CGRect(x: (bounds.width - dockWidth) / 2, y: 0,
                            width: dockWidth, height: max(dockThickness, 0))
        dock.cornerRadius = dockThickness > 0 ? 16 : 0
        dock.isHidden = dockThickness == 0

        dockDivider.frame = CGRect(x: bounds.midX - 200, y: dockTop, width: 400, height: 1)

        band.position = CGPoint(x: bounds.midX, y: bandCenterY)
        // Spans exactly the poured gap, so its top lands on the band's bottom.
        spout.bounds = CGRect(x: -spoutWidth / 2, y: 0, width: spoutWidth, height: max(gap, 1))
        spout.path = spoutPath(height: max(gap, 1))
        spout.position = CGPoint(x: bounds.midX, y: dockTop)

        hud.frame = CGRect(x: 40, y: bounds.height - 190, width: 720, height: 150)
        CATransaction.commit()
        updateHUD()
    }

    private func updateHUD() {
        let dockLabel = dockThickness == 0 ? "hidden" : "\(Int(dockThickness))pt"
        let text = """
        SpinWin — options bar "pour" preview        \(reduceMotion ? "[REDUCE MOTION: plain fade]" : "")

        variant   \(variantIndex + 1)  \(variant.name)\(variant.showSpout ? "" : "  (band only)")
        stiffness \(Int(stiffness))        damping \(String(format: "%.0f", damping))
        dock      \(dockLabel)      pour gap \(Int(gap))pt      band bottom at y=\(Int(bandBottom))

        1-5 variant   d dock   ←/→ damping   ↑/↓ gap   [ ] stiffness   space replay   r reduce-motion   q quit
        """
        hud.string = text
        print("variant=\(variant.name) stiffness=\(Int(stiffness)) damping=\(Int(damping)) dock=\(dockLabel) gap=\(Int(gap))")
    }

    // MARK: Animation

    func startLoop() {
        play()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: true) { [weak self] _ in
            self?.play()
        }
    }

    func play() {
        band.removeAllAnimations()
        spout.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.opacity = 0
        spout.opacity = 0
        CATransaction.commit()

        if reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.22
            fade.fillMode = .both
            fade.isRemovedOnCompletion = false
            band.add(fade, forKey: "fade")
            return
        }

        let start = CACurrentMediaTime()
        let pour = variant.showSpout ? variant.pour : 0
        if variant.showSpout { animateSpout(start: start, pour: pour) }
        animateBand(start: start + pour)
    }

    /// Liquid rises out of the Dock, then is swallowed up into the finished bar.
    /// The stream's `path` is animated (rather than scaling y) so the taper keeps
    /// its true shape instead of being stretched thin as it grows.
    private func animateSpout(start: CFTimeInterval, pour: CFTimeInterval) {
        let hold: CFTimeInterval = 0.10
        let swallow: CFTimeInterval = 0.26
        let total = pour + hold + swallow
        let t1 = pour / total
        let t2 = (pour + hold) / total
        let full = max(gap, 1)

        let grow = CAKeyframeAnimation(keyPath: "path")
        grow.values = [
            spoutPath(height: 1),
            spoutPath(height: full),
            spoutPath(height: full),
            spoutPath(height: 1),
        ]
        grow.keyTimes = [0, NSNumber(value: t1), NSNumber(value: t2), 1]
        grow.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeIn),
        ]

        // Rising position + shrinking height together keep the top edge pinned
        // to the bar, so it reads as being absorbed rather than falling back.
        let rise = CAKeyframeAnimation(keyPath: "position.y")
        rise.values = [dockTop, dockTop, dockTop, bandBottom]
        rise.keyTimes = [0, NSNumber(value: t1), NSNumber(value: t2), 1]

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: t1 * 0.6), NSNumber(value: t2), 1]

        for animation in [grow, rise, fade] {
            animation.duration = total
            animation.beginTime = start
            animation.fillMode = .backwards
            spout.add(animation, forKey: animation.keyPath)
        }
    }

    /// The bar unfurls horizontally out of the spout's width: at 12% scale it is
    /// already a narrow pill (corner radius 21 on a 58pt-tall box), so the
    /// silhouettes line up and it looks like one continuous pour.
    private func animateBand(start: CFTimeInterval) {
        func spring(_ keyPath: String, from: CGFloat, to: CGFloat) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.mass = 1
            animation.stiffness = stiffness
            animation.damping = damping
            animation.initialVelocity = 0
            animation.duration = animation.settlingDuration
            animation.beginTime = start
            animation.fillMode = .backwards
            animation.isRemovedOnCompletion = false
            return animation
        }

        band.add(spring("transform.scale.x", from: spoutWidth / bandSize.width, to: 1), forKey: "scaleX")
        band.add(spring("transform.scale.y", from: 0.62, to: 1), forKey: "scaleY")
        band.add(spring("position.y", from: bandCenterY - 10, to: bandCenterY), forKey: "riseY")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.14
        fade.beginTime = start
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        band.add(fade, forKey: "fade")
    }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        switch event.keyCode {
        case 53: NSApp.terminate(nil); return               // esc
        case 123: dampingOverride = max(3, damping - 1)     // left
        case 124: dampingOverride = min(40, damping + 1)    // right
        case 126: gap = min(160, gap + 4)                   // up
        case 125: gap = max(8, gap - 4)                     // down
        default:
            switch characters.lowercased() {
            case "q": NSApp.terminate(nil); return
            case "d": dockIndex = (dockIndex + 1) % dockThicknesses.count
            case "[": stiffnessOverride = max(40, stiffness - 20)
            case "]": stiffnessOverride = min(900, stiffness + 20)
            case "r": reduceMotion.toggle()
            case " ": play(); return
            case "1", "2", "3", "4", "5":
                variantIndex = Int(characters)! - 1
                dampingOverride = nil
                stiffnessOverride = nil
            default: return
            }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        play()
    }
}

// MARK: - Boot

/// Borderless windows refuse key status by default, which silently swallows
/// every keystroke. The app's own PickerWindow overrides this for the same
/// reason.
final class PreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let screenFrame = (NSScreen.main ?? NSScreen.screens[0]).frame
let window = PreviewWindow(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
window.level = .floating
window.backgroundColor = .black
window.isOpaque = true

let view = PourPreviewView(frame: NSRect(origin: .zero, size: screenFrame.size))
window.contentView = view
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)
view.startLoop()
app.run()
