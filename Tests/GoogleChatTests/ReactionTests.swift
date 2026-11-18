import ChatModel
import ChatNet
import Foundation
import Testing

@testable import GoogleChat

@Suite struct ReactionTests {
    let message = MessageName(unchecked: "spaces/AAAA/messages/M1")
    let reactionName = ReactionName(unchecked: "spaces/AAAA/messages/M1/reactions/R1")

    func reactionJSON(name: String = "spaces/AAAA/messages/M1/reactions/R1", emoji: String) -> Data {
        Data(#"{"name":"\#(name)","user":{"name":"users/1001","type":"HUMAN"},"emoji":\#(emoji)}"#.utf8)
    }

    @Test func createUnicodeReaction() async throws {
        let transport = StubTransport(status: 200, body: reactionJSON(emoji: #"{"unicode":"👍"}"#))
        let reaction = try await makeClient(transport).createReaction(on: message, emoji: .unicode("👍"))
        let request = try #require(transport.requests.first)
        #expect(request.method == .post)
        #expect(request.url.path == "/v1/spaces/AAAA/messages/M1/reactions")
        #expect(request.url.query == nil)
        #expect(bodyString(request) == #"{"emoji":{"unicode":"👍"}}"#)
        #expect(request.headers["Content-Type"] == "application/json; charset=utf-8")
        #expect(reaction == Reaction(name: reactionName, user: UserName(unchecked: "users/1001"), emoji: .unicode("👍")))
    }

    @Test func createCustomReactionSendsTheResourceName() async throws {
        let custom = CustomEmojiName(unchecked: "customEmojis/PARTY1")
        let transport = StubTransport(
            status: 200,
            body: reactionJSON(
                emoji: #"{"customEmoji":{"name":"customEmojis/PARTY1","uid":"PARTY1","emojiName":":party:"}}"#))
        let reaction = try await makeClient(transport).createReaction(
            on: message, emoji: .custom(custom, shortcode: ":ignored:"))
        let request = try #require(transport.requests.first)
        #expect(request.method == .post)
        #expect(request.url.path == "/v1/spaces/AAAA/messages/M1/reactions")
        #expect(bodyString(request) == #"{"emoji":{"customEmoji":{"name":"customEmojis/PARTY1"}}}"#)
        #expect(reaction.emoji == .custom(custom, shortcode: ":party:"))
    }

    @Test func createAcceptsMultiScalarEmojiUpToTheLimit() async throws {
        let family = "👨‍👩‍👧‍👦"
        let transport = StubTransport(status: 200, body: reactionJSON(emoji: #"{"unicode":"\#(family)"}"#))
        let reaction = try await makeClient(transport).createReaction(on: message, emoji: .unicode(family))
        #expect(reaction.emoji == .unicode(family))
        #expect(bodyString(try #require(transport.requests.first)) == #"{"emoji":{"unicode":"\#(family)"}}"#)
    }

    @Test(arguments: ["", String(repeating: "a", count: 17), String(repeating: "👍", count: 17)])
    func createRejectsEmptyOrOversizedUnicodeWithoutSending(text: String) async {
        let transport = StubTransport()
        let error = await thrownError {
            try await makeClient(transport).createReaction(on: message, emoji: .unicode(text))
        }
        #expect(error == .invalidArgument(GoogleErrorInfo(httpStatus: 0, status: "CLIENT_INVALID_EMOJI")))
        #expect(transport.requests.isEmpty)
    }

    @Test func createRejectsAReactionBelongingToAnotherMessage() async {
        let transport = StubTransport(
            status: 200,
            body: reactionJSON(name: "spaces/AAAA/messages/OTHER/reactions/R1", emoji: #"{"unicode":"👍"}"#))
        let error = await thrownError {
            try await makeClient(transport).createReaction(on: message, emoji: .unicode("👍"))
        }
        #expect(error == .decoding(path: "name"))

        let otherSpace = StubTransport(
            status: 200,
            body: reactionJSON(name: "spaces/ZZZZ/messages/M1/reactions/R1", emoji: #"{"unicode":"👍"}"#))
        let spaceError = await thrownError {
            try await makeClient(otherSpace).createReaction(on: message, emoji: .unicode("👍"))
        }
        #expect(spaceError == .decoding(path: "name"))
    }

    @Test func createResponseWithoutUserStillSucceeds() async throws {
        let transport = StubTransport(
            status: 200, body: Data(#"{"name":"spaces/AAAA/messages/M1/reactions/R1","emoji":{"unicode":"👍"}}"#.utf8))
        let reaction = try await makeClient(transport).createReaction(on: message, emoji: .unicode("👍"))
        #expect(reaction.name.rawValue == "spaces/AAAA/messages/M1/reactions/R1")
    }

    @Test func createWithMalformedResponseIsADecodingError() async {
        let transport = StubTransport(status: 200, body: Data(#"{"name":"spaces/AAAA/messages/M1/reactions/R1"}"#.utf8))
        let error = await thrownError {
            try await makeClient(transport).createReaction(on: message, emoji: .unicode("👍"))
        }
        #expect(error == .decoding(path: "emoji"))
    }

    @Test func createConflictSurfaces() async {
        let (client, _) = clientServing("error_409", status: 409)
        let error = await thrownError { try await client.createReaction(on: message, emoji: .unicode("👍")) }
        guard case .conflict = error else {
            Issue.record("expected conflict, got \(String(describing: error))")
            return
        }
    }

    // MARK: delete

    @Test func deleteUsesDeleteOnTheReactionPath() async throws {
        let transport = StubTransport(status: 200, body: Data("{}".utf8))
        try await makeClient(transport).deleteReaction(reactionName)
        let request = try #require(transport.requests.first)
        #expect(request.method == .delete)
        #expect(request.url.path == "/v1/spaces/AAAA/messages/M1/reactions/R1")
        #expect(request.url.query == nil)
        #expect(request.body == nil)
    }

    @Test func deleteAcceptsAnEmptyBody() async throws {
        let transport = StubTransport(status: 200, body: Data())
        try await makeClient(transport).deleteReaction(reactionName)
        #expect(transport.requests.count == 1)
    }

    @Test func deleteOfMissingReactionIsNotFound() async {
        let (client, _) = clientServing("error_404", status: 404)
        let error = await thrownError { try await client.deleteReaction(reactionName) }
        guard case .notFound = error else {
            Issue.record("expected notFound, got \(String(describing: error))")
            return
        }
    }

    // MARK: list

    @Test func listFiltersByUserAndRoundTrips() async throws {
        let transport = StubTransport()
        _ = try await makeClient(transport).listReactions(
            on: message, user: UserName(unchecked: "users/1001"), pageToken: "a/b+c==")
        let request = try #require(transport.requests.first)
        #expect(request.method == .get)
        #expect(request.url.path == "/v1/spaces/AAAA/messages/M1/reactions")
        #expect(queryNames(request) == ["pageSize", "pageToken", "filter"])
        let query = queryItems(request)
        #expect(query["filter"] == #"user.name = "users/1001""#)
        #expect(query["pageToken"] == "a/b+c==")
        #expect(query["pageSize"] == "200")
        #expect(request.url.absoluteString.contains("filter=user.name%20%3D%20%22users%2F1001%22"))
        #expect(!request.url.absoluteString.contains("\""))
    }

    @Test func listWithoutUserSendsNoFilter() async throws {
        let transport = StubTransport()
        _ = try await makeClient(transport).listReactions(on: message, user: nil, pageToken: nil)
        #expect(queryItems(try #require(transport.requests.first)) == ["pageSize": "200"])
    }

    @Test func listMapsValidReactionsAndCountsSkipped() async throws {
        let (client, _) = clientServing("reactions_list")
        let page = try await client.listReactions(on: message, user: nil, pageToken: nil)
        #expect(
            page.items == [
                Reaction(name: reactionName, user: UserName(unchecked: "users/1001"), emoji: .unicode("👍")),
                Reaction(
                    name: ReactionName(unchecked: "spaces/AAAA/messages/M1/reactions/R2"),
                    user: UserName(unchecked: "users/1002"),
                    emoji: .custom(CustomEmojiName(unchecked: "customEmojis/PARTY1"), shortcode: ":party:")),
            ])
        #expect(page.skipped == 5)
        #expect(page.nextPageToken == "react-next")
    }

    @Test func listWithNoReactionsIsEmpty() async throws {
        let transport = StubTransport()
        let page = try await makeClient(transport).listReactions(on: message, user: nil, pageToken: nil)
        #expect(page.items.isEmpty)
        #expect(page.skipped == 0)
        #expect(page.nextPageToken == nil)
    }
}
