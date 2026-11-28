import ChatModel

/// A styled stretch of the composer's text, in UTF-16 offsets. Unstyled text has no run.
public struct ComposerRun: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case text
        /// Syntax that Google doesn't show: emphasis and code markers, link targets, list and quote prefixes, fences.
        case marker
        /// A link's label, or a bare link's URL.
        case link
    }

    public var range: Range<Int>
    public var kind: Kind
    /// Includes `.code` on the lines of a fenced block.
    public var style: Span.Style

    public init(range: Range<Int>, kind: Kind, style: Span.Style) {
        self.range = range
        self.kind = kind
        self.style = style
    }
}

/// The Chat syntax of composer text, found by the same rules as `ChatMarkup.parse`, with UTF-16 positions.
struct ComposerSyntax {
    struct Pair {
        var open: Range<Int>
        var close: Range<Int>
        /// `.code` for a code span, empty for a link.
        var style: Span.Style
        var link: Link?
    }

    struct Link: Hashable {
        var url: String
        var label: String
    }

    struct Fence {
        var open: Range<Int>
        /// Nil while the fence is still open; the composer treats the rest of the text as code.
        var close: Range<Int>?
        var lines: Range<Int>
    }

    struct Line {
        enum Kind { case plain, bullet, quote, code }
        var range: Range<Int>
        var content: Range<Int>
        var kind: Kind
    }

    var runs: [ComposerRun] = []
    var pairs: [Pair] = []
    var fences: [Fence] = []
    var lines: [Line] = []

    mutating func run(_ range: Range<Int>, _ kind: ComposerRun.Kind, _ style: Span.Style) {
        guard !range.isEmpty, kind != .text || !style.isEmpty else { return }
        if let last = runs.last, last.range.upperBound == range.lowerBound, last.kind == kind, last.style == style {
            runs[runs.count - 1].range = last.range.lowerBound..<range.upperBound
        } else {
            runs.append(ComposerRun(range: range, kind: kind, style: style))
        }
    }
}

extension ChatMarkup {
    /// How the composer styles `text`. Lines style on their own unless the text has a fence, so a caller may
    /// restyle just the lines an edit touched while `hasFence` is false.
    public static func composerRuns(_ text: String) -> [ComposerRun] {
        composerSyntax(text).runs
    }

    /// Whether any line starts a fence.
    public static func hasFence(_ text: String) -> Bool {
        var atLineStart = true
        var ticks = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                atLineStart = true
                ticks = 0
            } else if atLineStart, byte == 0x60 {
                ticks += 1
                if ticks == 3 { return true }
            } else {
                atLineStart = false
            }
        }
        return false
    }

    /// Whether Return at `offset` belongs inside a fenced block: after its opening fence and not after its closing
    /// one.
    public static func isInsideCodeBlock(_ text: String, at offset: Int) -> Bool {
        guard hasFence(text) else { return false }
        return composerSyntax(text, inline: false).fences.contains { fence in
            offset >= fence.open.upperBound && offset <= (fence.close?.lowerBound ?? Int.max)
        }
    }

    /// The whole lines of `text` that `range` touches, in UTF-16 offsets.
    public static func lineRange(_ text: String, covering range: Range<Int>) -> Range<Int> {
        let units = text.utf16
        let count = units.count
        let lower = min(max(range.lowerBound, 0), count)
        let upper = min(max(range.upperBound, lower), count)
        var start = units.index(units.startIndex, offsetBy: lower)
        var low = lower
        while start > units.startIndex {
            let previous = units.index(before: start)
            if units[previous] == 0x0A { break }
            start = previous
            low -= 1
        }
        var end = units.index(units.startIndex, offsetBy: upper)
        var high = upper
        while end < units.endIndex, units[end] != 0x0A {
            end = units.index(after: end)
            high += 1
        }
        return low..<high
    }

    static func composerSyntax(_ text: String, lines: Range<Int>? = nil, inline: Bool = true) -> ComposerSyntax {
        let slice: Substring
        let base: Int
        if let lines {
            let units = text.utf16
            let lower = units.index(units.startIndex, offsetBy: lines.lowerBound)
            let upper = units.index(lower, offsetBy: lines.count)
            slice = text[lower..<upper]
            base = lines.lowerBound
        } else {
            slice = text[...]
            base = 0
        }
        let rows = slice.split(separator: "\n", omittingEmptySubsequences: false)
        var starts: [Int] = []
        starts.reserveCapacity(rows.count + 1)
        var offset = base
        for row in rows {
            starts.append(offset)
            offset += row.utf16.count + 1
        }
        var out = ComposerSyntax()
        var index = 0
        while index < rows.count {
            let row = rows[index]
            let start = starts[index]
            if row.hasPrefix("```") {
                let end = fenceEnd(rows, from: index)
                let last = end ?? rows.count - 1
                appendFence(rows, starts, index...last, closed: end != nil, into: &out)
                index = last + 1
                continue
            }
            let length = row.utf16.count
            let range = start..<(start + length)
            if let (_, content) = listItem(row) {
                let contentStart = start + length - content.utf16.count
                out.lines.append(.init(range: range, content: contentStart..<range.upperBound, kind: .bullet))
                out.run(start..<contentStart, .marker, [])
                if inline { InlineParser.syntax(content, base: contentStart, into: &out) }
            } else if let content = quoteLine(row) {
                let contentStart = start + length - content.utf16.count
                out.lines.append(.init(range: range, content: contentStart..<range.upperBound, kind: .quote))
                out.run(start..<contentStart, .marker, [])
                if inline { InlineParser.syntax(content, base: contentStart, into: &out) }
            } else {
                out.lines.append(.init(range: range, content: range, kind: .plain))
                if inline { InlineParser.syntax(row, base: start, into: &out) }
            }
            index += 1
        }
        return out
    }

    private static func appendFence(
        _ rows: [Substring], _ starts: [Int], _ span: ClosedRange<Int>, closed: Bool, into out: inout ComposerSyntax
    ) {
        let first = starts[span.lowerBound]
        let lastEnd = starts[span.upperBound] + rows[span.upperBound].utf16.count
        let open = first..<(first + 3)
        let close = closed ? (lastEnd - 3)..<lastEnd : nil
        out.fences.append(.init(open: open, close: close, lines: first..<lastEnd))
        for row in span {
            let start = starts[row]
            let range = start..<(start + rows[row].utf16.count)
            out.lines.append(.init(range: range, content: range, kind: .code))
        }
        out.run(open, .marker, .code)
        out.run(open.upperBound..<(close?.lowerBound ?? lastEnd), .text, .code)
        if let close { out.run(close, .marker, .code) }
    }
}
