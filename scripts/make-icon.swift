#!/usr/bin/env swift
// Builds the Mac Cleaner app icon from the rendered artwork and writes
//   Resources/AppIcon.icns   (via iconutil)
//   Resources/AppIcon.png    (1024 px, used by the README)
//
// Usage (from the repository root):  swift scripts/make-icon.swift
//
// The artwork (a disk with one wedge cleared and a sparkle in its place) is authored as HTML/SVG in
// Resources/icon/index.html and rendered full-bleed to Resources/icon/artwork.png with HyperFrames:
//   npx hyperframes snapshot Resources/icon --at 2.5 --no-end -o /tmp/icon && cp /tmp/icon/frame-00-*.png Resources/icon/artwork.png
// This script only places that square artwork on the standard macOS icon grid: continuous-corner
// body, drop shadow and a hairline highlight.
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

func loadArtwork(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write(Data("make-icon: cannot read \(url.path)\n".utf8))
        exit(1)
    }
    return image
}

/// Draws the whole icon in a 1024 x 1024 coordinate space.
func drawIcon(_ ctx: CGContext, artwork: CGImage, small: Bool) {
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

    // Artwork, clipped to the body. At tiny sizes zoom in a little so the mark stays readable.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let zoom: CGFloat = small ? 1.14 : 1.0
    let side = body.width * zoom
    ctx.draw(artwork, in: CGRect(x: body.midX - side / 2, y: body.midY - side / 2, width: side, height: side))
    ctx.restoreGState()

    // Hairline highlight along the upper edge.
    if !small {
        ctx.saveGState()
        let edge = CGGradient(colorsSpace: space,
                              colors: [color(0xFFFFFF, 0.30), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.addPath(shape)
        ctx.clip()
        ctx.addPath(shape)
        ctx.setLineWidth(8)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(edge, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: [])
        ctx.restoreGState()
    }
}

func render(pixels: Int, artwork: CGImage) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    drawIcon(ctx, artwork: artwork, small: pixels <= 32)
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
let artwork = loadArtwork(resources.appendingPathComponent("icon/artwork.png"))

do {
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

    let entries: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    var cache: [Int: CGImage] = [:]
    for e in entries {
        let image = cache[e.pixels] ?? render(pixels: e.pixels, artwork: artwork)
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
