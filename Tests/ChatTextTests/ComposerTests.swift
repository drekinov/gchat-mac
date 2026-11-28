import ChatModel
import ChatText
import Testing

private let ann = UserName(unchecked: "users/1")

private func range(of needle: String, in text: String) -> Range<Int> {
    guard let found = text.range(of: needle) else { return 0..<0 }
    let lower = text.utf16.distance(from: text.utf16.startIndex, to: found.lowerBound)
    return lower..<(lower + needle.utf16.count)
}

private func caret(_ offset: Int) -> Range<Int> { offset..<offset }

/// Each visible character with its style, line breaks left out, as the composer's runs show it.
private func styledByRuns(_ text: String, _ runs: [ComposerRun]) -> [(Character, Span.Style)] {
    var out: [(Character, Span.Style)] = []
    var offset = 0
    for char in text {
        defer { offset += char.utf16.count }
        guard char != "\n" else { continue }
        let run = runs.first { $0.range.contains(offset) }
        if run?.kind == .marker { continue }
        out.append((char, run?.style ?? []))
    }
    return out
}

/// The same, from what the message view renders.
private func styledByParse(_ markup: String) -> [(Character, Span.Style)] {
    func flat(_ spans: [Span]) -> [(Character, Span.Style)] {
        spans.flatMap { span in span.text.filter { $0 != "\n" }.map { ($0, span.style) } }
    }
    return ChatMarkup.parse(markup).blocks.flatMap { block -> [(Character, Span.Style)] in
        switch block {
        case .paragraph(let spans), .quote(let spans): flat(spans)
        case .list(let items): items.flatMap { flat($0.spans) }
        case .code(let body, _): body.filter { $0 != "\n" }.map { ($0, .code) }
        }
    }
}

private func same(_ a: [(Character, Span.Style)], _ b: [(Character, Span.Style)]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

@Suite struct ComposerRunTests {
    @Test func runsAgreeWithTheParser() {
        let inputs = [
            "a *b* _c_ ~d~ `e`", "*has arrived*", "*bold _both_*", "snake_case_name", "2*3*4", "a * not bold *",
            "(*yes*).", "*\u{a0}x*", "*open", "a ~b", "``", "*a\nb*", "`*x* :e:`",
            "see <https://example.com/a?b=c|d&e=f|the doc> or <https://example.com>",
            "* a\n    - b\n* *c*", "> a\n> _b_\nc", "run:\n```\nlet x = *1*\n```\ndone", "```x```",
            "👩‍👩‍👧 *bold* 🇧🇬 _it_ 🙂", "*🚀 now*",
        ]
        for input in inputs {
            #expect(
                same(styledByRuns(input, ChatMarkup.composerRuns(input)), styledByParse(input)), "\(input)")
        }
    }

    @Test func offsetsCountUTF16AfterEmoji() {
        let family = "👩‍👩‍👧"
        let text = family + " *b*"
        let start = family.utf16.count + 1
        #expect(
            ChatMarkup.composerRuns(text) == [
                ComposerRun(range: start..<(start + 1), kind: .marker, style: []),
                ComposerRun(range: (start + 1)..<(start + 2), kind: .text, style: .bold),
                ComposerRun(range: (start + 2)..<(start + 3), kind: .marker, style: []),
            ])
    }

    @Test func linksDimTheirTarget() {
        let text = "<https://example.com|doc>"
        #expect(
            ChatMarkup.composerRuns(text) == [
                ComposerRun(range: 0..<21, kind: .marker, style: []),
                ComposerRun(range: 21..<24, kind: .link, style: []),
                ComposerRun(range: 24..<25, kind: .marker, style: []),
            ])
    }

    @Test func prefixesAndCodeAreMarked() {
        #expect(
            ChatMarkup.composerRuns("* a `b`") == [
                ComposerRun(range: 0..<2, kind: .marker, style: []),
                ComposerRun(range: 4..<5, kind: .marker, style: .code),
                ComposerRun(range: 5..<6, kind: .text, style: .code),
                ComposerRun(range: 6..<7, kind: .marker, style: .code),
            ])
    }

    @Test func anOpenFenceStylesTheRestAsCode() {
        #expect(
            ChatMarkup.composerRuns("```\n*a*") == [
                ComposerRun(range: 0..<3, kind: .marker, style: .code),
                ComposerRun(range: 3..<7, kind: .text, style: .code),
            ])
    }

    @Test func restylingSomeLinesMatchesTheWhole() {
        let text = "first *one*\nmid _two_ 🙂\nlast ~three~"
        let lines = ChatMarkup.lineRange(text, covering: range(of: "two", in: text))
        #expect(lines == range(of: "mid _two_ 🙂", in: text))
        let piece = ChatMarkup.composerRuns("mid _two_ 🙂").map { run in
            ComposerRun(
                range: (run.range.lowerBound + lines.lowerBound)..<(run.range.upperBound + lines.lowerBound),
                kind: run.kind, style: run.style)
        }
        #expect(piece == ChatMarkup.composerRuns(text).filter { lines.contains($0.range.lowerBound) })
    }

    @Test func fencesAreFoundAtLineStarts() {
        #expect(ChatMarkup.hasFence("a\n```b"))
        #expect(ChatMarkup.hasFence("```"))
        #expect(!ChatMarkup.hasFence("a ```b```"))
        #expect(!ChatMarkup.hasFence("``\n`"))
    }

    @Test func returnStaysInsideAnOpenOrClosedBlock() {
        let open = "Try:\n```\ngit fetch"
        #expect(ChatMarkup.isInsideCodeBlock(open, at: open.utf16.count))
        #expect(ChatMarkup.isInsideCodeBlock(open, at: 8))
        #expect(!ChatMarkup.isInsideCodeBlock(open, at: 4))
        let closed = "```\nx\n```"
        #expect(ChatMarkup.isInsideCodeBlock(closed, at: 5))
        #expect(ChatMarkup.isInsideCodeBlock(closed, at: 6))
        #expect(!ChatMarkup.isInsideCodeBlock(closed, at: closed.utf16.count))
        #expect(!ChatMarkup.isInsideCodeBlock(closed + "\nafter", at: closed.utf16.count + 6))
        #expect(!ChatMarkup.isInsideCodeBlock("plain `x`", at: 8))
    }
}

/// Applies an action the way the composer does and returns the text, the wire text and the selection.
private func run(
    _ action: FormatAction, _ text: String, _ selection: Range<Int>, mentions: [MentionText.Mention] = []
) -> (text: String, wire: String, selection: Range<Int>)? {
    var editor = MentionEditor(mentions: mentions)
    guard let result = action.apply(to: text, selection: selection, mentions: editor.ranges) else { return nil }
    let out = TextEdit.apply(result.edits, to: text)
    editor.apply(result.edits)
    return (out, editor.wireText(out, names: [:]), result.selection)
}

private func paragraph(_ wire: String) -> [Span] {
    guard case .paragraph(let spans)? = ChatMarkup.parse(wire).blocks.first else { return [] }
    return spans
}

private func annMention(in text: String) -> MentionText.Mention {
    MentionText.Mention(range: range(of: "@Ann Lee", in: text), user: ann, token: "@Ann Lee")
}

@Suite struct InlineFormatTests {
    @Test func boldWrapsTheSelection() throws {
        let text = "make it bold"
        let done = try #require(run(.bold, text, range(of: "bold", in: text)))
        #expect(done.text == "make it *bold*")
        #expect(done.selection == 9..<13)
        #expect(paragraph(done.wire) == [Span("make it "), Span("bold", style: .bold)])
    }

    @Test func whitespaceIsTrimmedAndWordsWidened() throws {
        let text = "make it bold now"
        #expect(try #require(run(.bold, text, range(of: " bold ", in: text))).text == "make it *bold* now")
        #expect(try #require(run(.italic, text, range(of: "ol", in: text))).text == "make it _bold_ now")
        #expect(try #require(run(.strikethrough, text, range(of: "it bo", in: text))).text == "make ~it bold~ now")
        #expect(try #require(run(.bold, text, caret(10))).text == "make it *bold* now")
    }

    @Test func aCaretBetweenWordsGetsAnEmptyPair() throws {
        let done = try #require(run(.bold, "a  b", caret(2)))
        #expect(done.text == "a ** b")
        #expect(done.selection == caret(3))
    }

    @Test func pressingAgainRemovesTheStyle() throws {
        let text = "a *bold* b"
        for selection in [caret(4), range(of: "bold", in: text), range(of: "*bold*", in: text)] {
            let done = try #require(run(.bold, text, selection))
            #expect(done.text == "a bold b")
            #expect(paragraph(done.wire) == [Span("a bold b")])
        }
        #expect(FormatAction.state(in: text, selection: caret(4), mentions: []).active == [.bold])
    }

    @Test func eachNonEmptyLineGetsMarkers() throws {
        let text = "one\n\n two "
        let done = try #require(run(.italic, text, 0..<text.utf16.count))
        #expect(done.text == "_one_\n\n _two_ ")
        #expect(
            ChatMarkup.parse(done.wire).blocks == [
                .paragraph([Span("one", style: .italic), Span("\n\n "), Span("two", style: .italic), Span(" ")])
            ])
    }

    @Test func sameStyleInsideTheSelectionMerges() throws {
        let done = try #require(run(.bold, "a *b* c", 0..<7))
        #expect(done.text == "*a b c*")
        #expect(paragraph(done.wire) == [Span("a b c", style: .bold)])
    }

    @Test func mentionsInsideTheSelectionSurvive() throws {
        let text = "hi @Ann Lee there"
        let done = try #require(run(.bold, text, range(of: "Lee there", in: text), mentions: [annMention(in: text)]))
        #expect(done.text == "hi *@Ann Lee there*")
        #expect(done.wire == "hi *<users/1> there*")
        #expect(
            paragraph(done.wire) == [
                Span("hi "), Span("", style: .bold, kind: .mention(ann)), Span(" there", style: .bold),
            ])
    }

    @Test func emojiInsideTheSelection() throws {
        let text = "👩‍👩‍👧 go 🚀 now"
        let done = try #require(run(.bold, text, range(of: "🚀 now", in: text)))
        #expect(done.text == "👩‍👩‍👧 go *🚀 now*")
        #expect(paragraph(done.wire) == [Span("👩‍👩‍👧 go "), Span("🚀 now", style: .bold)])
    }

    @Test func inlineCode() throws {
        let text = "run make now"
        let done = try #require(run(.code, text, range(of: "make", in: text)))
        #expect(done.text == "run `make` now")
        #expect(paragraph(done.wire) == [Span("run "), Span("make", style: .code), Span(" now")])
        #expect(try #require(run(.code, done.text, caret(6))).text == text)
        #expect(run(.code, "a ` b", 0..<5) == nil)
    }

    @Test func codeAndLinksSkipMentions() {
        let text = "ping @Ann Lee now"
        let mention = annMention(in: text)
        let selection = range(of: "Lee now", in: text)
        #expect(run(.code, text, selection, mentions: [mention]) == nil)
        #expect(run(.codeBlock, text, selection, mentions: [mention]) == nil)
        let state = FormatAction.state(in: text, selection: selection, mentions: [mention.range])
        #expect(state.unavailable == [.code, .codeBlock, .link])
        #expect(
            FormatAction.link(
                url: "https://example.com", label: "x", in: text, selection: selection, mentions: [mention.range])
                == nil)
    }

    @Test func inlineStylesSkipCodeBlocks() {
        let text = "```\nx\n```"
        #expect(run(.bold, text, caret(4)) == nil)
        #expect(FormatAction.state(in: text, selection: caret(4), mentions: []).active == [.codeBlock])
    }
}

@Suite struct BlockFormatTests {
    @Test func codeBlockWrapsWholeLines() throws {
        let text = "see\nlet a = 1\nlet b = 2"
        let done = try #require(run(.codeBlock, text, range(of: "a = 1\nlet", in: text)))
        #expect(done.text == "see\n```\nlet a = 1\nlet b = 2\n```")
        #expect(
            ChatMarkup.parse(done.wire).blocks.last
                == .code("let a = 1\nlet b = 2", source: "```\nlet a = 1\nlet b = 2\n```"))
        let back = try #require(run(.codeBlock, done.text, caret(10)))
        #expect(back.text == text)
    }

    @Test func codeBlockOnAnEmptyLine() throws {
        let done = try #require(run(.codeBlock, "", caret(0)))
        #expect(done.text == "```\n\n```")
        #expect(done.selection == caret(4))
        #expect(try #require(run(.codeBlock, done.text, caret(4))).text == "")
        #expect(try #require(run(.codeBlock, "```x```", caret(4))).text == "x")
        #expect(try #require(run(.codeBlock, "```\nopen", caret(6))).text == "open")
    }

    @Test func bulletsToggleOnEachLine() throws {
        let text = "a\n\nb"
        let done = try #require(run(.bullet, text, 0..<4))
        #expect(done.text == "* a\n\n* b")
        #expect(done.selection == 0..<8)
        #expect(
            ChatMarkup.parse(done.wire).blocks == [
                .list([.init(level: 0, spans: [Span("a")])]), .paragraph([]),
                .list([.init(level: 0, spans: [Span("b")])]),
            ])
        #expect(try #require(run(.bullet, done.text, 0..<8)).text == text)
        #expect(try #require(run(.bullet, "* a\nb", 0..<5)).text == "* a\n* b")
        #expect(try #require(run(.bullet, "", caret(0))).text == "* ")
        #expect(try #require(run(.bullet, "    x", caret(5))).text == "    * x")
    }

    @Test func quotesToggleOnEachLine() throws {
        let text = "a\nb"
        let done = try #require(run(.quote, text, 0..<3))
        #expect(done.text == "> a\n> b")
        #expect(ChatMarkup.parse(done.wire).blocks == [.quote([Span("a\nb")])])
        #expect(try #require(run(.quote, done.text, caret(5))).text == "> a\nb")
    }

    @Test func blockPrefixesKeepMentions() throws {
        let text = "hey @Ann Lee"
        let done = try #require(run(.quote, text, caret(0), mentions: [annMention(in: text)]))
        #expect(done.wire == "> hey <users/1>")
        #expect(ChatMarkup.parse(done.wire).blocks == [.quote([Span("hey "), Span("", kind: .mention(ann))])])
    }
}

@Suite struct LinkFormatTests {
    @Test func linkReplacesTheSelection() throws {
        let text = "see the docs"
        let selection = range(of: "the docs", in: text)
        #expect(FormatAction.linkDraft(in: text, selection: selection) == ("the docs", nil))
        let result = try #require(
            FormatAction.link(
                url: " https://example.com/d ", label: "the docs", in: text, selection: selection, mentions: []))
        let out = TextEdit.apply(result.edits, to: text)
        #expect(out == "see <https://example.com/d|the docs>")
        #expect(result.selection == caret(out.utf16.count))
        #expect(paragraph(out) == [Span("see "), Span("the docs", kind: .link("https://example.com/d"))])
    }

    @Test func linkEditsTheLinkAtTheCaret() throws {
        let text = "a <https://example.com/old|old> b"
        #expect(FormatAction.linkDraft(in: text, selection: caret(28)) == ("old", "https://example.com/old"))
        #expect(FormatAction.state(in: text, selection: caret(28), mentions: []).active == [.link])
        let result = try #require(
            FormatAction.link(
                url: "https://example.com/new", label: "new>\n", in: text, selection: caret(28), mentions: []))
        #expect(TextEdit.apply(result.edits, to: text) == "a <https://example.com/new|new> b")
        let bare = try #require(
            FormatAction.link(url: "https://example.com", label: "", in: "", selection: caret(0), mentions: []))
        #expect(TextEdit.apply(bare.edits, to: "") == "<https://example.com>")
    }

    @Test func onlyHTTPSLinksWithAHost() {
        #expect(FormatAction.linkTarget("https://example.com/a?b=c") == "https://example.com/a?b=c")
        for bad in ["http://example.com", "https://", "https://exa mple.com", "ftp://example.com", "https://a|b", "x"] {
            #expect(FormatAction.linkTarget(bad) == nil, "\(bad)")
        }
    }
}

@Suite struct MentionEditTests {
    private func mention(_ range: Range<Int>) -> MentionText.Mention {
        MentionText.Mention(range: range, user: ann, token: nil)
    }

    @Test func editsShiftBorderingMentionsAndDropCutOnes() {
        var editor = MentionEditor(mentions: [mention(2..<6), mention(10..<14)])
        editor.apply([
            TextEdit(range: 2..<2, replacement: "**"), TextEdit(range: 6..<6, replacement: "*"),
            TextEdit(range: 11..<12, replacement: ""),
        ])
        #expect(editor.ranges == [4..<8])
        var inside = MentionEditor(mentions: [mention(2..<6)])
        inside.apply([TextEdit(range: 3..<3, replacement: "x")])
        #expect(inside.ranges.isEmpty)
    }

    @Test func undoAndRedoBringMentionsBack() throws {
        let typed = "hi @Ann Lee"
        var editor = MentionEditor(mentions: [annMention(in: typed)])
        editor.remember(typed)
        let result = try #require(FormatAction.bold.apply(to: typed, selection: 0..<11, mentions: editor.ranges))
        let wrapped = TextEdit.apply(result.edits, to: typed)
        editor.apply(result.edits)
        editor.remember(wrapped)
        #expect(editor.wireText(wrapped, names: [:]) == "*hi <users/1>*")

        var diffOnly = editor
        diffOnly.applyEdit(old: wrapped, new: typed)
        #expect(diffOnly.mentions.isEmpty)

        let undone = editor.recall(typed)
        #expect(undone)
        #expect(editor.wireText(typed, names: [:]) == "hi <users/1>")
        let redone = editor.recall(wrapped)
        #expect(redone)
        #expect(editor.wireText(wrapped, names: [:]) == "*hi <users/1>*")
        let unknown = editor.recall("something else")
        #expect(!unknown)
    }

    @Test func insertionReplacesTheTypedPrefix() throws {
        var editor = MentionEditor()
        let text = "hi @an"
        let trigger = try #require(editor.trigger(in: text, caret: nil))
        let done = editor.insert(ann, token: "@Ann Lee", into: text, trigger: trigger)
        #expect(done.text == "hi @Ann Lee ")
        #expect(done.caret == 12)
        #expect(editor.wireText(done.text, names: [:]) == "hi <users/1> ")
    }
}
