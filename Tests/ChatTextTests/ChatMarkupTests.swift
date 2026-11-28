import ChatModel
import ChatText
import Testing

private let alex = UserName(unchecked: "users/1")
private let sam = UserName(unchecked: "users/2")

private func spans(_ markup: String) -> [Span] {
    guard case .paragraph(let spans)? = ChatMarkup.parse(markup).blocks.first else { return [] }
    return spans
}

private func mention(_ user: UserName, at start: Int, _ length: Int) -> Annotation {
    Annotation(kind: .userMention(user), startIndex: start, length: length)
}

@Suite struct InlineTests {
    @Test func emphasisStyles() {
        #expect(
            spans("a *b* _c_ ~d~ `e`") == [
                Span("a "), Span("b", style: .bold), Span(" "), Span("c", style: .italic), Span(" "),
                Span("d", style: .strikethrough), Span(" "), Span("e", style: .code),
            ])
    }

    @Test func interiorSpacesAndNesting() {
        #expect(spans("*has arrived*") == [Span("has arrived", style: .bold)])
        #expect(
            spans("*bold _both_*") == [Span("bold ", style: .bold), Span("both", style: [.bold, .italic])])
    }

    @Test func markersNeedWordBoundaries() {
        #expect(spans("snake_case_name") == [Span("snake_case_name")])
        #expect(spans("2*3*4") == [Span("2*3*4")])
        #expect(spans("a * not bold *") == [Span("a * not bold *")])
        #expect(spans("(*yes*).") == [Span("("), Span("yes", style: .bold), Span(").")])
    }

    @Test func noBreakSpaceCountsAsContent() {
        #expect(spans("*\u{a0}x*") == [Span("\u{a0}x", style: .bold)])
    }

    @Test func unmatchedMarkersStayLiteral() {
        #expect(spans("*open") == [Span("*open")])
        #expect(spans("a ~b") == [Span("a ~b")])
        #expect(spans("``") == [Span("``")])
    }

    @Test func emphasisNeverSpansLines() {
        #expect(spans("*a\nb*") == [Span("*a\nb*")])
    }

    @Test func codeIsLiteral() {
        #expect(spans("`*x* <users/1> :e:`") == [Span("*x* <users/1> :e:", style: .code)])
    }

    @Test func tokens() {
        #expect(
            spans("hi <users/1>, see <https://example.com/a?b=c|d&e=f|the doc> or <https://example.com>") == [
                Span("hi "), Span("", kind: .mention(alex)), Span(", see "),
                Span("d&e=f|the doc", kind: .link("https://example.com/a?b=c")), Span(" or "),
                Span("https://example.com", kind: .link("https://example.com")),
            ])
        #expect(spans("a <b> <users/x y> <x|>") == [Span("a <b> <users/x y> <x|>")])
        #expect(spans("*<users/1>*") == [Span("", style: .bold, kind: .mention(alex))])
    }

    @Test func customEmoji() {
        #expect(spans(":party: at 10:30:00") == [Span(":party:", kind: .customEmoji), Span(" at 10:30:00")])
    }
}

@Suite struct BlockTests {
    @Test func fencedCode() {
        let source = "```\nlet x = *1*\n```"
        #expect(
            ChatMarkup.parse("run:\n" + source + "\ndone").blocks == [
                .paragraph([Span("run:")]), .code("let x = *1*", source: source), .paragraph([Span("done")]),
            ])
    }

    @Test func oneLineFenceAndLanguageTagStayInTheCode() {
        #expect(ChatMarkup.parse("```x```").blocks == [.code("x", source: "```x```")])
        #expect(
            ChatMarkup.parse("```swift\nprint()\n```").blocks == [
                .code("swift\nprint()", source: "```swift\nprint()\n```")
            ])
    }

    @Test func unclosedFenceStaysLiteral() {
        #expect(ChatMarkup.parse("```\n*a*").blocks == [.paragraph([Span("```\n"), Span("a", style: .bold)])])
    }

    @Test func nestedBullets() {
        #expect(
            ChatMarkup.parse("* a\n    - b\n* *c*").blocks == [
                .list([
                    .init(level: 0, spans: [Span("a")]), .init(level: 1, spans: [Span("b")]),
                    .init(level: 0, spans: [Span("c", style: .bold)]),
                ])
            ])
        #expect(ChatMarkup.parse("  * two spaces").blocks == [.paragraph([Span("  * two spaces")])])
    }

    @Test func quotes() {
        #expect(
            ChatMarkup.parse("> a\n> _b_\nc").blocks == [
                .quote([Span("a\n"), Span("b", style: .italic)]), .paragraph([Span("c")]),
            ])
    }

    @Test func plainDocuments() {
        #expect(ChatMarkup.parse("hi <users/1>\nthere").isPlain)
        #expect(!ChatMarkup.parse("hi *there*").isPlain)
        #expect(!ChatMarkup.parse("* item").isPlain)
    }

    @Test func longLinesOfMarkersParse() {
        let line = String(repeating: "*a ", count: 10_000)
        #expect(ChatMarkup.parse(line).blocks == [.paragraph([Span(line)])])
    }
}

@Suite struct ResolveTests {
    @Test func visibleTextFollowsGoogle() {
        let document = ChatMarkup.parse("*Hi* <users/1>\n* `x` <https://example.com|doc>\n```\ncode\n```")
        #expect(document.visibleText { _ in "@Alex" } == "Hi @Alex\n`x` doc\n```\ncode\n```")
    }

    @Test func mentionsTakeTheirTextFromAnnotations() throws {
        let document = try #require(
            ChatMarkup.resolve(
                markup: "*hey* <users/1> and <users/1>", text: "hey @Alex and @Alex",
                annotations: [mention(alex, at: 14, 5), mention(alex, at: 4, 5)]))
        guard case .paragraph(let spans) = document.blocks[0] else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(spans.filter { $0.kind == .mention(alex) }.map(\.text) == ["@Alex", "@Alex"])
    }

    @Test func mentionsMatchOneToOneByRange() {
        let text = "@Alex and @Alex"
        #expect(
            ChatMarkup.resolve(markup: "@Alex and <users/1>", text: text, annotations: [mention(alex, at: 10, 5)])
                != nil)
        #expect(
            ChatMarkup.resolve(markup: "@Alex and <users/1>", text: text, annotations: [mention(alex, at: 0, 5)])
                == nil)
        #expect(ChatMarkup.resolve(markup: "@Alex and <users/1>", text: text, annotations: []) == nil)
        #expect(
            ChatMarkup.resolve(
                markup: "@Alex and <users/1>", text: text, annotations: [mention(sam, at: 10, 5)]) == nil)
        #expect(
            ChatMarkup.resolve(
                markup: "@Alex and @Alex", text: text, annotations: [mention(alex, at: 10, 5)]) == nil)
    }

    @Test func allMayComeWithoutAnAnnotation() {
        #expect(ChatMarkup.resolve(markup: "<users/all> *now*", text: "@all now", annotations: []) != nil)
        #expect(
            ChatMarkup.resolve(
                markup: "<users/all> now", text: "@all now", annotations: [mention(.all, at: 0, 4)]) != nil)
    }

    @Test func literalMarkersDoNotResolve() {
        #expect(ChatMarkup.resolve(markup: "*kept*", text: "*kept*", annotations: []) == nil)
        #expect(ChatMarkup.resolve(markup: "a `b`", text: "a `b`", annotations: []) != nil)
    }
}
