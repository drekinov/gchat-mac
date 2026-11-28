/// A replacement of a UTF-16 range of text.
public struct TextEdit: Hashable, Sendable {
    public var range: Range<Int>
    public var replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    public var delta: Int { replacement.utf16.count - range.count }

    /// Applies edits that don't overlap, given in any order.
    public static func apply(_ edits: [TextEdit], to text: String) -> String {
        var units = Array(text.utf16)
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            units.replaceSubrange(edit.range, with: Array(edit.replacement.utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Where `offset` ends up after `edits`. With `after`, it stays after text inserted exactly at it; an offset
    /// inside a replaced range moves to the replacement's start.
    public static func map(_ offset: Int, through edits: [TextEdit], after: Bool) -> Int {
        var shift = 0
        for edit in edits {
            if edit.range.upperBound < offset || (edit.range.upperBound == offset && (!edit.range.isEmpty || after)) {
                shift += edit.delta
            } else if edit.range.lowerBound < offset {
                shift += edit.range.lowerBound - offset
            }
        }
        return offset + shift
    }
}
