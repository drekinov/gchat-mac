import Foundation

/// Every string that came from the server passes through here before it is displayed.
enum RemoteText {
    static let titleLimit = 200
    static let previewLimit = 140
    static let messageLimit = 32_768

    static func title(_ text: String) -> String {
        clean(text, limit: titleLimit, keepLineBreaks: false)
    }

    static func preview(_ text: String) -> String {
        clean(text, limit: previewLimit, keepLineBreaks: false)
    }

    static func message(_ text: String) -> String {
        clean(text, limit: messageLimit, keepLineBreaks: true)
    }

    static func clean(_ text: String, limit: Int, keepLineBreaks: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasSpace = false
        let input = Array(text.unicodeScalars)
        for (index, original) in input.enumerated() {
            if isInvisible(original) && !isEmojiJoiner(input, index) { continue }
            var scalar = original
            switch scalar {
            case "\r":
                continue
            case "\n", "\t":
                if !keepLineBreaks {
                    scalar = " "
                }
            default:
                if scalar.properties.generalCategory == .control { continue }
            }
            if !keepLineBreaks {
                if scalar == " " && previousWasSpace { continue }
                previousWasSpace = scalar == " "
            }
            scalars.append(scalar)
        }
        var result = String(scalars)
        if !keepLineBreaks { result = result.trimmingCharacters(in: .whitespaces) }
        guard result.utf8.count > limit, result.count > limit else { return result }
        return String(result.prefix(limit)) + "…"
    }

    /// A zero-width joiner survives only between two emoji, so ZWJ sequences render and other joiners are stripped.
    static func isEmojiJoiner(_ scalars: [Unicode.Scalar], _ index: Int) -> Bool {
        guard scalars[index].value == 0x200D, index > 0, index + 1 < scalars.count else { return false }
        func isPictograph(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value > 0xFF
                && (scalar.properties.isEmoji || scalar.value == 0xFE0F || scalar.value == 0x2640
                    || scalar.value == 0x2642)
        }
        return isPictograph(scalars[index - 1]) && isPictograph(scalars[index + 1])
    }

    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF, 0x2028, 0x2029, 0x2060...0x2064, 0x061C,
            0x180E:
            true
        default:
            false
        }
    }
}
