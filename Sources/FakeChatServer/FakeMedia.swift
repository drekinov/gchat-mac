import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generated images and documents for fake-mode seeding. Image bytes depend only on the arguments; PDF output embeds
/// a creation date from CoreGraphics, so its bytes differ between runs.
public enum FakeMedia {
    public struct Color: Sendable, Hashable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public static let red = Color(red: 220, green: 40, blue: 40)
        public static let green = Color(red: 40, green: 180, blue: 70)
        public static let blue = Color(red: 40, green: 90, blue: 220)
        public static let yellow = Color(red: 240, green: 200, blue: 40)
        public static let gray = Color(red: 128, green: 128, blue: 128)

        fileprivate var cgColor: CGColor {
            CGColor(
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [CGFloat(red) / 255, CGFloat(green) / 255, CGFloat(blue) / 255, 1])!
        }
    }

    public static func png(width: Int = 64, height: Int = 64, color: Color = .blue) -> Data {
        encode([image(width, height, color)], type: .png)
    }

    public static func jpeg(width: Int = 64, height: Int = 64, color: Color = .blue, quality: Double = 0.8) -> Data {
        encode(
            [image(width, height, color)], type: .jpeg,
            properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    /// An endlessly looping GIF with one frame per colour.
    public static func gif(
        width: Int = 32, height: Int = 32, colors: [Color] = [.red, .green, .blue], frameDelay: Double = 0.1
    ) -> Data {
        encode(
            colors.map { image(width, height, $0) }, type: .gif,
            fileProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
            frameProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDelay]])
    }

    public static func pdf(pages: Int = 1, title: String = "Fake document", color: Color = .gray) -> Data {
        let data = CFDataCreateMutable(nil, 0)!
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "FakeMedia"]
        guard let consumer = CGDataConsumer(data: data),
            let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary)
        else { return Data() }
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for page in 1...max(pages, 1) {
            context.beginPDFPage(nil)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 36, y: 700, width: 540, height: 4))
            let text = NSAttributedString(
                string: "\(title) - page \(page)",
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 36, y: 720)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func image(_ width: Int, _ height: Int, _ color: Color) -> CGImage {
        precondition(width > 0 && height > 0)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func encode(
        _ images: [CGImage], type: UTType, properties: [CFString: Any] = [:], fileProperties: [CFString: Any] = [:],
        frameProperties: [CFString: Any] = [:]
    ) -> Data {
        let data = CFDataCreateMutable(nil, 0)!
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)
        else { return Data() }
        if !fileProperties.isEmpty { CGImageDestinationSetProperties(destination, fileProperties as CFDictionary) }
        for image in images {
            CGImageDestinationAddImage(destination, image, (properties.merging(frameProperties) { $1 }) as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
