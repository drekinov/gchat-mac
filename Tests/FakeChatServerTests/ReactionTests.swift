import ChatModel
import ChatNet
import Foundation
import Testing

@testable import FakeChatServer

struct ReactionTests {
    let h: Harness
    let message: Message

    init() {
        let harness = Harness()
        h = harness
        message = harness.server.post("hello", in: harness.space, from: .account(harness.alice))
    }

    var collection: String { "\(message.name.rawValue)/reactions" }

    func react(_ emoji: [String: Any], as account: FakeAccount) async throws -> Call {
        try await h.call(.post, collection, body: ["emoji": emoji], as: account)
    }

    func react(_ unicode: String = "🙂", as account: FakeAccount) async throws -> Call {
        try await react(["unicode": unicode], as: account)
    }

    func summaries() async throws -> [[String: Any]] {
        try await h.get(message.name.rawValue, as: h.alice).items("emojiReactionSummaries")
    }

    func reactionEvents(_ types: [String] = [reactionCreated, reactionDeleted]) async throws -> [[String: Any]] {
        try await h.listEvents(h.eventsFilter(types: types)).items("spaceEvents")
    }

    func reactionName(_ call: Call) throws -> String {
        try #require(call.json["name"] as? String)
    }

    // MARK: Create

    @Test func createReturnsTheReactionAndUpdatesTheSummary() async throws {
        let call = try await react(as: h.bob)
        #expect(call.status == 200)
        let name = try reactionName(call)
        #expect(name.hasPrefix(collection + "/"))
        #expect(ReactionName(name) != nil)
        let user = call.json["user"] as? [String: Any]
        #expect(user?["name"] as? String == h.bob.user.name.rawValue)
        #expect(user?["type"] as? String == "HUMAN")
        #expect((call.json["emoji"] as? [String: Any])?["unicode"] as? String == "🙂")

        _ = try await react(as: h.alice)
        let summary = try #require(try await summaries().first)
        #expect(summary["reactionCount"] as? Int == 2)
        #expect((summary["emoji"] as? [String: Any])?["unicode"] as? String == "🙂")
    }

    @Test func differentEmojiGetTheirOwnSummary() async throws {
        _ = try await react("🙂", as: h.bob)
        _ = try await react("👍", as: h.bob)
        let found = try await summaries().compactMap { ($0["emoji"] as? [String: Any])?["unicode"] as? String }
        #expect(found == ["🙂", "👍"])
    }

    @Test func theSameUserAndEmojiAgainIs409() async throws {
        _ = try await react(as: h.bob)
        let duplicate = try await react(as: h.bob)
        #expect(duplicate.status == 409)
        #expect(duplicate.errorStatus == "ALREADY_EXISTS")
        #expect(try await summaries().first?["reactionCount"] as? Int == 1)
        #expect(try await reactionEvents().count == 1)
        #expect(try await react(as: h.alice).status == 200)
    }

    @Test func seededDuplicateIsIgnored() async throws {
        let first = h.server.react(message.name, emoji: .unicode("🙂"), by: .account(h.bob))
        let second = h.server.react(message.name, emoji: .unicode("🙂"), by: .account(h.bob))
        #expect(first == second)
        #expect(try await summaries().first?["reactionCount"] as? Int == 1)
    }

    @Test func customEmojiReactionsCarryNameUidAndEmojiName() async throws {
        let name = h.server.addCustomEmoji(shortcode: "party")
        let call = try await react(["customEmoji": ["name": name.rawValue]], as: h.bob)
        #expect(call.status == 200)
        let custom = (call.json["emoji"] as? [String: Any])?["customEmoji"] as? [String: Any]
        #expect(custom?["name"] as? String == name.rawValue)
        #expect(custom?["emojiName"] as? String == ":party:")
        let uid = try #require(custom?["uid"] as? String)

        #expect(try await react(["customEmoji": ["name": name.rawValue]], as: h.bob).status == 409)
        let summary = (try await summaries().first?["emoji"] as? [String: Any])?["customEmoji"] as? [String: Any]
        #expect(summary?["name"] as? String == name.rawValue)

        let filtered = try await h.get(
            collection, ["filter": "emoji.custom_emoji.uid = \"\(uid)\""], as: h.alice)
        #expect(filtered.items("reactions").count == 1)
        let other = try await h.get(collection, ["filter": "emoji.custom_emoji.uid = \"nope\""], as: h.alice)
        #expect(other.items("reactions").isEmpty)
    }

    @Test func unknownOrMalformedEmojiIs400() async throws {
        let unknown = try await react(["customEmoji": ["name": "customEmojis/Nope"]], as: h.bob)
        #expect(unknown.status == 400)
        #expect(unknown.errorStatus == "INVALID_ARGUMENT")
        let bodies: [[String: Any]] = [
            ["customEmoji": ["name": "garbage"]], ["customEmoji": [:]], ["unicode": ""], [:],
            ["unicode": "🙂", "customEmoji": ["name": "customEmojis/Nope"]],
        ]
        for emoji in bodies {
            #expect(try await react(emoji, as: h.bob).status == 400, "\(emoji)")
        }
        let noBody = try await h.call(.post, collection, as: h.bob)
        #expect(noBody.status == 400)
        #expect(try await summaries().isEmpty)
    }

    @Test func nonMembersAndMissingMessagesAreRejected() async throws {
        let denied = try await react(as: h.carol)
        #expect(denied.status == 403)
        #expect(denied.errorStatus == "PERMISSION_DENIED")

        let missing = try await h.call(
            .post, "\(h.space.rawValue)/messages/Nope.Nope/reactions", body: ["emoji": ["unicode": "🙂"]],
            as: h.bob)
        #expect(missing.status == 404)
        let noSpace = try await h.call(
            .post, "spaces/Missing/messages/Nope.Nope/reactions", body: ["emoji": ["unicode": "🙂"]], as: h.bob)
        #expect(noSpace.status == 404)

        h.server.delete(message.name)
        #expect(try await react(as: h.bob).status == 404)
    }

    @Test func reactingBumpsLastActiveTimeOnlyWhenAsked() async throws {
        func lastActive() async throws -> String? {
            try await h.get(h.space.rawValue, as: h.alice).json["lastActiveTime"] as? String
        }
        let before = try await lastActive()
        _ = try await react("🙂", as: h.bob)
        #expect(try await lastActive() == before)

        h.server.editsBumpLastActiveTime = true
        _ = try await react("👍", as: h.bob)
        #expect(try await lastActive() != before)
    }

    // MARK: Delete

    @Test func deletingOwnReactionReturnsAnEmptyObjectAndShrinksTheSummary() async throws {
        let mine = try reactionName(try await react(as: h.bob))
        _ = try await react(as: h.alice)

        let call = try await h.call(.delete, mine, as: h.bob)
        #expect(call.status == 200)
        #expect(call.json.isEmpty)
        #expect(try await summaries().first?["reactionCount"] as? Int == 1)

        let again = try await h.call(.delete, mine, as: h.bob)
        #expect(again.status == 403)
        #expect(again.errorStatus == "PERMISSION_DENIED")
    }

    @Test func summaryDisappearsAtZero() async throws {
        let mine = try reactionName(try await react(as: h.bob))
        try await h.call(.delete, mine, as: h.bob)
        #expect(try await summaries().isEmpty)
        #expect(try await react(as: h.bob).status == 200)
    }

    @Test func anotherUsersReactionCannotBeDeleted() async throws {
        let theirs = try reactionName(try await react(as: h.bob))
        let call = try await h.call(.delete, theirs, as: h.alice)
        #expect(call.status == 403)
        #expect(call.errorStatus == "PERMISSION_DENIED")
        #expect(try await summaries().first?["reactionCount"] as? Int == 1)
        #expect(try await h.call(.delete, theirs, as: h.carol).status == 403)
    }

    @Test func seededReactionsAreListedAndDeletableByTheirAuthor() async throws {
        let seeded = h.server.react(message.name, emoji: .unicode("🎉"), by: .account(h.bob))
        let listed = try await h.get(collection, as: h.alice).names("reactions")
        #expect(listed == [seeded.rawValue])
        #expect(try await h.call(.delete, seeded.rawValue, as: h.alice).status == 403)
        #expect(try await h.call(.delete, seeded.rawValue, as: h.bob).status == 200)
        #expect(try await summaries().isEmpty)
    }

    @Test func seededRemovalUpdatesTheSummaryAndRecordsAnEvent() async throws {
        let seeded = h.server.react(message.name, emoji: .unicode("🎉"), by: .account(h.bob))
        h.server.removeReaction(seeded)
        #expect(try await summaries().isEmpty)
        #expect(try await reactionEvents([reactionDeleted]).count == 1)
    }

    @Test func deleteChecksMembershipAndMessage() async throws {
        let mine = try reactionName(try await react(as: h.bob))
        #expect(try await h.call(.delete, mine, as: h.carol).status == 403)
        #expect(try await h.call(.delete, "\(message.name.rawValue)/reactions/Nope", as: h.bob).status == 403)
        #expect(
            try await h.call(.delete, "\(h.space.rawValue)/messages/Nope.Nope/reactions/x", as: h.bob).status == 404)
    }

    @Test func deletingTheMessageDropsItsReactions() async throws {
        let mine = try reactionName(try await react(as: h.bob))
        h.server.delete(message.name)
        #expect(try await h.call(.delete, mine, as: h.bob).status == 404)
        #expect(try await h.get(collection, as: h.alice).status == 404)
    }

    // MARK: Events

    @Test func createAndDeleteRecordEventsWithTheReaction() async throws {
        let name = try reactionName(try await react(as: h.bob))
        try await h.call(.delete, name, as: h.bob)

        let events = try await reactionEvents()
        #expect(events.compactMap { $0["eventType"] as? String } == [reactionCreated, reactionDeleted])
        let created = (events[0]["reactionCreatedEventData"] as? [String: Any])?["reaction"] as? [String: Any]
        let deleted = (events[1]["reactionDeletedEventData"] as? [String: Any])?["reaction"] as? [String: Any]
        for reaction in [created, deleted] {
            #expect(reaction?["name"] as? String == name)
            #expect((reaction?["user"] as? [String: Any])?["name"] as? String == h.bob.user.name.rawValue)
            #expect((reaction?["emoji"] as? [String: Any])?["unicode"] as? String == "🙂")
        }
    }

    @Test func sameInstantDeletionsBatchAsReactionBatchDeleted() async throws {
        let at = ts("2026-03-01T00:00:00Z")
        let first = h.server.react(message.name, emoji: .unicode("🙂"), by: .account(h.bob))
        let second = h.server.react(message.name, emoji: .unicode("👍"), by: .account(h.bob))
        h.server.removeReaction(first, at: at)
        h.server.removeReaction(second, at: at)
        let events = try await reactionEvents([reactionDeleted])
        #expect(events.count == 1)
        #expect(events[0]["eventType"] as? String == "google.workspace.chat.reaction.v1.batchDeleted")
        let batch = (events[0]["reactionBatchDeletedEventData"] as? [String: Any])?["reactions"] as? [[String: Any]]
        #expect(batch?.count == 2)
    }

    // MARK: List

    @Test func listDefaultsTo25AndPaginates() async throws {
        for index in 0..<30 {
            let user = User(name: UserName("users/\(5000 + index)")!, displayName: "U\(index)")
            h.server.react(message.name, emoji: .unicode("🙂"), by: .user(user))
        }
        let first = try await h.get(collection, as: h.alice)
        #expect(first.items("reactions").count == 25)
        let token = try #require(first.nextPageToken)
        let second = try await h.get(collection, ["pageToken": token], as: h.alice)
        #expect(second.items("reactions").count == 5)
        #expect(second.nextPageToken == nil)
        #expect(Set(first.names("reactions") + second.names("reactions")).count == 30)
    }

    @Test func listPageSizeIsCappedAt200() async throws {
        for index in 0..<205 {
            let user = User(name: UserName("users/\(7000 + index)")!)
            h.server.react(message.name, emoji: .unicode("🙂"), by: .user(user))
        }
        let page = try await h.get(collection, ["pageSize": "500"], as: h.alice)
        #expect(page.items("reactions").count == 200)
        #expect(page.nextPageToken != nil)
        #expect(try await h.get(collection, ["pageSize": "0"], as: h.alice).items("reactions").count == 1)
    }

    @Test func listTokenIsBoundToTheQuery() async throws {
        for index in 0..<3 {
            h.server.react(
                message.name, emoji: .unicode("🙂"), by: .user(User(name: UserName("users/\(9000 + index)")!)))
        }
        let token = try #require(try await h.get(collection, ["pageSize": "1"], as: h.alice).nextPageToken)
        #expect(try await h.get(collection, ["pageSize": "1", "pageToken": token], as: h.alice).status == 200)
        #expect(try await h.get(collection, ["pageSize": "2", "pageToken": token], as: h.alice).status == 400)
        let filtered = try await h.get(
            collection, ["pageSize": "1", "pageToken": token, "filter": "emoji.unicode = \"🙂\""], as: h.alice)
        #expect(filtered.status == 400)
        #expect(filtered.errorStatus == "INVALID_ARGUMENT")
    }

    @Test func listFiltersByUser() async throws {
        _ = try await react("🙂", as: h.bob)
        _ = try await react("👍", as: h.bob)
        _ = try await react("🙂", as: h.alice)
        let filter = "user.name = \"\(h.bob.user.name.rawValue)\""
        let call = try await h.get(collection, ["filter": filter], as: h.alice)
        #expect(call.status == 200)
        let users = call.items("reactions").compactMap { ($0["user"] as? [String: Any])?["name"] as? String }
        #expect(users == [h.bob.user.name.rawValue, h.bob.user.name.rawValue])
    }

    @Test func listFiltersByUnicodeAndCombinations() async throws {
        _ = try await react("🙂", as: h.bob)
        _ = try await react("👍", as: h.bob)
        _ = try await react("🙂", as: h.alice)
        _ = try await react("🎉", as: h.alice)
        let bob = "user.name = \"\(h.bob.user.name.rawValue)\""
        let alice = "user.name = \"\(h.alice.user.name.rawValue)\""

        func count(_ filter: String) async throws -> Int {
            let call = try await h.get(collection, ["filter": filter], as: h.bob)
            #expect(call.status == 200, "\(filter)")
            return call.items("reactions").count
        }
        #expect(try await count("emoji.unicode = \"🙂\"") == 2)
        #expect(try await count("emoji.unicode = \"🙂\" AND \(bob)") == 1)
        #expect(try await count("emoji.unicode = \"🙂\" OR emoji.unicode = \"👍\"") == 3)
        #expect(try await count("\(bob) OR \(alice)") == 4)
        #expect(try await count("\(alice) AND (emoji.unicode = \"🙂\" OR emoji.unicode = \"🎉\")") == 2)
        #expect(try await count("\(alice) AND emoji.unicode = \"🙂\" OR \(bob)") == 3)
        #expect(try await count("emoji.unicode = \"🚀\"") == 0)
    }

    @Test(arguments: [
        "garbage", "user.name = users/1", "user.name == \"users/1\"", "user.name = \"users/1\" AND",
        "(user.name = \"users/1\"", "text = \"x\"", "user.name = \"users/1", "AND user.name = \"users/1\"",
        "user.name = \"users/1\" user.name = \"users/2\"",
    ])
    func listWithGarbageFilterIs400(filter: String) async throws {
        let call = try await h.get(collection, ["filter": filter], as: h.alice)
        #expect(call.status == 400)
        #expect(call.errorStatus == "INVALID_ARGUMENT")
    }

    @Test func listChecksMembershipAndMessage() async throws {
        #expect(try await h.get(collection, as: h.carol).status == 403)
        #expect(try await h.get("\(h.space.rawValue)/messages/Nope.Nope/reactions", as: h.alice).status == 404)
        #expect(try await h.get(collection, as: h.alice).json.isEmpty)
    }

    @Test func unsupportedMethodsAre404() async throws {
        #expect(try await h.call(.put, collection, as: h.alice).status == 404)
        #expect(try await h.call(.get, "\(collection)/x", as: h.alice).status == 404)
        #expect(try await h.call(.delete, collection, as: h.alice).status == 404)
    }

    // MARK: Failure rules

    @Test func createReactionCanBeFailedAndLostResponseStillCommits() async throws {
        h.server.fail(.unavailable(route: .createReaction))
        #expect(try await react(as: h.bob).status == 503)
        #expect(try await summaries().isEmpty)

        h.server.fail(.lostResponse(.networkConnectionLost, route: .createReaction))
        await #expect(throws: TransportError.connectionLost) { try await react(as: h.bob) }
        #expect(try await summaries().first?["reactionCount"] as? Int == 1)
        #expect(try await react(as: h.bob).status == 409)
    }

    @Test func deleteReactionCanBeFailed() async throws {
        let mine = try reactionName(try await react(as: h.bob))
        h.server.fail(.rateLimited(route: .deleteReaction, retryAfter: 3))
        let limited = try await h.call(.delete, mine, as: h.bob)
        #expect(limited.status == 429)
        #expect(limited.headers["retry-after"] == "3")
        #expect(try await summaries().count == 1)

        h.server.fail(.lostResponse(.timedOut, route: .deleteReaction))
        await #expect(throws: TransportError.timedOut) { try await h.call(.delete, mine, as: h.bob) }
        #expect(try await summaries().isEmpty)
        #expect(try await h.call(.delete, mine, as: h.bob).status == 403)
    }

    @Test func listReactionsCanBeFailedOnPageTwoOnly() async throws {
        for index in 0..<3 {
            h.server.react(message.name, emoji: .unicode("🙂"), by: .user(User(name: UserName("users/\(300 + index)")!)))
        }
        h.server.fail(.permissionDenied(route: .listReactions, reason: "R", onlyWithPageToken: true))
        let first = try await h.get(collection, ["pageSize": "2"], as: h.alice)
        #expect(first.status == 200)
        let token = try #require(first.nextPageToken)
        #expect(try await h.get(collection, ["pageSize": "2", "pageToken": token], as: h.alice).status == 403)
        #expect(try await h.get(collection, ["pageSize": "2", "pageToken": token], as: h.alice).status == 200)
    }

    @Test func reactionRoutesAreIndependent() async throws {
        h.server.fail(.unavailable(route: .listReactions))
        #expect(try await react(as: h.bob).status == 200)
        #expect(try await h.get(collection, as: h.alice).status == 503)
    }
}
