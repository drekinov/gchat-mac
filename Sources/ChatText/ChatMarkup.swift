import ChatModel

/// A message's Google Chat markup (`formattedText`), parsed into blocks of styled spans.
public struct ChatDocument: Hashable, Sendable {
    public enum Block: Hashable, Sendable {
        /// One or more lines, joined with `\n` inside the spans.
        case paragraph([Span])
        case quote([Span])
        case list([ListItem])
        /// `source` is the fenced markup as written, which Google's plain text keeps.
        case code(String, source: String)
    }

    public struct ListItem: Hashable, Sendable {
        /// Nesting depth, from zero.
        public var level: Int
        public var spans: [Span]

        public init(level: Int, spans: [Span]) {
            self.level = level
            self.spans = spans
        }
    }

    public var blocks: [Block]

    public init(blocks: [Block]) { self.blocks = blocks }

    /// True when the document is one paragraph of unstyled text and mentions, which plain rendering shows the same.
    public var isPlain: Bool {
        guard blocks.count <= 1 else { return false }
        guard case .paragraph(let spans)? = blocks.first else { return blocks.isEmpty }
        return spans.allSatisfy { span in
            guard span.style.isEmpty else { return false }
            switch span.kind {
            case .text, .mention: return true
            case .link, .customEmoji: return false
            }
        }
    }
}

public struct Span: Hashable, Sendable {
    public struct Style: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let bold = Style(rawValue: 1 << 0)
        public static let italic = Style(rawValue: 1 << 1)
        public static let strikethrough = Style(rawValue: 1 << 2)
        public static let code = Style(rawValue: 1 << 3)
    }

    public enum Kind: Hashable, Sendable {
        case text
        /// The link's target as written; the span's text is its label.
        case link(String)
        /// The span's text is empty until `ChatMarkup.resolve` fills in the `@Name` that Google's text shows.
        case mention(UserName)
        case customEmoji
    }

    public var text: String
    public var style: Style
    public var kind: Kind

    public init(_ text: String, style: Style = [], kind: Kind = .text) {
        self.text = text
        self.style = style
        self.kind = kind
    }
}

public enum ChatMarkup {
    /// Parses Chat syntax. Anything that isn't well-formed markup stays literal text.
    public static func parse(_ markup: String) -> ChatDocument {
        let lines = markup.split(separator: "\n", omittingEmptySubsequences: false)
        var blocks: [ChatDocument.Block] = []
        var paragraph: [Substring] = []
        var quote: [Substring] = []
        var items: [ChatDocument.ListItem] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(InlineParser.spans(paragraph))) }
            if !quote.isEmpty { blocks.append(.quote(InlineParser.spans(quote))) }
            if !items.isEmpty { blocks.append(.list(items)) }
            paragraph = []
            quote = []
            items = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let end = fenceEnd(lines, from: index) {
                flush()
                blocks.append(fence(lines[index...end]))
                index = end + 1
                continue
            }
            if let (level, content) = listItem(line) {
                if items.isEmpty { flush() }
                items.append(.init(level: level, spans: InlineParser.spans([content])))
            } else if let content = quoteLine(line) {
                if quote.isEmpty { flush() }
                quote.append(content)
            } else {
                if paragraph.isEmpty { flush() }
                paragraph.append(line)
            }
            index += 1
        }
        flush()
        return ChatDocument(blocks: blocks)
    }

    /// The parsed markup with each mention's text taken from Google's plain `text`, or nil unless the document's
    /// plain projection is exactly `text` and every user mention matches one annotation at its offset. Only `@all`
    /// may appear without an annotation.
    public static func resolve(markup: String, text: String, annotations: [Annotation]) -> ChatDocument? {
        var document = parse(markup)
        var matcher = Matcher(text: text, annotations: annotations)
        document.project(into: &matcher)
        return matcher.finished ? document : nil
    }

    private static func fenceEnd(_ lines: [Substring], from start: Int) -> Int? {
        let first = lines[start]
        guard first.hasPrefix("```") else { return nil }
        if first.count >= 6, first.hasSuffix("```") { return start }
        return lines[(start + 1)...].firstIndex { $0.hasSuffix("```") }
    }

    private static func fence(_ lines: ArraySlice<Substring>) -> ChatDocument.Block {
        let source = lines.joined(separator: "\n")
        var body = source.dropFirst(3).dropLast(3)
        if body.first == "\n" { body = body.dropFirst() }
        if body.last == "\n" { body = body.dropLast() }
        return .code(String(body), source: source)
    }

    private static func listItem(_ line: Substring) -> (Int, Substring)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent.isMultiple(of: 4) else { return nil }
        let rest = line.dropFirst(indent)
        guard rest.hasPrefix("* ") || rest.hasPrefix("- ") else { return nil }
        return (indent / 4, rest.dropFirst(2))
    }

    private static func quoteLine(_ line: Substring) -> Substring? {
        if line == ">" { return line.dropFirst() }
        return line.hasPrefix("> ") ? line.dropFirst(2) : nil
    }
}

extension ChatDocument {
    /// The plain text Google derives from this markup: emphasis markers, list prefixes and link targets go, code
    /// keeps its backticks and fences, and each mention reads as `mention(user)`.
    public func visibleText(mention: @escaping (UserName) -> String) -> String {
        var copy = self
        var builder = TextBuilder(mention: mention)
        copy.project(into: &builder)
        return builder.text
    }

    fileprivate mutating func project(into sink: inout some ProjectionSink) {
        for index in blocks.indices {
            if index > 0 { sink.append("\n") }
            switch blocks[index] {
            case .paragraph(var spans):
                Self.project(&spans, into: &sink)
                blocks[index] = .paragraph(spans)
            case .quote(var spans):
                Self.project(&spans, into: &sink)
                blocks[index] = .quote(spans)
            case .list(var items):
                for item in items.indices {
                    if item > 0 { sink.append("\n") }
                    Self.project(&items[item].spans, into: &sink)
                }
                blocks[index] = .list(items)
            case .code(_, let source):
                sink.append(source)
            }
            if sink.failed { return }
        }
    }

    private static func project(_ spans: inout [Span], into sink: inout some ProjectionSink) {
        for index in spans.indices where !sink.failed {
            let span = spans[index]
            switch span.kind {
            case .mention(let user):
                if let text = sink.mention(user) { spans[index].text = text }
            case .text where span.style.contains(.code):
                sink.append("`")
                sink.append(span.text)
                sink.append("`")
            case .text, .link, .customEmoji:
                sink.append(span.text)
            }
        }
    }
}

private protocol ProjectionSink {
    var failed: Bool { get }
    mutating func append(_ string: String)
    /// The text a mention of `user` projects to, already appended.
    mutating func mention(_ user: UserName) -> String?
}

private struct TextBuilder: ProjectionSink {
    let mentionText: (UserName) -> String
    var text = ""
    var failed: Bool { false }

    init(mention: @escaping (UserName) -> String) { mentionText = mention }

    mutating func append(_ string: String) { text += string }

    mutating func mention(_ user: UserName) -> String? {
        let mention = mentionText(user)
        text += mention
        return mention
    }
}

/// Follows a projection along Google's `text`, failing at the first difference.
private struct Matcher: ProjectionSink {
    let units: [UInt16]
    var offset = 0
    var mentions: ArraySlice<(user: UserName, start: Int, length: Int)>
    var failed = false

    init(text: String, annotations: [Annotation]) {
        units = Array(text.utf16)
        mentions = ArraySlice(
            annotations.compactMap { annotation in
                guard case .userMention(let user) = annotation.kind else { return nil }
                return (user, annotation.startIndex, annotation.length)
            }
            .sorted { $0.start < $1.start })
    }

    var finished: Bool { !failed && offset == units.count && mentions.isEmpty }

    mutating func append(_ string: String) {
        guard !failed else { return }
        for unit in string.utf16 {
            guard offset < units.count, units[offset] == unit else {
                failed = true
                return
            }
            offset += 1
        }
    }

    mutating func mention(_ user: UserName) -> String? {
        guard !failed else { return nil }
        guard let next = mentions.first, next.user == user, next.start == offset, next.length > 0,
            offset + next.length <= units.count, units[offset] == 0x40
        else {
            // Google often sends `@all` without an annotation.
            guard user == .all else {
                failed = true
                return nil
            }
            append("@all")
            return failed ? nil : "@all"
        }
        mentions.removeFirst()
        defer { offset += next.length }
        return String(decoding: Array(units[offset..<(offset + next.length)]), as: UTF16.self)
    }
}
