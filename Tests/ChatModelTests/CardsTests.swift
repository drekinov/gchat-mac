import Foundation
import Testing

@testable import ChatModel

@Suite struct CardsTests {
    private func base() -> Message {
        Message(
            name: MessageName(unchecked: "spaces/AAAA/messages/M1"),
            sender: User(name: UserName(unchecked: "users/1")), createTime: Timestamp(seconds: 1_790_000_000, nanos: 0),
            text: "hi")
    }

    private var sample: [Card] {
        [
            Card(
                title: "T", subtitle: "S",
                sections: [
                    CardSection(
                        header: "H",
                        widgets: [
                            .text("body"), .keyValue(top: "a", content: "b", bottom: nil),
                            .buttons([CardButton(text: "Go", url: URL(string: "https://example.com"))]),
                            .image(alt: nil), .divider,
                        ])
                ])
        ]
    }

    @Test func cardsRoundTrip() throws {
        var message = base()
        message.cards = sample
        let decoded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
        #expect(decoded == message)
    }

    @Test func rowsStoredBeforeCardsExistedStillDecode() throws {
        var message = base()
        message.cards = sample
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        #expect(object.removeValue(forKey: "cards") != nil)
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Message.self, from: old)
        #expect(decoded.cards == nil)
        #expect(decoded.text == "hi")
    }

    @Test func summaryPrefersTitleThenFirstText() {
        #expect(sample[0].summary == "T")
        #expect(Card(sections: [CardSection(widgets: [.divider, .text("first")])]).summary == "first")
        #expect(Card().summary == nil)
    }
}
