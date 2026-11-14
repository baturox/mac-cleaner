#!/usr/bin/env swift
// Draws the Mac Cleaner app icon with CoreGraphics and writes
//   Resources/AppIcon.icns   (via iconutil)
//   Resources/AppIcon.png    (1024 px, used by the README)
//
// Usage (from the repository root):  swift scripts/make-icon.swift
//
// The icon: a continuous-corner rounded square, a storage gauge ring (used space in white, a
// freshly cleared segment in mint) and a terminal prompt in the middle. No external assets.
import AppKit
import CoreGraphics
import Foundation

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Superellipse ("squircle") path, closer to Apple's continuous corners than a rounded rectangle.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func arc(_ ctx: CGContext, center: CGPoint, radius: CGFloat, from startDeg: CGFloat, to endDeg: CGFloat,
         width: CGFloat, color c: CGColor) {
    ctx.saveGState()
    ctx.setStrokeColor(c)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    // Angles are measured clockwise from 12 o'clock.
    let toRad = { (d: CGFloat) in (90 - d) * .pi / 180 }
    ctx.addArc(center: center, radius: radius, startAngle: toRad(startDeg), endAngle: toRad(endDeg), clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()
}

/// Draws the whole icon in a 1024 x 1024 coordinate space.
func drawIcon(_ ctx: CGContext, small: Bool) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Standard macOS icon grid: 824 px body centered in 1024.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    // Soft shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1B2766))
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [color(0x4466F0), color(0x1B2766)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Gentle highlight on the upper edge.
    let gloss = CGGradient(colorsSpace: space,
                           colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()

    // Gauge ring.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 262
    let width: CGFloat = small ? 118 : 100
    arc(ctx, center: center, radius: radius, from: 0, to: 359.9, width: width, color: color(0xFFFFFF, 0.20))
    arc(ctx, center: center, radius: radius, from: 0, to: 232, width: width, color: color(0xFFFFFF))        // used
    arc(ctx, center: center, radius: radius, from: 262, to: 322, width: width, color: color(0x3DDC97))      // freed

    // Terminal prompt ">_" in the middle (dropped at tiny sizes where it would only be noise).
    if !small {
        ctx.saveGState()
        ctx.setStrokeColor(color(0xFFFFFF))
        ctx.setLineWidth(40)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: 438, y: 594))
        ctx.addLine(to: CGPoint(x: 520, y: 512))
        ctx.addLine(to: CGPoint(x: 438, y: 430))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: 548, y: 430))
        ctx.addLine(to: CGPoint(x: 618, y: 430))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    drawIcon(ctx, small: pixels <= 32)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
}

// MARK: - Main

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = root.appendingPathComponent(".build/icon/AppIcon.iconset")

do {
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)

    let entries: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    var cache: [Int: CGImage] = [:]
    for e in entries {
        let image = cache[e.pixels] ?? render(pixels: e.pixels)
        cache[e.pixels] = image
        try writePNG(image, to: iconset.appendingPathComponent(e.name))
    }
    try writePNG(cache[1024]!, to: resources.appendingPathComponent("AppIcon.png"))

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
    print("Wrote Resources/AppIcon.icns and Resources/AppIcon.png")
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
