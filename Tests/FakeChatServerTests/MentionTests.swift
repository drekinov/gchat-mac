import ChatModel
import Foundation
import Testing

@testable import FakeChatServer

@Suite struct MentionTests {
    let h = Harness()
    var bobID: String { h.bob.user.name.id(at: 0) }
    var carolID: String { h.carol.user.name.id(at: 0) }

    private func annotations(_ call: Call) -> [[String: Any]] {
        call.json["annotations"] as? [[String: Any]] ?? []
    }

    private func slice(_ text: String, _ annotation: [String: Any]) -> String {
        let start = annotation["startIndex"] as? Int ?? 0
        let length = annotation["length"] as? Int ?? 0
        return (text as NSString).substring(with: NSRange(location: start, length: length))
    }

    @Test func aUserMentionBecomesAtNameWithAnAnnotation() async throws {
        let call = try await h.create("hi <users/\(bobID)>!")
        #expect(call.status == 200)
        #expect(call.json["text"] as? String == "hi @Bob!")
        let mention = try #require(annotations(call).first)
        #expect(annotations(call).count == 1)
        #expect(mention["type"] as? String == "USER_MENTION")
        #expect(mention["startIndex"] as? Int == 3)
        #expect(mention["length"] as? Int == 4)
        let detail = try #require(mention["userMention"] as? [String: Any])
        #expect(detail["type"] as? String == "MENTION")
        let user = try #require(detail["user"] as? [String: Any])
        #expect(user["name"] as? String == h.bob.user.name.rawValue)
        #expect(user["type"] as? String == "HUMAN")
    }

    @Test func theStoredMessageCarriesTheReplacement() async throws {
        let call = try await h.create("ping <users/\(bobID)>")
        let name = try #require(call.json["name"] as? String)
        let fetched = try await h.get(name, as: h.bob)
        #expect(fetched.json["text"] as? String == "ping @Bob")
        #expect(annotations(fetched).count == 1)
        let stored = try #require(h.server.messages(in: h.space).last)
        #expect(stored.text == "ping @Bob")
        #expect(stored.annotations == [Annotation(kind: .userMention(h.bob.user.name), startIndex: 5, length: 4)])
    }

    @Test func mentionAllUsesAtAll() async throws {
        let call = try await h.create("<users/all> standup")
        #expect(call.json["text"] as? String == "@all standup")
        let mention = try #require(annotations(call).first)
        #expect(mention["startIndex"] == nil)
        #expect(mention["length"] as? Int == 4)
        let user = try #require((mention["userMention"] as? [String: Any])?["user"] as? [String: Any])
        #expect(user["name"] as? String == "users/all")
    }

    @Test func unknownUsersStayAsLiteralText() async throws {
        for text in [
            "<users/9999999>", "x <users/nobody> y", "<users/>", "<users/12 34>", "<users/", "<users/\(bobID)",
            "<user/\(bobID)>", "users/\(bobID)", "<spaces/\(bobID)>",
        ] {
            let call = try await h.create(text)
            #expect(call.status == 200)
            #expect(call.json["text"] as? String == text)
            #expect(annotations(call).isEmpty)
        }
    }

    @Test func offsetsCountUTF16UnitsAfterEmoji() async throws {
        let call = try await h.create("😀 <users/\(bobID)>")
        #expect(call.json["text"] as? String == "😀 @Bob")
        let mention = try #require(annotations(call).first)
        #expect(mention["startIndex"] as? Int == 3)
        #expect(mention["length"] as? Int == 4)
        #expect(slice("😀 @Bob", mention) == "@Bob")
    }

    @Test func offsetsStayCorrectAcrossSeveralMentionsAndComplexEmoji() async throws {
        let text = "👨‍👩‍👧 hello <users/\(bobID)> and 🇧🇬 <users/\(carolID)>, then <users/all> é"
        let call = try await h.create(text)
        let stored = try #require(call.json["text"] as? String)
        #expect(stored == "👨‍👩‍👧 hello @Bob and 🇧🇬 @Carol, then @all é")
        let found = annotations(call)
        #expect(found.map { slice(stored, $0) } == ["@Bob", "@Carol", "@all"])
        #expect(found[0]["startIndex"] as? Int == "👨‍👩‍👧 hello ".utf16.count)
        #expect(found[1]["startIndex"] as? Int == "👨‍👩‍👧 hello @Bob and 🇧🇬 ".utf16.count)
        #expect(found[1]["length"] as? Int == 6)
    }

    @Test func displayNamesWithWideCharactersCountInUTF16() async throws {
        let wide = User(name: UserName(unchecked: "users/8001"), displayName: "Zoë 🎉")
        h.server.addMember(wide, to: h.space)
        let call = try await h.create("a 😀<users/8001>")
        let stored = try #require(call.json["text"] as? String)
        #expect(stored == "a 😀@Zoë 🎉")
        let mention = try #require(annotations(call).first)
        #expect(mention["startIndex"] as? Int == 4)
        #expect(mention["length"] as? Int == "@Zoë 🎉".utf16.count)
        #expect(slice(stored, mention) == "@Zoë 🎉")
    }

    @Test func adjacentAndRepeatedMentions() async throws {
        let call = try await h.create("<users/\(bobID)><users/\(carolID)> <users/\(bobID)>")
        let stored = try #require(call.json["text"] as? String)
        #expect(stored == "@Bob@Carol @Bob")
        let found = annotations(call)
        #expect(found.map { slice(stored, $0) } == ["@Bob", "@Carol", "@Bob"])
        #expect(found.map { $0["startIndex"] as? Int ?? 0 } == [0, 4, 11])
    }

    @Test func aKnownMentionAfterAnUnknownOneStillResolves() async throws {
        let call = try await h.create("<users/9999> <users/\(bobID)>")
        let stored = try #require(call.json["text"] as? String)
        #expect(stored == "<users/9999> @Bob")
        let mention = try #require(annotations(call).first)
        #expect(annotations(call).count == 1)
        #expect(mention["startIndex"] as? Int == 13)
        #expect(slice(stored, mention) == "@Bob")
    }

    @Test func botMentionsReportTheBotType() async throws {
        let bot = User(name: UserName(unchecked: "users/8002"), type: .bot, displayName: "Helper")
        let space = h.server.addSpace(.space, members: [h.alice], bots: [bot])
        let call = try await h.call(.post, "\(space.rawValue)/messages", body: ["text": "<users/8002> go"], as: h.alice)
        #expect(call.json["text"] as? String == "@Helper go")
        let user = try #require(
            ((annotations(call).first?["userMention"]) as? [String: Any])?["user"] as? [String: Any])
        #expect(user["type"] as? String == "BOT")
    }

    @Test func mentionsDoNotBreakRequestIdempotency() async throws {
        let first = try await h.create("hey <users/\(bobID)>", query: ["requestId": "r1"])
        let again = try await h.create("hey <users/\(bobID)>", query: ["requestId": "r1"])
        #expect(first.json["name"] as? String == again.json["name"] as? String)
        #expect(again.json["text"] as? String == "hey @Bob")
        #expect(h.server.messages(in: h.space).count == 1)
    }

    @Test func theLengthLimitAppliesToTheRawText() async throws {
        let raw = String(repeating: "<users/\(bobID)>", count: 3000)
        #expect(raw.utf8.count > 32_000)
        #expect(try await h.create(raw).status == 400)
    }

    @Test func mentionOnlyMessagesAreNotEmpty() async throws {
        let call = try await h.create("<users/\(bobID)>")
        #expect(call.status == 200)
        #expect(call.json["text"] as? String == "@Bob")
    }

    @Test func creationEventsCarryTheAnnotations() async throws {
        _ = try await h.create("yo <users/\(bobID)>")
        let events = try await h.listEvents()
        let message = try #require(
            (events.items("spaceEvents").first?["messageCreatedEventData"] as? [String: Any])?["message"]
                as? [String: Any])
        #expect(message["text"] as? String == "yo @Bob")
        #expect((message["annotations"] as? [[String: Any]])?.count == 1)
    }
}
