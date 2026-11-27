import ChatModel
import Foundation
import Testing

@testable import FakeChatServer

@Suite struct MarkupTests {
    let h = Harness()
    var bob: String { h.bob.user.name.rawValue }

    private func create(_ text: String, syntax: String? = FakeMarkup.chatSyntax) async throws -> Call {
        var body: [String: Any] = ["text": text]
        if let syntax { body["markupSyntax"] = syntax }
        return try await h.call(.post, "\(h.space.rawValue)/messages", body: body, as: h.alice)
    }

    private func mentionRanges(_ call: Call) -> [[Int]] {
        (call.json["annotations"] as? [[String: Any]] ?? []).map {
            [$0["startIndex"] as? Int ?? 0, $0["length"] as? Int ?? 0]
        }
    }

    @Test(arguments: [
        ("*bold* and _it_ ~gone~", "bold and it gone"),
        ("keep `*code*` and <https://example.com/a|the doc>", "keep `*code*` and the doc"),
        ("* one\n    - two\n> said", "one\ntwo\nsaid"),
        ("```\n*raw*\n```\nafter *b*", "```\n*raw*\n```\nafter b"),
        ("snake_case 2*3*4 <https://example.com>", "snake_case 2*3*4 https://example.com"),
    ])
    func createStoresMarkupAndDerivesPlainText(_ pair: (String, String)) async throws {
        let call = try await create(pair.0)
        #expect(call.status == 200)
        #expect(call.json["formattedText"] as? String == pair.0)
        #expect(call.json["text"] as? String == pair.1)
    }

    @Test func mentionOffsetsAreCountedOnThePlainText() async throws {
        let call = try await create("*Hey* <\(bob)>, see <https://example.com|this> <\(bob)>")
        #expect(call.json["text"] as? String == "Hey @Bob, see this @Bob")
        #expect(mentionRanges(call) == [[4, 4], [19, 4]])
        #expect(call.json["formattedText"] as? String == "*Hey* <\(bob)>, see <https://example.com|this> <\(bob)>")
    }

    @Test func withoutMarkupSyntaxTheTextIsKeptAsSent() async throws {
        let call = try await create("*as is*", syntax: nil)
        #expect(call.json["text"] as? String == "*as is*")
        #expect(call.json["formattedText"] == nil)
        #expect(try await create("x", syntax: "MARKUP_SYNTAX_BOGUS").status == 400)
    }

    @Test func getListAndEventsCarryTheMarkup() async throws {
        let created = try await create("_hi_ <\(bob)>")
        let name = try #require(created.json["name"] as? String)
        let fetched = try await h.get(name, as: h.bob)
        #expect(fetched.json["formattedText"] as? String == "_hi_ <\(bob)>")
        #expect(fetched.json["text"] as? String == "hi @Bob")
        let listed = try #require(try await h.listMessages().items("messages").last)
        #expect(listed["formattedText"] as? String == "_hi_ <\(bob)>")
        let event = try #require(try await h.listEvents().items("spaceEvents").last)
        let message = (event["messageCreatedEventData"] as? [String: Any])?["message"] as? [String: Any]
        #expect(message?["formattedText"] as? String == "_hi_ <\(bob)>")
    }

    @Test func patchReplacesOrClearsTheMarkup() async throws {
        let created = try await create("*v1*")
        let name = try #require(created.json["name"] as? String)
        let patched = try await h.call(
            .patch, name, query: ["updateMask": "text"],
            body: ["text": "~v2~ <\(bob)>", "markupSyntax": FakeMarkup.chatSyntax], as: h.alice)
        #expect(patched.json["text"] as? String == "v2 @Bob")
        #expect(patched.json["formattedText"] as? String == "~v2~ <\(bob)>")
        #expect(mentionRanges(patched) == [[3, 4]])
        let plain = try await h.call(.patch, name, query: ["updateMask": "text"], body: ["text": "v3"], as: h.alice)
        #expect(plain.json["formattedText"] == nil)
    }

    @Test func deletingDropsTheMarkup() async throws {
        let created = try await create("*gone*")
        let name = try #require(created.json["name"] as? String)
        #expect(try await h.call(.delete, name, as: h.alice).status == 200)
        let stored = try #require(h.server.messages(in: h.space).last)
        #expect(stored.isDeleted)
        #expect(stored.formattedText == nil)
    }

    @Test func seedingMarkupMatchesTheAPI() {
        let message = h.server.post(markup: "*Hi* <\(bob)>", in: h.space, from: .account(h.alice))
        #expect(message.text == "Hi @Bob")
        #expect(message.formattedText == "*Hi* <\(bob)>")
        #expect(message.annotations == [Annotation(kind: .userMention(h.bob.user.name), startIndex: 3, length: 4)])
    }
}
