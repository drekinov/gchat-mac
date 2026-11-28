import AppKit
import UniformTypeIdentifiers

/// The drag types a composer's text view keeps, so file and image drags reach the enclosing drop destination and
/// attach. A plain `NSTextView` accepts any file drag and types the file's path, and as the innermost view it gets
/// the drag before SwiftUI can.
enum TextOnlyDrops {
    /// Text views register mostly legacy type names, which `UTType` doesn't know.
    static let legacyText: Set<String> = [
        "NSStringPboardType", "NeXT Rich Text Format v1.0 pasteboard type", "Apple HTML pasteboard type",
        "NeXT font pasteboard type", "NeXT ruler pasteboard type", "NSColor pasteboard type",
    ]

    /// Plain and styled text, fonts and colours; not file names, file promises, URLs, images or RTFD (which can
    /// carry files).
    static func isText(_ type: NSPasteboard.PasteboardType) -> Bool {
        if legacyText.contains(type.rawValue) { return true }
        guard let uti = UTType(type.rawValue) else { return false }
        return uti.conforms(to: .text) && !uti.conforms(to: .rtfd) && !uti.conforms(to: .flatRTFD)
    }
}
