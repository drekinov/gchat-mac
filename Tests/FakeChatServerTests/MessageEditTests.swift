import ChatModel
import ChatNet
import Foundation
import Testing

@testable import FakeChatServer

struct MessageEditTests {
    let h = Harness()

    func post(_ text: String, from account: FakeAccount, thread: ThreadName? = nil) -> Message {
        let message = h.server.post(text, in: h.space, from: .account(account), thread: thread)
        h.server.advance(.seconds(1))
        return message
    }

    func patch(_ message: Message, _ text: String, as account: FakeAccount) async throws -> Call {
        try await h.call(
            .patch, message.name.rawValue, query: ["updateMask": "text"], body: ["text": text], as: account)
    }

    func delete(_ message: Message, force: Bool = false, as account: FakeAccount) async throws -> Call {
        try await h.call(.delete, message.name.rawValue, query: force ? ["force": "true"] : [:], as: account)
    }

    @Test func onlyTheSenderEditsAndMentionsAreParsed() async throws {
        let mine = post("helo", from: h.alice)
        #expect(try await patch(mine, "nope", as: h.bob).status == 403)

        let call = try await patch(mine, "hello <\(h.bob.user.name.rawValue)>", as: h.alice)
        #expect(call.status == 200)
        #expect(call.json["text"] as? String == "hello @Bob")
        #expect((call.json["annotations"] as? [[String: Any]])?.count == 1)
        #expect(call.json["lastUpdateTime"] != nil)
        let events = try await h.listEvents(h.eventsFilter(types: [updated])).items("spaceEvents")
        #expect(events.count == 1)
    }

    @Test func aDeletedMessageCanBeNeitherEditedNorDeletedAgain() async throws {
        let mine = post("x", from: h.alice)
        #expect(try await delete(mine, as: h.alice).status == 200)
        #expect(try await patch(mine, "y", as: h.alice).status == 404)
        #expect(try await delete(mine, as: h.alice).status == 404)
    }

    @Test func membersDeleteOnlyTheirOwnAndManagersDeleteAny() async throws {
        let theirs = post("bob's", from: h.bob)
        #expect(try await delete(theirs, as: h.alice).status == 403)
        h.server.setRole(.manager, of: h.alice, in: h.space)
        #expect(try await delete(theirs, as: h.alice).status == 200)
    }

    @Test func aThreadStarterWithRepliesNeedsForce() async throws {
        let root = post("root", from: h.alice)
        let reply = post("reply", from: h.bob, thread: root.thread)
        let refused = try await delete(root, as: h.alice)
        #expect(refused.status == 400)
        #expect((refused.json["error"] as? [String: Any])?["status"] as? String == "FAILED_PRECONDITION")
        #expect(try await delete(root, force: true, as: h.alice).status == 200)
        #expect(try await h.get(reply.name.rawValue, as: h.alice).json["deleteTime"] != nil)
    }

    @Test func deletionEventsCarryOnlyWhatGoogleSends() async throws {
        let mine = post("x", from: h.alice)
        _ = try await delete(mine, as: h.alice)
        let event = try #require(try await h.listEvents(h.eventsFilter(types: [deleted])).items("spaceEvents").first)
        let message = try #require((event["messageDeletedEventData"] as? [String: Any])?["message"] as? [String: Any])
        #expect(Set(message.keys) == ["name", "createTime", "deleteTime", "deletionMetadata"])
    }
}
