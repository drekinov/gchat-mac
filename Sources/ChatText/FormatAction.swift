import Foundation

/// A format bar button. Each one returns explicit edits, so mention ranges can follow them.
public enum FormatAction: String, CaseIterable, Hashable, Sendable {
    case bold, italic, strikethrough, code, codeBlock, bullet, quote, link
}

public struct FormatResult: Hashable, Sendable {
    /// Sorted and non-overlapping.
    public var edits: [TextEdit]
    public var selection: Range<Int>
}

public struct FormatState: Hashable, Sendable {
    /// Formatting the selection is in, which pressing the button removes.
    public var active: Set<FormatAction> = []
    public var unavailable: Set<FormatAction> = []

    public init(active: Set<FormatAction> = [], unavailable: Set<FormatAction> = []) {
        self.active = active
        self.unavailable = unavailable
    }
}

extension FormatAction {
    /// The edits for pressing the button with `selection`, or nil when it can't apply there. Not for `.link`.
    public func apply(to text: String, selection: Range<Int>, mentions: [Range<Int>]) -> FormatResult? {
        guard case .apply(let result, _) = FormatContext(text, selection, mentions).plan(self) else { return nil }
        return result
    }

    public static func state(in text: String, selection: Range<Int>, mentions: [Range<Int>]) -> FormatState {
        let context = FormatContext(text, selection, mentions)
        var state = FormatState()
        for action in allCases {
            switch context.plan(action) {
            case .unavailable: state.unavailable.insert(action)
            case .apply(_, let removes): if removes { state.active.insert(action) }
            }
        }
        return state
    }

    /// Inserts `<url|label>` over the selection, or over the link the selection is in.
    public static func link(
        url: String, label: String, in text: String, selection: Range<Int>, mentions: [Range<Int>]
    ) -> FormatResult? {
        let context = FormatContext(text, selection, mentions)
        guard let url = linkTarget(url), !context.touchesMention(context.selection) else { return nil }
        let target = context.link.map { $0.open.lowerBound..<$0.close.upperBound } ?? context.selection
        let cleaned = label.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespaces)
        let token = cleaned.isEmpty || cleaned == url ? "<\(url)>" : "<\(url)|\(cleaned)>"
        let end = target.lowerBound + token.utf16.count
        return FormatResult(edits: [TextEdit(range: target, replacement: token)], selection: end..<end)
    }

    /// What the link popover starts with: the link the selection is in, or the selected text.
    public static func linkDraft(in text: String, selection: Range<Int>) -> (label: String, url: String?) {
        let context = FormatContext(text, selection, [])
        if let pair = context.link, let link = pair.link { return (link.label, link.url) }
        let selected = context.string(context.selection)
        return (selected.contains("\n") ? "" : selected, nil)
    }

    /// `candidate` as a link target the message view renders: `https` with a host, and nothing that ends a token.
    public static func linkTarget(_ candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("https://"),
            !trimmed.contains(where: { $0.isWhitespace || $0 == "|" || $0 == ">" || $0 == "<" }),
            let url = URL(string: trimmed), let host = url.host(), !host.isEmpty
        else { return nil }
        return trimmed
    }
}

/// The text around a selection, parsed for formatting: the whole text when it has a fence, else the touched lines.
private struct FormatContext {
    enum Plan {
        case unavailable
        case apply(FormatResult, removes: Bool)
    }

    typealias Pair = ComposerSyntax.Pair
    typealias Line = ComposerSyntax.Line

    let selection: Range<Int>
    let mentions: [Range<Int>]
    let syntax: ComposerSyntax
    private let chars: [Character]
    private let offsets: [Int]

    init(_ text: String, _ selection: Range<Int>, _ mentions: [Range<Int>]) {
        let count = text.utf16.count
        let lower = min(max(selection.lowerBound, 0), count)
        self.selection = lower..<min(max(selection.upperBound, lower), count)
        self.mentions = mentions
        let lines = ChatMarkup.hasFence(text) ? 0..<count : ChatMarkup.lineRange(text, covering: self.selection)
        syntax = ChatMarkup.composerSyntax(text, lines: lines.count == count ? nil : lines)
        let units = text.utf16
        let start = units.index(units.startIndex, offsetBy: lines.lowerBound)
        let slice = text[start..<units.index(start, offsetBy: lines.count)]
        chars = Array(slice)
        var offsets = [lines.lowerBound]
        offsets.reserveCapacity(chars.count + 1)
        for char in chars { offsets.append(offsets[offsets.count - 1] + char.utf16.count) }
        self.offsets = offsets
    }

    func plan(_ action: FormatAction) -> Plan {
        switch action {
        case .bold: inline(.bold, "*")
        case .italic: inline(.italic, "_")
        case .strikethrough: inline(.strikethrough, "~")
        case .code: inline(.code, "`")
        case .codeBlock: codeBlock()
        case .bullet: prefix(.bullet)
        case .quote: prefix(.quote)
        case .link:
            touchesMention(selection) || selectedLines.allSatisfy { $0.kind == .code }
                ? .unavailable : .apply(FormatResult(edits: [], selection: selection), removes: link != nil)
        }
    }

    var link: Pair? {
        syntax.pairs.first { $0.link != nil && Self.inside(selection, $0) }
    }

    func touchesMention(_ range: Range<Int>) -> Bool {
        mentions.contains { mention in
            range.isEmpty
                ? mention.lowerBound < range.lowerBound && range.lowerBound < mention.upperBound
                : mention.lowerBound < range.upperBound && range.lowerBound < mention.upperBound
        }
    }

    func string(_ range: Range<Int>) -> String {
        guard let lower = index(range.lowerBound), let upper = index(range.upperBound) else { return "" }
        return String(chars[lower..<upper])
    }

    // MARK: Inline styles

    private func inline(_ flag: Span.Style, _ marker: String) -> Plan {
        let lines = selectedLines.filter { $0.kind != .code }
        guard !lines.isEmpty else { return .unavailable }
        var segments: [(range: Range<Int>, line: Line, pair: Pair?)] = []
        for line in lines {
            let lower = max(selection.lowerBound, line.content.lowerBound)
            let upper = min(selection.upperBound, line.content.upperBound)
            guard lower <= upper else { continue }
            let segment = lower..<upper
            guard selection.isEmpty || !trimmed(segment).isEmpty else { continue }
            let pair = syntax.pairs.first { $0.style == flag && $0.link == nil && Self.inside(segment, $0) }
            segments.append((segment, line, pair))
        }
        guard !segments.isEmpty else { return .unavailable }

        if segments.allSatisfy({ $0.pair != nil }) {
            let edits = segments.compactMap(\.pair).flatMap { pair in
                [TextEdit(range: pair.open, replacement: ""), TextEdit(range: pair.close, replacement: "")]
            }
            return .apply(result(edits, from: selection.lowerBound, to: selection.upperBound), removes: true)
        }
        if flag == .code, touchesMention(selection) { return .unavailable }
        var edits: [TextEdit] = []
        var bounds: [Range<Int>] = []
        for segment in segments where segment.pair == nil {
            guard let wrap = wrap(segment.range, in: segment.line, flag, marker) else { return .unavailable }
            if wrap.range.isEmpty, segment.range.isEmpty, segments.count == 1 {
                let caret = wrap.range.lowerBound + marker.utf16.count
                return .apply(
                    FormatResult(edits: wrap.edits, selection: caret..<caret), removes: false)
            }
            edits += wrap.edits
            bounds.append(wrap.range)
        }
        guard let first = bounds.first, let last = bounds.last else { return .unavailable }
        return .apply(result(edits, from: first.lowerBound, to: last.upperBound), removes: false)
    }

    /// Markers around the segment, trimmed of whitespace and widened to whole words, mentions and same-style spans.
    private func wrap(_ segment: Range<Int>, in line: Line, _ flag: Span.Style, _ marker: String) -> (
        range: Range<Int>, edits: [TextEdit]
    )? {
        var range = trimmed(segment)
        let caret = segment.isEmpty
        if caret, !isWord(char(before: range.lowerBound)), !isWord(char(at: range.lowerBound)),
            !touchesMention(range)
        {
            return (range, [TextEdit(range: range, replacement: marker + marker)])
        }
        var lower = range.lowerBound
        var upper = range.upperBound
        if caret || (isWord(char(before: lower)) && isWord(char(at: lower))) {
            while lower > line.content.lowerBound, let previous = char(before: lower), isWord(previous) {
                lower -= previous.utf16.count
            }
        }
        if caret || (isWord(char(before: upper)) && isWord(char(at: upper))) {
            while upper < line.content.upperBound, let next = char(at: upper), isWord(next) {
                upper += next.utf16.count
            }
        }
        var merged: [Pair] = []
        var grew = true
        while grew {
            grew = false
            range = lower..<upper
            for mention in mentions where mention.lowerBound < upper && lower < mention.upperBound {
                if flag == .code { return nil }
                if mention.lowerBound < lower || mention.upperBound > upper {
                    lower = min(lower, mention.lowerBound)
                    upper = max(upper, mention.upperBound)
                    grew = true
                }
            }
            for pair in syntax.pairs
            where pair.style == flag && pair.link == nil && pair.open.lowerBound < upper
                && lower < pair.close.upperBound && !merged.contains(where: { $0.open == pair.open })
            {
                merged.append(pair)
                lower = min(lower, pair.open.lowerBound)
                upper = max(upper, pair.close.upperBound)
                grew = true
            }
        }
        range = lower..<upper
        if flag == .code {
            let ticks = merged.flatMap { [$0.open.lowerBound, $0.close.lowerBound] }
            var offset = lower
            while offset < upper, let char = char(at: offset) {
                if char == "`", !ticks.contains(offset) { return nil }
                offset += char.utf16.count
            }
        }
        var edits = [TextEdit(range: lower..<lower, replacement: marker)]
        for pair in merged {
            edits += [TextEdit(range: pair.open, replacement: ""), TextEdit(range: pair.close, replacement: "")]
        }
        edits.append(TextEdit(range: upper..<upper, replacement: marker))
        return (range, edits)
    }

    // MARK: Blocks

    private func codeBlock() -> Plan {
        let lines = selectedLines
        guard let first = lines.first, let last = lines.last else { return .unavailable }
        if let fence = syntax.fences.first(where: {
            $0.lines.lowerBound <= selection.lowerBound && selection.upperBound <= $0.lines.upperBound
        }) {
            return .apply(unfence(fence), removes: true)
        }
        if lines.contains(where: { $0.kind == .code }) { return .unavailable }
        let start = first.range.lowerBound
        let end = last.range.upperBound
        if mentions.contains(where: { $0.lowerBound < end && start < $0.upperBound }) { return .unavailable }
        if start == end {
            let edits = [TextEdit(range: start..<start, replacement: "```\n\n```")]
            return .apply(FormatResult(edits: edits, selection: (start + 4)..<(start + 4)), removes: false)
        }
        let edits = [
            TextEdit(range: start..<start, replacement: "```\n"), TextEdit(range: end..<end, replacement: "\n```"),
        ]
        let selected =
            selection.isEmpty ? (selection.lowerBound + 4)..<(selection.lowerBound + 4) : (start + 4)..<(end + 4)
        return .apply(FormatResult(edits: edits, selection: selected), removes: false)
    }

    private func unfence(_ fence: ComposerSyntax.Fence) -> FormatResult {
        let openerLine = syntax.lines.first { $0.range.lowerBound == fence.open.lowerBound }
        var open = fence.open
        if openerLine?.range.count == 3, fence.lines.upperBound > open.upperBound {
            open = open.lowerBound..<(open.upperBound + 1)
        }
        var edits = [TextEdit(range: open, replacement: "")]
        if var close = fence.close, close.lowerBound >= fence.open.upperBound {
            let ownLine = syntax.lines.contains { $0.range == close }
            if ownLine, close.lowerBound > open.upperBound { close = (close.lowerBound - 1)..<close.upperBound }
            if close.lowerBound < open.upperBound {
                edits = [TextEdit(range: fence.lines, replacement: "")]
            } else {
                edits.append(TextEdit(range: close, replacement: ""))
            }
        }
        return result(edits, from: selection.lowerBound, to: selection.upperBound)
    }

    private func prefix(_ kind: Line.Kind) -> Plan {
        let lines = selectedLines.filter { $0.kind != .code }
        guard !lines.isEmpty else { return .unavailable }
        let nonEmpty = lines.filter { !$0.range.isEmpty }
        let targets = nonEmpty.isEmpty ? lines : nonEmpty
        if targets.allSatisfy({ $0.kind == kind }) {
            let edits = targets.map { line in
                let start = kind == .bullet ? line.content.lowerBound - 2 : line.range.lowerBound
                return TextEdit(range: start..<line.content.lowerBound, replacement: "")
            }
            return .apply(result(edits, from: selection.lowerBound, to: selection.upperBound), removes: true)
        }
        let edits = targets.filter { $0.kind != kind }.map { line in
            var at = line.range.lowerBound
            if kind == .bullet {
                var spaces = 0
                while let char = char(at: at + spaces), char == " " { spaces += 1 }
                at += spaces / 4 * 4
            }
            return TextEdit(range: at..<at, replacement: kind == .bullet ? "* " : "> ")
        }
        let lower = TextEdit.map(selection.lowerBound, through: edits, after: selection.isEmpty)
        let upper = TextEdit.map(selection.upperBound, through: edits, after: true)
        return .apply(FormatResult(edits: edits, selection: lower..<max(lower, upper)), removes: false)
    }

    // MARK: Helpers

    private var selectedLines: [Line] {
        syntax.lines.filter { line in
            if selection.isEmpty {
                return line.range.lowerBound <= selection.lowerBound && selection.lowerBound <= line.range.upperBound
            }
            return line.range.lowerBound < selection.upperBound
                && (selection.lowerBound < line.range.upperBound
                    || (line.range.isEmpty && selection.lowerBound <= line.range.lowerBound))
        }
    }

    private static func inside(_ segment: Range<Int>, _ pair: Pair) -> Bool {
        segment.isEmpty
            ? pair.open.upperBound <= segment.lowerBound && segment.lowerBound <= pair.close.lowerBound
            : pair.open.lowerBound <= segment.lowerBound && segment.upperBound <= pair.close.upperBound
    }

    private func result(_ edits: [TextEdit], from lower: Int, to upper: Int) -> FormatResult {
        let start = TextEdit.map(lower, through: edits, after: true)
        let end = TextEdit.map(upper, through: edits, after: false)
        return FormatResult(edits: Self.normalized(edits), selection: start..<max(start, end))
    }

    /// Sorted, with touching edits merged so that applying them in any order gives the same text.
    private static func normalized(_ edits: [TextEdit]) -> [TextEdit] {
        let sorted = edits.sorted {
            ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound)
        }
        var out: [TextEdit] = []
        for edit in sorted {
            if let last = out.last, last.range.upperBound == edit.range.lowerBound {
                out[out.count - 1] = TextEdit(
                    range: last.range.lowerBound..<edit.range.upperBound,
                    replacement: last.replacement + edit.replacement)
            } else {
                out.append(edit)
            }
        }
        return out
    }

    private func trimmed(_ range: Range<Int>) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, let char = char(at: lower), char.isWhitespace { lower += char.utf16.count }
        while upper > lower, let char = char(before: upper), char.isWhitespace { upper -= char.utf16.count }
        return lower..<upper
    }

    private func isWord(_ char: Character?) -> Bool {
        guard let char else { return false }
        return !char.isWhitespace && !InlineParser.isPunct(char)
    }

    private func index(_ offset: Int) -> Int? {
        var low = 0
        var high = offsets.count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid] < offset { low = mid + 1 } else { high = mid }
        }
        return low < offsets.count && offsets[low] == offset ? low : nil
    }

    private func char(at offset: Int) -> Character? {
        guard let index = index(offset), index < chars.count else { return nil }
        return chars[index]
    }

    private func char(before offset: Int) -> Character? {
        guard let index = index(offset), index > 0 else { return nil }
        return chars[index - 1]
    }
}
