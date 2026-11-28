import ChatModel

/// Inline Chat syntax on single lines: code spans first, then `<…>` tokens and custom emoji, then emphasis.
enum InlineParser {
    private enum Atom {
        case char(Character)
        case code(String)
        case mention(UserName)
        case link(url: String, label: String?)
        case emoji(String)
    }

    /// The spans of `lines`, joined by line breaks. Emphasis never spans a line break.
    static func spans(_ lines: [Substring]) -> [Span] {
        var out = SpanBuilder()
        for (index, line) in lines.enumerated() {
            if index > 0 { out.append("\n", style: []) }
            let atoms = tokenize(line)
            Emphasis(atoms: atoms).emit(into: &out)
        }
        return out.spans
    }

    private static func tokenize(_ line: Substring) -> [Atom] {
        var atoms: [Atom] = []
        atoms.reserveCapacity(line.count)
        tokenize(line) { atom, _ in atoms.append(atom) }
        return atoms
    }

    /// The syntax of one line as the composer shows it, in UTF-16 offsets from `base`.
    static func syntax(_ line: Substring, base: Int, into out: inout ComposerSyntax) {
        var atoms: [Atom] = []
        var ranges: [Range<Int>] = []
        atoms.reserveCapacity(line.count)
        ranges.reserveCapacity(line.count)
        tokenize(line) { atom, range in
            atoms.append(atom)
            ranges.append(range)
        }
        var offsets = [base]
        offsets.reserveCapacity(line.count + 1)
        for char in line { offsets.append(offsets[offsets.count - 1] + char.utf16.count) }
        func span(_ chars: Range<Int>) -> Range<Int> { offsets[chars.lowerBound]..<offsets[chars.upperBound] }

        Emphasis(atoms: atoms).walk(0..<atoms.count, style: []) { event in
            switch event {
            case .open(let open, let style):
                out.run(span(ranges[open]), .marker, style)
            case .close(let open, let close, let flag, let style):
                out.pairs.append(.init(open: span(ranges[open]), close: span(ranges[close]), style: flag))
                out.run(span(ranges[close]), .marker, style)
            case .atom(let index, let style):
                let chars = ranges[index]
                switch atoms[index] {
                case .char, .mention, .emoji:
                    out.run(span(chars), .text, style)
                case .code:
                    let open = chars.lowerBound..<(chars.lowerBound + 1)
                    let close = (chars.upperBound - 1)..<chars.upperBound
                    out.pairs.append(.init(open: span(open), close: span(close), style: .code))
                    out.run(span(open), .marker, style.union(.code))
                    out.run(span(open.upperBound..<close.lowerBound), .text, style.union(.code))
                    out.run(span(close), .marker, style.union(.code))
                case .link(let url, let label):
                    let head = label == nil ? 1 : url.count + 2
                    let open = chars.lowerBound..<(chars.lowerBound + head)
                    let close = (chars.upperBound - 1)..<chars.upperBound
                    out.pairs.append(
                        .init(
                            open: span(open), close: span(close), style: [],
                            link: .init(url: url, label: label ?? url)))
                    out.run(span(open), .marker, style)
                    out.run(span(open.upperBound..<close.lowerBound), .link, style)
                    out.run(span(close), .marker, style)
                }
            }
        }
    }

    /// What editing a line's markup can't keep: tokens and custom emoji outside code, with character offsets.
    static func scan(_ line: Substring, into inventory: inout MarkupInventory) {
        let indices = Array(line.indices) + [line.endIndex]
        tokenize(
            line,
            emit: { atom, range in
                switch atom {
                case .mention(let user):
                    inventory.mentions.append(
                        .init(range: indices[range.lowerBound]..<indices[range.upperBound], user: user))
                case .emoji: inventory.hasCustomEmoji = true
                case .char, .code, .link: break
                }
            }, unknownToken: { inventory.hasUnknownToken = true })
    }

    private static func tokenize(
        _ line: Substring, emit: (Atom, Range<Int>) -> Void, unknownToken: () -> Void = {}
    ) {
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "`", let close = chars[(index + 1)...].firstIndex(of: "`"), close > index + 1 {
                emit(.code(String(chars[(index + 1)..<close])), index..<(close + 1))
                index = close + 1
                continue
            }
            if char == "<", let close = chars[(index + 1)...].firstIndex(of: ">") {
                let body = String(chars[(index + 1)..<close])
                if let atom = token(body) {
                    emit(atom, index..<(close + 1))
                    index = close + 1
                    continue
                }
                if !body.isEmpty, !body.contains(where: \.isWhitespace),
                    body.contains(where: { $0 == "/" || $0 == ":" })
                {
                    unknownToken()
                }
            }
            if char == ":", let close = emojiEnd(chars, from: index) {
                emit(.emoji(String(chars[index...close])), index..<(close + 1))
                index = close + 1
                continue
            }
            emit(.char(char), index..<(index + 1))
            index += 1
        }
    }

    private static func token(_ body: String) -> Atom? {
        if let user = UserName(body) { return .mention(user) }
        if let bar = body.firstIndex(of: "|") {
            let url = String(body[..<bar])
            let label = String(body[body.index(after: bar)...])
            guard isURL(url), !label.isEmpty else { return nil }
            return .link(url: url, label: label)
        }
        let lower = body.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://"), isURL(body) else { return nil }
        return .link(url: body, label: nil)
    }

    private static func isURL(_ candidate: String) -> Bool {
        guard let colon = candidate.firstIndex(of: ":"), colon > candidate.startIndex else { return false }
        return candidate[..<colon].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
            && !candidate.contains(where: \.isWhitespace)
    }

    /// The closing colon of a `:shortcode:` that stands as its own word.
    private static func emojiEnd(_ chars: [Character], from start: Int) -> Int? {
        guard start == 0 || chars[start - 1].isWhitespace || chars[start - 1] == "(" else { return nil }
        var index = start + 1
        while index < chars.count, index - start <= 64 {
            let char = chars[index]
            if char == ":" {
                guard index > start + 1 else { return nil }
                let after = index + 1
                guard
                    after == chars.count || chars[after].isWhitespace || (chars[after] != ":" && isPunct(chars[after]))
                else { return nil }
                return index
            }
            guard char.isASCII, char.isLowercase || char.isNumber || char == "_" || char == "-" || char == "+" else {
                return nil
            }
            index += 1
        }
        return nil
    }

    static func isPunct(_ char: Character) -> Bool { char.isPunctuation || char.isSymbol }

    /// A plain space or tab. A no-break space counts as content, as it does for Google.
    static func isBreakingSpace(_ char: Character) -> Bool { char == " " || char == "\t" }

    private struct Emphasis {
        let atoms: [Atom]
        /// Valid closing positions per marker, ascending, computed once per line.
        let closers: [Character: [Int]]

        init(atoms: [Atom]) {
            self.atoms = atoms
            var closers: [Character: [Int]] = [:]
            for index in atoms.indices {
                guard case .char(let char) = atoms[index], Self.flag(char) != nil else { continue }
                if Self.canClose(atoms, index) { closers[char, default: []].append(index) }
            }
            self.closers = closers
        }

        static func flag(_ char: Character) -> Span.Style? {
            switch char {
            case "*": .bold
            case "_": .italic
            case "~": .strikethrough
            default: nil
            }
        }

        private static func isBoundary(_ atom: Atom?) -> Bool {
            guard let atom else { return true }
            guard case .char(let char) = atom else { return false }
            return char.isWhitespace || InlineParser.isPunct(char)
        }

        private static func canOpen(_ atoms: [Atom], _ index: Int, _ marker: Character) -> Bool {
            guard isBoundary(index > 0 ? atoms[index - 1] : nil), index + 1 < atoms.count else { return false }
            guard case .char(let next) = atoms[index + 1] else { return true }
            return !InlineParser.isBreakingSpace(next) && next != marker
        }

        private static func canClose(_ atoms: [Atom], _ index: Int) -> Bool {
            guard index > 0, isBoundary(index + 1 < atoms.count ? atoms[index + 1] : nil) else { return false }
            guard case .char(let previous) = atoms[index - 1] else { return true }
            return !InlineParser.isBreakingSpace(previous)
        }

        private func closer(_ marker: Character, after opener: Int, before end: Int) -> Int? {
            guard let positions = closers[marker] else { return nil }
            var low = 0
            var high = positions.count
            while low < high {
                let mid = (low + high) / 2
                if positions[mid] < opener + 2 { low = mid + 1 } else { high = mid }
            }
            guard low < positions.count, positions[low] < end else { return nil }
            return positions[low]
        }

        enum Event {
            case atom(Int, Span.Style)
            /// An emphasis marker atom, with the style around it.
            case open(Int, Span.Style)
            case close(open: Int, close: Int, flag: Span.Style, style: Span.Style)
        }

        func walk(_ range: Range<Int>, style: Span.Style, visit: (Event) -> Void) {
            var index = range.lowerBound
            while index < range.upperBound {
                if case .char(let char) = atoms[index], let flag = Self.flag(char), !style.contains(flag),
                    Self.canOpen(atoms, index, char), let close = closer(char, after: index, before: range.upperBound)
                {
                    visit(.open(index, style))
                    walk((index + 1)..<close, style: style.union(flag), visit: visit)
                    visit(.close(open: index, close: close, flag: flag, style: style))
                    index = close + 1
                    continue
                }
                visit(.atom(index, style))
                index += 1
            }
        }

        func emit(into out: inout SpanBuilder) {
            walk(0..<atoms.count, style: []) { event in
                guard case .atom(let index, let style) = event else { return }
                switch atoms[index] {
                case .char(let char):
                    out.append(String(char), style: style)
                case .code(let code):
                    out.add(Span(code, style: style.union(.code)))
                case .mention(let user):
                    out.add(Span("", style: style, kind: .mention(user)))
                case .link(let url, let label):
                    out.add(Span(label ?? url, style: style, kind: .link(url)))
                case .emoji(let shortcode):
                    out.add(Span(shortcode, style: style, kind: .customEmoji))
                }
            }
        }
    }
}

/// Merges adjacent plain text of one style into a single span.
struct SpanBuilder {
    var spans: [Span] = []

    mutating func append(_ text: String, style: Span.Style) {
        if let last = spans.last, last.kind == .text, last.style == style, !style.contains(.code) {
            spans[spans.count - 1].text += text
        } else {
            spans.append(Span(text, style: style))
        }
    }

    mutating func add(_ span: Span) { spans.append(span) }
}
