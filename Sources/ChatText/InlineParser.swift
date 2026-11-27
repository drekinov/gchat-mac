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
            Emphasis(atoms: atoms).emit(0..<atoms.count, style: [], into: &out)
        }
        return out.spans
    }

    private static func tokenize(_ line: Substring) -> [Atom] {
        let chars = Array(line)
        var atoms: [Atom] = []
        atoms.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "`", let close = chars[(index + 1)...].firstIndex(of: "`"), close > index + 1 {
                atoms.append(.code(String(chars[(index + 1)..<close])))
                index = close + 1
                continue
            }
            if char == "<", let close = chars[(index + 1)...].firstIndex(of: ">"),
                let atom = token(String(chars[(index + 1)..<close]))
            {
                atoms.append(atom)
                index = close + 1
                continue
            }
            if char == ":", let close = emojiEnd(chars, from: index) {
                atoms.append(.emoji(String(chars[index...close])))
                index = close + 1
                continue
            }
            atoms.append(.char(char))
            index += 1
        }
        return atoms
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

        func emit(_ range: Range<Int>, style: Span.Style, into out: inout SpanBuilder) {
            var index = range.lowerBound
            while index < range.upperBound {
                switch atoms[index] {
                case .char(let char):
                    if let flag = Self.flag(char), !style.contains(flag), Self.canOpen(atoms, index, char),
                        let close = closer(char, after: index, before: range.upperBound)
                    {
                        emit((index + 1)..<close, style: style.union(flag), into: &out)
                        index = close + 1
                        continue
                    }
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
                index += 1
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
