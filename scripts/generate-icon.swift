#!/usr/bin/swift
import AppKit

// Generates a 1024x1024 macOS app icon: a squircle canvas with a black
// gradient (lighter top-left, darker bottom-right) and a heavy-stroked
// square rotated 30°, matching the menubar icon's shape.

let size: CGFloat = 1024
let rect = NSRect(x: 0, y: 0, width: size, height: size)

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let context = NSGraphicsContext.current?.cgContext else { return false }

    // macOS Big Sur-style squircle (~22% corner radius).
    let cornerRadius = size * 0.2197
    let squircle = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    context.saveGState()
    squircle.addClip()

    let gradient = NSGradient(
        colors: [
            NSColor(calibratedWhite: 0.12, alpha: 1.0), // lighter, top-left
            NSColor(calibratedWhite: 0.02, alpha: 1.0)  // near-black, bottom-right
        ]
    )
    // Top-left to bottom-right in a flipped(false) NSImage: y=size is top.
    gradient?.draw(from: NSPoint(x: 0, y: size), to: NSPoint(x: size, y: 0), options: [])

    context.restoreGState()

    // Tilted square, heavier stroke than the menubar icon.
    context.saveGState()
    context.translateBy(x: size / 2, y: size / 2)
    context.rotate(by: 30 * .pi / 180)

    let squareSide: CGFloat = size * 0.52 * 1.2
    let lineWidth: CGFloat = size * 0.075
    let square = NSRect(x: -squareSide / 2, y: -squareSide / 2, width: squareSide, height: squareSide)
        .insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
    // Soft window-style corners (macOS Tahoe's rounder window chrome) — less
    // rounded than a full squircle.
    let squareCornerRadius = squareSide * 0.12
    let path = NSBezierPath(roundedRect: square, xRadius: squareCornerRadius, yRadius: squareCornerRadius)
    path.lineWidth = lineWidth
    NSColor(calibratedWhite: 0.97, alpha: 1.0).setStroke()
    path.stroke()

    context.restoreGState()
    return true
}

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
else {
    FileHandle.standardError.write("Failed to render icon\n".data(using: .utf8)!)
    exit(1)
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
try png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
