import ChatModel
import ChatNet
import Foundation
import Testing

@testable import FakeChatServer

struct CreateMessageTests {
    let h = Harness()

    @Test func createsAMessageFromTheCaller() async throws {
        let call = try await h.create("hello")
        #expect(call.status == 200)
        let wire = call.json
        #expect(wire["text"] as? String == "hello")
        #expect((wire["sender"] as? [String: Any])?["name"] as? String == h.alice.user.name.rawValue)
        #expect(wire["threadReply"] == nil)
        #expect(h.server.messages(in: h.space).map(\.text) == ["hello"])
        #expect(try await h.get(try #require(wire["name"] as? String), as: h.bob).status == 200)
    }

    @Test func requestIdIsIdempotentPerAccountAndSpace() async throws {
        let first = try await h.create("hello", query: ["requestId": "r1"])
        let repeated = try await h.create("hello", query: ["requestId": "r1"])
        #expect(repeated.status == 200)
        #expect(repeated.json["name"] as? String == first.json["name"] as? String)
        #expect(h.server.messages(in: h.space).count == 1)

        let otherAccount = try await h.create("hello", query: ["requestId": "r1"], as: h.bob)
        #expect(otherAccount.json["name"] as? String != first.json["name"] as? String)
        let otherSpace = h.server.addSpace(.space, members: [h.alice])
        let elsewhere = try await h.call(
            .post, "\(otherSpace.rawValue)/messages", query: ["requestId": "r1"], body: ["text": "hello"],
            as: h.alice)
        #expect(elsewhere.json["name"] as? String != first.json["name"] as? String)
        let different = try await h.create("hello", query: ["requestId": "r2"])
        #expect(different.json["name"] as? String != first.json["name"] as? String)
        #expect(h.server.messages(in: h.space).count == 3)
    }

    @Test func repeatedRequestIdReturnsTheCurrentMessage() async throws {
        let first = try await h.create("hello", query: ["requestId": "r1"])
        let rawName = try #require(first.json["name"] as? String)
        let name = try #require(MessageName(rawName))
        h.server.edit(name, text: "edited")
        let repeated = try await h.create("hello", query: ["requestId": "r1"])
        #expect(repeated.json["text"] as? String == "edited")
    }

    @Test func textLimitIs32000Bytes() async throws {
        #expect(try await h.create(String(repeating: "a", count: 32_000)).status == 200)
        let tooLong = try await h.create(String(repeating: "a", count: 32_001))
        #expect(tooLong.status == 400)
        #expect(tooLong.errorStatus == "INVALID_ARGUMENT")
        #expect(try await h.create(String(repeating: "é", count: 16_001)).status == 400)
    }

    @Test func emptyMessageAndBadBodyAre400() async throws {
        #expect(try await h.create("").status == 400)
        let raw = try await h.transport.send(
            HTTPRequest(
                method: .post, url: URL(string: "https://chat.googleapis.com/v1/\(h.space.rawValue)/messages")!,
                headers: ["Authorization": "Bearer \(h.alice.token)"], body: Data("not json".utf8)))
        #expect(raw.status == 400)
    }

    @Test func replyToExistingThreadIsAThreadReply() async throws {
        let root = h.server.post("root", in: h.space, from: .account(h.bob))
        let call = try await h.create(
            "reply", query: ["messageReplyOption": "REPLY_MESSAGE_OR_FAIL"], thread: root.thread)
        #expect(call.status == 200)
        #expect(call.json["threadReply"] as? Bool == true)
        #expect((call.json["thread"] as? [String: Any])?["name"] as? String == root.thread?.rawValue)
    }

    @Test func replyOrFailOnMissingThreadIs404AndCommitsNothing() async throws {
        let missing = ThreadName("\(h.space.rawValue)/threads/Missing")!
        let call = try await h.create("reply", query: ["messageReplyOption": "REPLY_MESSAGE_OR_FAIL"], thread: missing)
        #expect(call.status == 404)
        #expect(call.errorStatus == "NOT_FOUND")
        #expect(h.server.messages(in: h.space).isEmpty)
    }

    @Test func missingThreadWithoutTheOptionStartsANewThread() async throws {
        let missing = ThreadName("\(h.space.rawValue)/threads/Missing")!
        let call = try await h.create("hello", thread: missing)
        #expect(call.status == 200)
        #expect(call.json["threadReply"] == nil)
        let thread = (call.json["thread"] as? [String: Any])?["name"] as? String
        #expect(thread != nil && thread != missing.rawValue)
    }

    @Test func threadFromAnotherSpaceIs400() async throws {
        let other = h.server.addSpace(.space, members: [h.alice])
        let foreign = h.server.post("x", in: other, from: .account(h.alice))
        let call = try await h.create("hi", thread: foreign.thread)
        #expect(call.status == 400)
    }

    @Test func attachmentTokensBecomeUploadedAttachments() async throws {
        let uploaded = try await h.uploaded(Data("png-bytes".utf8))
        let call = try await h.createWithAttachment(uploaded.token)
        #expect(call.status == 200)
        let attachment = try #require(call.items("attachment").first)
        #expect(attachment["source"] as? String == "UPLOADED_CONTENT")
        #expect((attachment["attachmentDataRef"] as? [String: Any])?["resourceName"] is String)
    }

    @Test func createdMessageIsRecordedAsAnEvent() async throws {
        let call = try await h.create("hello")
        let events = try await h.listEvents()
        let message = events.items("spaceEvents").first?["messageCreatedEventData"] as? [String: Any]
        #expect((message?["message"] as? [String: Any])?["name"] as? String == call.json["name"] as? String)
    }
}
