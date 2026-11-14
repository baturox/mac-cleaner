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
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.40))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x0C0E1D))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: deep ink gradient with a faint glow behind the artwork.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [color(0x2B3158), color(0x0C0E1D)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let glow = CGGradient(colorsSpace: space,
                          colors: [color(0x35D6C3, 0.26), color(0x35D6C3, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 400, options: [])
    // Hairline highlight along the upper edge.
    let edge = CGGradient(colorsSpace: space,
                          colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.addPath(shape)
    ctx.setLineWidth(small ? 0 : 6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(edge, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // Storage gauge: a dim track with a gap at the bottom, and a bright arc for the space won back.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 268
    let width: CGFloat = small ? 96 : 62
    let sweepStart: CGFloat = -138, sweepEnd: CGFloat = 138   // degrees clockwise from 12 o'clock
    let fillEnd: CGFloat = 62
    arc(ctx, center: center, radius: radius, from: sweepStart, to: sweepEnd, width: width, color: color(0xFFFFFF, 0.13))

    let stops: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
        (0.0, (0.36, 0.96, 0.73)),   // mint
        (0.55, (0.22, 0.78, 0.98)),  // sky
        (1.0, (0.55, 0.52, 1.00)),   // violet
    ]
    func ramp(_ t: CGFloat) -> CGColor {
        var lo = stops[0], hi = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) where t >= stops[i].0 && t <= stops[i + 1].0 { lo = stops[i]; hi = stops[i + 1] }
        let f = hi.0 == lo.0 ? 0 : (t - lo.0) / (hi.0 - lo.0)
        return CGColor(srgbRed: lo.1.0 + (hi.1.0 - lo.1.0) * f, green: lo.1.1 + (hi.1.1 - lo.1.1) * f,
                       blue: lo.1.2 + (hi.1.2 - lo.1.2) * f, alpha: 1)
    }
    let toRad = { (d: CGFloat) in (90 - d) * .pi / 180 }
    let pieces = 240
    ctx.saveGState()
    ctx.setLineWidth(width)
    ctx.setLineCap(.butt)
    for i in 0..<pieces {
        let t0 = CGFloat(i) / CGFloat(pieces), t1 = CGFloat(i + 1) / CGFloat(pieces)
        let d0 = sweepStart + (fillEnd - sweepStart) * t0
        let d1 = sweepStart + (fillEnd - sweepStart) * t1 + 0.4   // slight overlap hides seams
        ctx.setStrokeColor(ramp(t0))
        ctx.addArc(center: center, radius: radius, startAngle: toRad(d0), endAngle: toRad(d1), clockwise: true)
        ctx.strokePath()
    }
    for (d, t) in [(sweepStart, CGFloat(0)), (fillEnd, CGFloat(1))] {   // round ends
        let p = CGPoint(x: center.x + radius * cos(toRad(d)), y: center.y + radius * sin(toRad(d)))
        ctx.setFillColor(ramp(t))
        ctx.fillEllipse(in: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width))
    }
    ctx.restoreGState()

    // Sparkle: "clean". One large four-point star, plus a small companion at larger sizes.
    func sparkle(at c: CGPoint, radius r: CGFloat, pinch: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let k = r * pinch
        path.move(to: CGPoint(x: c.x, y: c.y + r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + k, y: c.y - k))
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - k, y: c.y + k))
        path.closeSubpath()
        return path
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 46, color: color(0x5CF5BA, 0.55))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.addPath(sparkle(at: CGPoint(x: small ? 512 : 496, y: small ? 512 : 496), radius: small ? 170 : 150, pinch: 0.16))
    ctx.fillPath()
    if !small {
        ctx.addPath(sparkle(at: CGPoint(x: 624, y: 632), radius: 54, pinch: 0.16))
        ctx.fillPath()
    }
    ctx.restoreGState()
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
