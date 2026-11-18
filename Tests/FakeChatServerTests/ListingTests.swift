import ChatModel
import Foundation
import Testing

@testable import FakeChatServer

struct PaginationTests {
    let h = Harness()

    @Test func pagesCoverEveryMessageOnceAndTheLastPageHasNoToken() async throws {
        let messages = h.seed(5)
        var seen: [String] = []
        var pages = 0
        var token: String?
        repeat {
            var query = ["pageSize": "2"]
            query["pageToken"] = token
            let page = try await h.listMessages(query)
            #expect(page.status == 200)
            seen += page.names("messages")
            token = page.nextPageToken
            pages += 1
        } while token != nil
        #expect(pages == 3)
        #expect(seen == messages.map(\.name.rawValue))
    }

    @Test func exactMultipleOfPageSizeEndsWithoutAnEmptyPage() async throws {
        h.seed(4)
        let first = try await h.listMessages(["pageSize": "2"])
        let second = try await h.listMessages(["pageSize": "2", "pageToken": try #require(first.nextPageToken)])
        #expect(second.items("messages").count == 2)
        #expect(second.nextPageToken == nil)
    }

    @Test func tokenReusedWithDifferentParametersIs400() async throws {
        h.seed(5)
        let token = try #require(try await h.listMessages(["pageSize": "2"]).nextPageToken)
        let differentSize = try await h.listMessages(["pageSize": "3", "pageToken": token])
        let differentOrder = try await h.listMessages([
            "pageSize": "2", "orderBy": "createTime DESC", "pageToken": token,
        ])
        let differentFilter = try await h.listMessages(
            ["pageSize": "2", "filter": "createTime > \"2026-01-01T00:00:00Z\"", "pageToken": token])
        let otherAccount = try await h.listMessages(["pageSize": "2", "pageToken": token], as: h.bob)
        for call in [differentSize, differentOrder, differentFilter, otherAccount] {
            #expect(call.status == 400)
            #expect(call.errorStatus == "INVALID_ARGUMENT")
        }
        #expect(try await h.listMessages(["pageSize": "2", "pageToken": token]).status == 200)
    }

    @Test func garbageTokenIs400() async throws {
        #expect(try await h.listMessages(["pageToken": "garbage"]).status == 400)
    }

    @Test func pageSizeIsClamped() async throws {
        h.seed(3)
        #expect(try await h.listMessages(["pageSize": "0"]).items("messages").count == 1)
        #expect(try await h.listMessages(["pageSize": "-5"]).items("messages").count == 1)
        #expect(try await h.listMessages(["pageSize": "5000"]).items("messages").count == 3)
        #expect(try await h.listMessages(["pageSize": "abc"]).status == 400)
    }

    @Test func spacesMembersAndEmojisPaginate() async throws {
        for index in 1...3 { h.server.addSpace(.space, displayName: "S\(index)", members: [h.alice]) }
        for index in 1...3 { h.server.addCustomEmoji(shortcode: "e\(index)") }
        let spaces = try await h.get("spaces", ["pageSize": "3"], as: h.alice)
        #expect(spaces.items("spaces").count == 3)
        #expect(spaces.nextPageToken != nil)

        let members = try await h.get("\(h.space.rawValue)/members", ["pageSize": "1"], as: h.alice)
        #expect(members.items("memberships").count == 1)
        #expect(members.nextPageToken != nil)

        let emojis = try await h.get("customEmojis", ["pageSize": "2"], as: h.alice)
        #expect(emojis.items("customEmojis").count == 2)
        let rest = try await h.get(
            "customEmojis", ["pageSize": "2", "pageToken": try #require(emojis.nextPageToken)], as: h.alice)
        #expect(rest.items("customEmojis").count == 1)
        #expect(rest.nextPageToken == nil)
    }
}

struct MessageListingTests {
    let h = Harness()

    @Test func filterByCreateTimeBounds() async throws {
        let messages = h.seed(5)
        let after = "createTime > \"\(messages[1].createTime.rfc3339)\""
        #expect(try await h.listMessages(["filter": after]).names("messages") == messages[2...].map(\.name.rawValue))

        let before = "createTime < \"\(messages[3].createTime.rfc3339)\""
        #expect(try await h.listMessages(["filter": before]).names("messages") == messages[..<3].map(\.name.rawValue))

        let both = "\(after) AND \(before)"
        #expect(
            try await h.listMessages(["filter": both]).names("messages") == [messages[2].name.rawValue])
    }

    @Test func filterByThread() async throws {
        let root = h.server.post("root", in: h.space, from: .account(h.alice))
        let reply = h.server.post("reply", in: h.space, from: .account(h.alice), thread: root.thread)
        h.server.post("elsewhere", in: h.space, from: .account(h.alice))
        let thread = try #require(root.thread)
        let call = try await h.listMessages(["filter": "thread.name = \(thread.rawValue)"])
        #expect(call.names("messages") == [root.name.rawValue, reply.name.rawValue])
    }

    @Test func filterCombinedWithThread() async throws {
        let root = h.server.post("root", in: h.space, from: .account(h.alice))
        let reply = h.server.post("reply", in: h.space, from: .account(h.alice), thread: root.thread)
        let thread = try #require(root.thread)
        let filter = "createTime > \"\(root.createTime.rfc3339)\" AND thread.name = \(thread.rawValue)"
        #expect(try await h.listMessages(["filter": filter]).names("messages") == [reply.name.rawValue])
    }

    @Test func orderByDescendingAndDefaultAscending() async throws {
        let messages = h.seed(3).map(\.name.rawValue)
        #expect(try await h.listMessages().names("messages") == messages)
        #expect(try await h.listMessages(["orderBy": "createTime ASC"]).names("messages") == messages)
        #expect(try await h.listMessages(["orderBy": "createTime DESC"]).names("messages") == messages.reversed())
    }

    @Test func descendingOrderPaginates() async throws {
        let messages = h.seed(3).map(\.name.rawValue)
        let first = try await h.listMessages(["orderBy": "createTime DESC", "pageSize": "2"])
        let second = try await h.listMessages(
            ["orderBy": "createTime DESC", "pageSize": "2", "pageToken": try #require(first.nextPageToken)])
        #expect(first.names("messages") + second.names("messages") == messages.reversed())
    }

    @Test func tombstonesAreHiddenUnlessShowDeleted() async throws {
        let messages = h.seed(3)
        h.server.delete(messages[1].name)
        #expect(try await h.listMessages().names("messages") == [messages[0], messages[2]].map(\.name.rawValue))

        let shown = try await h.listMessages(["showDeleted": "true"])
        #expect(shown.names("messages") == messages.map(\.name.rawValue))
        let tombstone = shown.items("messages")[1]
        #expect(tombstone["deleteTime"] as? String != nil)
        #expect((tombstone["deletionMetadata"] as? [String: Any])?["deletionType"] as? String == "CREATOR")
        #expect(tombstone["text"] == nil)
        #expect(tombstone["createTime"] as? String == messages[1].createTime.rfc3339)
    }

    @Test(arguments: [
        "createTime >= \"2026-01-01T00:00:00Z\"", "createTime > 2026-01-01", "text = \"hello\"", "garbage",
        "createTime > \"2026-01-01T00:00:00Z\" OR thread.name = spaces/A/threads/B", "thread.name = nonsense",
    ])
    func unparseableFilterIs400(filter: String) async throws {
        let call = try await h.listMessages(["filter": filter])
        #expect(call.status == 400)
        #expect(call.errorStatus == "INVALID_ARGUMENT")
    }

    @Test func badOrderByIs400() async throws {
        #expect(try await h.listMessages(["orderBy": "text DESC"]).status == 400)
        #expect(try await h.listMessages(["orderBy": "createTime SIDEWAYS"]).status == 400)
    }

    @Test func messageWireShape() async throws {
        let root = h.server.post(
            "hello @Bob", in: h.space, from: .account(h.alice),
            annotations: [
                Annotation(kind: .userMention(h.bob.user.name), startIndex: 6, length: 4),
                Annotation(kind: .richLink(URL(string: "https://example.com/doc")!), startIndex: 0, length: 5),
            ],
            attachments: [
                Attachment(
                    contentName: "a.png", contentType: "image/png", source: .uploaded(MediaResourceName("media/abc")!)),
                Attachment(contentName: "d.pdf", contentType: "application/pdf", source: .drive(fileID: "F1")),
            ], gifURLs: [URL(string: "https://gifs.example/1.gif")!], cardsFallbackText: "card text")
        h.server.react(root.name, emoji: .unicode("👍"), by: .account(h.bob))
        h.server.react(root.name, emoji: .unicode("👍"), by: .account(h.alice))
        let reply = h.server.post(
            "re", in: h.space, from: .bot(User(name: UserName("users/77")!, type: .bot)), thread: root.thread)

        let wire = try await h.get(root.name.rawValue, as: h.bob).json
        #expect(wire["text"] as? String == "hello @Bob")
        #expect((wire["sender"] as? [String: Any])?["displayName"] as? String == "Alice")
        #expect(wire["threadReply"] == nil)
        #expect((wire["thread"] as? [String: Any])?["name"] as? String == root.thread?.rawValue)
        #expect(wire["fallbackText"] as? String == "card text")
        #expect(wire["cardsV2"] != nil)
        #expect((wire["attachedGifs"] as? [[String: Any]])?.first?["uri"] as? String == "https://gifs.example/1.gif")

        let annotations = try #require(wire["annotations"] as? [[String: Any]])
        #expect(annotations[0]["type"] as? String == "USER_MENTION")
        #expect(annotations[0]["startIndex"] as? Int == 6)
        #expect(
            ((annotations[0]["userMention"] as? [String: Any])?["user"] as? [String: Any])?["name"] as? String
                == h.bob.user.name.rawValue)
        #expect(annotations[1]["startIndex"] == nil)
        #expect((annotations[1]["richLinkMetadata"] as? [String: Any])?["uri"] as? String == "https://example.com/doc")

        let attachments = try #require(wire["attachment"] as? [[String: Any]])
        #expect(attachments[0]["source"] as? String == "UPLOADED_CONTENT")
        #expect((attachments[0]["attachmentDataRef"] as? [String: Any])?["resourceName"] as? String == "media/abc")
        #expect(attachments[1]["source"] as? String == "DRIVE_FILE")
        #expect((attachments[1]["driveDataRef"] as? [String: Any])?["driveFileId"] as? String == "F1")

        let summaries = try #require(wire["emojiReactionSummaries"] as? [[String: Any]])
        #expect(summaries.count == 1)
        #expect(summaries[0]["reactionCount"] as? Int == 2)
        #expect((summaries[0]["emoji"] as? [String: Any])?["unicode"] as? String == "👍")

        let replyWire = try await h.get(reply.name.rawValue, as: h.bob).json
        #expect(replyWire["threadReply"] as? Bool == true)
        #expect((replyWire["sender"] as? [String: Any])?["type"] as? String == "BOT")
    }

    @Test func idsLookLikeGoogleOnes() {
        let messages = h.seed(3)
        for message in messages {
            let id = message.name.id(at: 1)
            #expect(id.contains("."))
            let thread = message.thread!.id(at: 1)
            #expect(thread.allSatisfy { $0.isLetter || $0.isNumber })
        }
        #expect(Set(messages.map(\.name)).count == 3)
    }

    @Test func clockStampsAndAdvances() {
        let start = h.server.now
        let first = h.server.post("a", in: h.space, from: .account(h.alice))
        let second = h.server.post("b", in: h.space, from: .account(h.alice))
        #expect(second.createTime == first.createTime.adding(.milliseconds(1)))
        #expect(h.server.now == second.createTime.adding(.milliseconds(1)))
        #expect(first.createTime == start)

        let explicit = ts("2030-01-01T00:00:00Z")
        let pinned = h.server.post("c", in: h.space, from: .account(h.alice), at: explicit)
        #expect(pinned.createTime == explicit)
        #expect(h.server.now == second.createTime.adding(.milliseconds(1)))
        h.server.advance(.seconds(10))
        #expect(h.server.now == second.createTime.adding(.milliseconds(10_001)))
    }

    @Test func lastActiveTimeBumpsOnPostAndOnlyOnEditWhenAsked() async throws {
        func lastActive() async throws -> String? {
            try await h.get(h.space.rawValue, as: h.alice).json["lastActiveTime"] as? String
        }
        let message = h.server.post("a", in: h.space, from: .account(h.alice))
        #expect(try await lastActive() == message.createTime.rfc3339)

        h.server.edit(message.name, text: "b")
        h.server.react(message.name, emoji: .unicode("🎉"), by: .account(h.bob))
        #expect(try await lastActive() == message.createTime.rfc3339)

        h.server.editsBumpLastActiveTime = true
        let edited = h.server.edit(message.name, text: "c")
        #expect(try await lastActive() == edited.lastUpdateTime?.rfc3339)
    }
}
