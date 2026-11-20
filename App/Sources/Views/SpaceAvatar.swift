import SwiftUI

/// A conversation's picture: a rounded square with an initial for a space, a circle with initials for a direct
/// message or group chat, and a rounded square with a chip symbol for an app.
struct SpaceAvatar: View {
    let title: String
    let kind: SpaceKind
    var size: CGFloat = 40

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: kind == .space || kind == .bot ? size * 0.26 : size / 2)
        content
            .frame(width: size, height: size)
            .background(color, in: shape)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if kind == .bot {
            Image(systemName: "cpu").font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.white)
        } else {
            Text(initials)
                .font(.system(size: size * (initials.count > 1 ? 0.36 : 0.42), weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var initials: String {
        let words = title.split(whereSeparator: { $0 == " " || $0 == "," }).filter { $0.first?.isLetter == true }
        let take = kind == .space ? 1 : 2
        let letters = words.prefix(take).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// Muted tones that keep white text readable; the same title always gets the same one.
    private var color: Color {
        if kind == .bot { return Color(red: 0x3F / 255, green: 0x54 / 255, blue: 0x68 / 255) }
        let tones: [(Double, Double, Double)] = [
            (0x5E, 0x6E, 0x91), (0x4F, 0x7D, 0x6B), (0xA4, 0x55, 0x3C), (0x86, 0x68, 0x2F), (0x7A, 0x6E, 0x86),
            (0x3F, 0x6D, 0x8C),
        ]
        let hash = title.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        let tone = tones[Int(hash % UInt32(tones.count))]
        return Color(red: tone.0 / 255, green: tone.1 / 255, blue: tone.2 / 255)
    }
}
