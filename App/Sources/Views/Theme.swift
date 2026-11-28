import AppKit
import SwiftUI

/// The app's colours. Each one resolves against the current appearance, so light mode, dark mode and the
/// Auto/Light/Dark setting all pick the right shade without any view code of their own.
enum Theme {
    /// Slate, from the asset catalog's AccentColor. Used for fills: own bubbles, unread dots, the send button.
    /// When someone picks an accent colour other than Multicolor in System Settings, macOS uses theirs instead.
    static let accent = Color.accentColor
    /// Slate for text and icons on the window background. Lighter in dark mode so it stays readable.
    static let accentText = dynamic(light: 0x4A_6382, dark: 0xA4_B1C0)
    /// Text and icons on an accent fill.
    static let onAccent = Color.white
    /// Other people's bubbles: a neutral grey with a little Slate in it.
    static let incomingBubble = dynamic(light: 0xDE_E1E5, dark: 0x36_393F)
    /// Quotes and cards inside a bubble.
    static let insetSurface = dynamic(light: 0xFF_FFFF, dark: 0x26_272B)
    /// The sidebar island: a little darker than the window in light mode and a little lighter in dark mode, with a
    /// trace of Slate, so the sidebar reads as a panel of its own.
    static let island = dynamic(light: 0xEA_EBEE, dark: 0x2B_2D32)
    /// The island's hairline edge.
    static let islandEdge = dynamic(light: 0x00_0000, dark: 0xFF_FFFF, lightAlpha: 0.07, darkAlpha: 0.08)
    /// Selected rows and highlighted search results.
    static let selection = dynamic(light: 0x4A_6382, dark: 0x6E_87A6, lightAlpha: 0.14, darkAlpha: 0.32)
    /// The tint behind inline code on other people's bubbles.
    static let inlineCode = dynamic(light: 0x00_0000, dark: 0xFF_FFFF, lightAlpha: 0.07, darkAlpha: 0.09)
    static let warning = dynamic(light: 0x9A_5B00, dark: 0xF2_B455)
    static let error = dynamic(light: 0xC4_352B, dark: 0xFF_6B61)

    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    static func dynamicNS(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    private static func rgb(_ value: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}
