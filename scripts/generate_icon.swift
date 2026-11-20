#!/usr/bin/env swift
import Cocoa

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate_icon.swift <output.iconset>\n", stderr)
    exit(1)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> NSBitmapImageRep? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
    guard let rep else { return nil }
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(pixelSize)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let pad = size * 0.08
    let cardRect = rect.insetBy(dx: pad, dy: pad)
    let corner = size * 0.22

    let bgPath = NSBezierPath(roundedRect: cardRect, xRadius: corner, yRadius: corner)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.20, alpha: 1.0),
        NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.34, alpha: 1.0)
    ])
    gradient?.draw(in: bgPath, angle: -55)

    // Subtle inner border
    NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.72, alpha: 0.35).setStroke()
    bgPath.lineWidth = max(1.0, size * 0.015)
    bgPath.stroke()

    // Outer timer ring
    let center = NSPoint(x: size * 0.5, y: size * 0.5)
    let ringRadius = size * 0.28
    let ringPath = NSBezierPath()
    ringPath.appendArc(withCenter: center, radius: ringRadius, startAngle: -30, endAngle: 285, clockwise: false)
    ringPath.lineWidth = max(1.5, size * 0.055)
    ringPath.lineCapStyle = .round
    NSColor(calibratedRed: 0.28, green: 0.90, blue: 0.72, alpha: 1.0).setStroke()
    ringPath.stroke()

    // Lightning bolt inside timer ring
    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: size * 0.53, y: size * 0.67))
    bolt.line(to: NSPoint(x: size * 0.41, y: size * 0.49))
    bolt.line(to: NSPoint(x: size * 0.51, y: size * 0.49))
    bolt.line(to: NSPoint(x: size * 0.47, y: size * 0.32))
    bolt.line(to: NSPoint(x: size * 0.60, y: size * 0.51))
    bolt.line(to: NSPoint(x: size * 0.50, y: size * 0.51))
    bolt.close()

    NSColor.white.setFill()
    bolt.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let specs: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for spec in specs {
    guard let rep = renderIcon(pixelSize: spec.px),
          let png = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed to render \(spec.name)\n", stderr)
        exit(1)
    }
    try png.write(to: outputDir.appendingPathComponent(spec.name))
}
