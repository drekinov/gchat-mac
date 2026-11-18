// Renders the app icon (original artwork, no third-party marks) to a 1024 px PNG.
// Usage: swift scripts/make_icon.swift <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(
        srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255, alpha: alpha)
}

/// Fills a rounded-rect speech bubble whose tail hangs below the bottom edge, near the left or right corner.
func fillBubble(_ rect: CGRect, radius: Double, tailRight: Bool) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    let inner = tailRight ? rect.maxX - radius * 1.35 : rect.minX + radius * 1.35
    let outer = tailRight ? rect.maxX - radius * 0.45 : rect.minX + radius * 0.45
    let tip = tailRight ? rect.maxX - radius * 0.15 : rect.minX + radius * 0.15
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: inner, y: rect.minY + 2))
    tail.addQuadCurve(
        to: CGPoint(x: tip, y: rect.minY - radius * 0.62), control: CGPoint(x: outer, y: rect.minY - radius * 0.1))
    tail.addQuadCurve(
        to: CGPoint(x: outer, y: rect.minY + radius * 0.4), control: CGPoint(x: outer, y: rect.minY - radius * 0.2))
    tail.closeSubpath()
    ctx.addPath(tail)
    ctx.fillPath()
}

// Body: the macOS icon grid's 824 px rounded square with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x3B5BDB))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: space, colors: [color(0x22B8CF), color(0x4263EB), color(0x5F3DC4)] as CFArray,
    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 924), end: CGPoint(x: 864, y: 100), options: [])
ctx.restoreGState()

// Back bubble: translucent, upper left.
let back = CGRect(x: 225, y: 470, width: 400, height: 290)
ctx.saveGState()
ctx.setAlpha(0.42)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(color(0xFFFFFF))
fillBubble(back, radius: 115, tailRight: false)
ctx.endTransparencyLayer()
ctx.restoreGState()

// Front bubble: solid white with a shadow, lower right.
let front = CGRect(x: 375, y: 285, width: 430, height: 310)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: color(0x1A1B4B, 0.30))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(color(0xFFFFFF))
fillBubble(front, radius: 125, tailRight: true)
ctx.endTransparencyLayer()
ctx.restoreGState()

// Typing dots in the front bubble.
let dotRadius = 30.0
for index in 0..<3 {
    let x = front.midX + Double(index - 1) * 92
    ctx.addEllipse(
        in: CGRect(x: x - dotRadius, y: front.midY - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
}
ctx.setFillColor(color(0x4263EB))
ctx.fillPath()

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
