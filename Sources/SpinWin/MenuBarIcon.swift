import AppKit

/// Draws the menubar status item icon: a hollow (outlined) square rotated
/// 30°. No arrow/symbol — just the shape, rendered as a template image so
/// macOS tints it correctly for the light/dark menu bar and menu-open states.
enum MenuBarIcon {
    static func make(
        canvasSize: CGFloat = 18,
        squareSide: CGFloat = 12,
        degrees: CGFloat = 30,
        lineWidth: CGFloat = 1.6
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: canvasSize, height: canvasSize), flipped: false) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            context.saveGraphicsState()

            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: degrees)
            transform.concat()

            // Inset by half the stroke width so the outline doesn't get
            // clipped by the canvas at any rotation.
            let side = squareSide - lineWidth
            let square = NSRect(x: -side / 2, y: -side / 2, width: side, height: side)
            let path = NSBezierPath(rect: square)
            path.lineWidth = lineWidth
            NSColor.black.setStroke()
            path.stroke()

            context.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }
}
