// Renders the app icon (original artwork, no third-party marks) to a 1024 px PNG: two speech bubbles sewn on like
// fabric patches, one thread of conversation, where they overlap a third colour.
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
// Top-left origin with y pointing down. Shadow offsets stay in device space, where a negative height points down.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(
        srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255, alpha: alpha)
}

/// A rounded-rect speech bubble whose tail sweeps out of the bottom-left corner, or the bottom-right when mirrored.
/// `tip` moves the tail's point; it is given for the bottom-left shape, before any mirroring.
func bubble(_ rect: CGRect, radius r: Double, tailRight: Bool, tip: CGPoint? = nil) -> CGPath {
    let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: x0 + r, y: y0))
    path.addLine(to: CGPoint(x: x1 - r, y: y0))
    path.addArc(center: CGPoint(x: x1 - r, y: y0 + r), radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
    path.addLine(to: CGPoint(x: x1, y: y1 - r))
    path.addArc(center: CGPoint(x: x1 - r, y: y1 - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: false)
    path.addLine(to: CGPoint(x: x0 + r * 1.5, y: y1))
    path.addQuadCurve(
        to: tip ?? CGPoint(x: x0 + r * 0.06, y: y1 + r * 0.56), control: CGPoint(x: x0 + r * 0.85, y: y1 + r * 0.22))
    // Back to the bottom-left corner, 30 degrees short of its end.
    path.addQuadCurve(
        to: CGPoint(x: x0 + r * (1 - cos(.pi / 6)), y: y1 - r * 0.5),
        control: CGPoint(x: x0 + r * 0.16, y: y1 + r * 0.18))
    path.addArc(
        center: CGPoint(x: x0 + r, y: y1 - r), radius: r, startAngle: .pi * 5 / 6, endAngle: .pi, clockwise: false)
    path.addLine(to: CGPoint(x: x0, y: y0 + r))
    path.addArc(
        center: CGPoint(x: x0 + r, y: y0 + r), radius: r, startAngle: .pi, endAngle: .pi * 3 / 2, clockwise: false)
    path.closeSubpath()
    guard tailRight else { return path }
    var mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: x0 + x1, ty: 0)
    return path.copy(using: &mirror)!
}

// Body: the macOS icon grid's 824 px rounded square with a soft drop shadow, warm paper fading slightly downward.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.26))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0xF2EADB))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let paper = CGGradient(colorsSpace: space, colors: [color(0xF8F2E7), color(0xEBE1CE)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])

let radius = 160.0
let left = CGRect(x: 178, y: 222, width: 434, height: 346)
let right = CGRect(x: 412, y: 412, width: 434, height: 346)
let leftBubble = bubble(left, radius: radius, tailRight: false)
let rightBubble = bubble(right, radius: radius, tailRight: true)

/// A bubble cut from cloth, lifted slightly off the paper.
func patch(_ shape: CGPath, _ fill: UInt32) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x2A1A10, 0.22))
    ctx.addPath(shape)
    ctx.setFillColor(color(fill))
    ctx.fillPath()
    ctx.restoreGState()
}

/// A running stitch just inside a patch's edge, reaching into its tail.
func seam(_ patch: CGRect, tailRight: Bool) {
    let inset = 34.0
    let tip = CGPoint(x: patch.minX + radius * 0.06 + inset * 1.1, y: patch.maxY + radius * 0.56 - inset * 1.49)
    let line = bubble(patch.insetBy(dx: inset, dy: inset), radius: radius - inset, tailRight: tailRight, tip: tip)
    ctx.saveGState()
    ctx.addPath(line)
    ctx.setStrokeColor(color(0xFBF4E8))
    ctx.setLineWidth(15)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [26, 30])
    ctx.strokePath()
    ctx.restoreGState()
}

patch(leftBubble, 0xE8573F)
seam(left, tailRight: false)
patch(rightBubble, 0x1F8A94)
// Where the two voices overlap.
ctx.saveGState()
ctx.addPath(leftBubble)
ctx.clip()
ctx.addPath(rightBubble)
ctx.setFillColor(color(0x2E2A3B))
ctx.fillPath()
ctx.restoreGState()
seam(right, tailRight: true)
ctx.restoreGState()

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
