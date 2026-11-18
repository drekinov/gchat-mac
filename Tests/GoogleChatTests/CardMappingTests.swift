import ChatModel
import Foundation
import Testing

@testable import GoogleChat

@Suite struct CardMappingTests {
    private func message(_ extra: String) throws -> Message {
        let json = #"{"name":"spaces/AAAA/messages/C1","createTime":"2026-10-14T12:00:00Z",\#(extra)}"#
        return try JSONDecoder.chat.decode(Wire.MessageDTO.self, from: Data(json.utf8)).domain()
    }

    @Test func legacyCardsMapHeaderAndTextSections() throws {
        let mapped = try message(
            """
            "cards":[{"header":{"title":"Build failed","subtitle":"main"},
              "sections":[{"widgets":[{"textParagraph":{"text":"first"}}]},
                          {"widgets":[{"textParagraph":{"text":"second"}}]}]}]
            """)
        #expect(
            mapped.cards == [
                Card(
                    title: "Build failed", subtitle: "main",
                    sections: [
                        CardSection(widgets: [.text("first")]), CardSection(widgets: [.text("second")]),
                    ])
            ])
        #expect(mapped.text == "")
        #expect(mapped.cardsFallbackText == nil)
    }

    @Test func legacyKeyValueButtonsAndImage() throws {
        let mapped = try message(
            """
            "cards":[{"sections":[{"header":"Details","widgets":[
              {"keyValue":{"topLabel":"Status","content":"<b>Red</b>","bottomLabel":"since 9am",
                           "button":{"textButton":{"text":"Open","onClick":{"openLink":{"url":"https://example.com/a"}}}}}},
              {"buttons":[{"textButton":{"text":"Logs","onClick":{"openLink":{"url":"https://example.com/l"}}}},
                          {"imageButton":{"name":"Docs","onClick":{"openLink":{"url":"http://insecure.example"}}}}]},
              {"image":{"imageUrl":"https://example.com/i.png"}}
            ]}]}]
            """)
        let section = try #require(mapped.cards?.first?.sections.first)
        #expect(section.header == "Details")
        #expect(
            section.widgets == [
                .keyValue(top: "Status", content: "Red", bottom: "since 9am"),
                .buttons([CardButton(text: "Open", url: URL(string: "https://example.com/a"))]),
                .buttons([
                    CardButton(text: "Logs", url: URL(string: "https://example.com/l")),
                    CardButton(text: "Docs", url: nil),
                ]),
                .image(alt: nil),
            ])
    }

    @Test func cardsV2MapAllWidgetKindsAndFlattenColumns() throws {
        let mapped = try message(
            """
            "fallbackText":"fb",
            "cardsV2":[{"cardId":"x","card":{"header":{"title":"T","subtitle":"S"},"sections":[
              {"header":"H","widgets":[
                {"textParagraph":{"text":"para"}},
                {"decoratedText":{"topLabel":"top","text":"body","bottomLabel":"bot",
                                  "button":{"text":"Go","onClick":{"openLink":{"url":"https://example.com/go"}}}}},
                {"buttonList":{"buttons":[{"text":"One","onClick":{"openLink":{"url":"https://example.com/1"}}},
                                          {"text":"Action","onClick":{"action":{"function":"f"}}}]}},
                {"image":{"imageUrl":"https://example.com/p.png","altText":"A photo"}},
                {"divider":{}},
                {"columns":{"columnItems":[{"widgets":[{"textParagraph":{"text":"left"}}]},
                                           {"widgets":[{"textParagraph":{"text":"right"}}]}]}}
              ]}]}}]
            """)
        #expect(mapped.cardsFallbackText == "fb")
        let card = try #require(mapped.cards?.first)
        #expect(card.title == "T")
        #expect(card.subtitle == "S")
        #expect(
            card.sections == [
                CardSection(
                    header: "H",
                    widgets: [
                        .text("para"),
                        .keyValue(top: "top", content: "body", bottom: "bot"),
                        .buttons([CardButton(text: "Go", url: URL(string: "https://example.com/go"))]),
                        .buttons([
                            CardButton(text: "One", url: URL(string: "https://example.com/1")),
                            CardButton(text: "Action", url: nil),
                        ]),
                        .image(alt: "A photo"),
                        .divider,
                        .text("left"),
                        .text("right"),
                    ])
            ])
    }

    @Test func unknownWidgetsAreSkipped() throws {
        let mapped = try message(
            """
            "cardsV2":[{"card":{"sections":[{"widgets":[
              {"grid":{"title":"g"}}, {"textParagraph":{"text":"kept"}}, {"chipList":{}}
            ]}]}}]
            """)
        #expect(mapped.cards?.first?.sections == [CardSection(widgets: [.text("kept")])])
    }

    @Test func malformedWidgetsSectionsAndCardsDoNotDropTheMessage() throws {
        let mapped = try message(
            """
            "text":"hello",
            "cards":[42,{"header":"not an object","sections":[
                {"widgets":[{"textParagraph":{"text":7}},{"textParagraph":{"text":"ok"}},"junk"]},
                {"header":["bad"],"widgets":[]},
                {"widgets":[{"buttons":[{"textButton":"x"},{"textButton":{"text":"Fine"}}]}]}]}],
            "cardsV2":[{"card":"nope"},{"cardId":"only"}]
            """)
        #expect(mapped.text == "hello")
        #expect(
            mapped.cards == [
                Card(
                    sections: [
                        CardSection(widgets: [.text("ok")]),
                        CardSection(widgets: [.buttons([CardButton(text: "Fine", url: nil)])]),
                    ])
            ])
    }

    @Test func emptyCardsMapToNil() throws {
        #expect(try message(#""cards":[{"sections":[{"widgets":[{"textParagraph":{"text":"  "}}]}]}]"#).cards == nil)
        #expect(try message(#""cardsV2":[{"cardId":"x","card":{}}]"#).cards == nil)
        #expect(try message(#""text":"plain""#).cards == nil)
    }

    @Test func cardLimitsBoundWidgetsAndText() throws {
        let widgets = Array(repeating: #"{"textParagraph":{"text":"w"}}"#, count: 200).joined(separator: ",")
        let long = String(repeating: "x", count: 10_000)
        let mapped = try message(
            #""cards":[{"header":{"title":"\#(long)"},"sections":[{"widgets":[\#(widgets)]}]}]"#)
        let card = try #require(mapped.cards?.first)
        #expect(card.title?.count == CardLimits.titleLength + 1)
        #expect(card.sections.flatMap(\.widgets).count == CardLimits.widgetsPerCard)
    }

    @Test func buttonURLsMustBeHTTPS() throws {
        let mapped = try message(
            """
            "cards":[{"sections":[{"widgets":[{"buttons":[
              {"textButton":{"text":"a","onClick":{"openLink":{"url":"javascript:alert(1)"}}}},
              {"textButton":{"text":"b","onClick":{"openLink":{"url":"file:///etc/passwd"}}}},
              {"textButton":{"text":"c","onClick":{"openLink":{"url":"HTTPS://example.com/ok"}}}}]}]}]}]
            """)
        guard case .buttons(let buttons) = mapped.cards?.first?.sections.first?.widgets.first else {
            Issue.record("expected buttons")
            return
        }
        #expect(buttons.map(\.url?.host) == [nil, nil, "example.com"])
    }
}

@Suite struct CardHTMLTests {
    private func plain(_ html: String, limit: Int = 4_000) -> String { CardHTML.plain(html, limit: limit) }

    @Test func stripsInlineTagsAndKeepsLinkText() {
        #expect(
            plain(##"<b>bold</b> <i>it</i> <u>u</u> <s>s</s> <font color="#ff0000">red</font>"##) == "bold it u s red")
        #expect(plain(#"see <a href="https://example.com/x?a=1&amp;b=2">the docs</a> now"#) == "see the docs now")
    }

    @Test func lineBreaksAndBlocks() {
        #expect(plain("a<br>b<br/>c<BR />d") == "a\nb\nc\nd")
        #expect(plain("<p>one</p><p>two</p>") == "one\ntwo")
        #expect(plain("a<br><br><br><br>b") == "a\n\nb")
    }

    @Test func decodesEntities() {
        #expect(plain("Tom &amp; Jerry &lt;3 &gt; &quot;q&quot; it&#39;s&nbsp;ok") == "Tom & Jerry <3 > \"q\" it's ok")
        #expect(plain("&#65;&#x42;&#x1F600;") == "AB\u{1F600}")
        #expect(plain("&bogus; &#xZZ; &amp") == "&bogus; &#xZZ; &amp")
    }

    @Test func literalAngleBracketsSurvive() {
        #expect(plain("1 < 2 and 3 > 2") == "1 < 2 and 3 > 2")
        #expect(plain("unclosed <b tag") == "unclosed <b tag")
    }

    @Test func truncatesWithEllipsis() {
        #expect(plain(String(repeating: "a", count: 50), limit: 10) == String(repeating: "a", count: 10) + "…")
    }
}
