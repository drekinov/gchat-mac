import ChatModel
import ChatNet
import Foundation
import Testing

@testable import GoogleChat

@Suite struct RequestBuildingTests {
    @Test(arguments: [(-5, "1"), (0, "1"), (1, "1"), (50, "50"), (1000, "1000"), (5000, "1000")])
    func listSpacesClampsPageSize(requested: Int, sent: String) async throws {
        let transport = StubTransport()
        _ = try await makeClient(transport).listSpaces(pageSize: requested, pageToken: nil)
        let request = try #require(transport.requests.first)
        #expect(request.method == .get)
        #expect(request.url.path == "/v1/spaces")
        #expect(queryItems(request) == ["pageSize": sent])
    }

    @Test func requestsCarryBearerTokenAndNoBodyHeaders() async throws {
        let transport = StubTransport()
        _ = try await makeClient(transport).listSpaces(pageSize: 10, pageToken: nil)
        let request = try #require(transport.requests.first)
        #expect(request.headers["Authorization"] == "Bearer token-1")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Content-Type"] == nil)
        #expect(request.body == nil)
        #expect(request.url.host() == "chat.test")
    }

    @Test func pageTokenIsPercentEncodedAndRoundTrips() async throws {
        let transport = StubTransport()
        let token = "a/b+c==&x y?#é"
        _ = try await makeClient(transport).listSpaces(pageSize: 10, pageToken: token)
        let request = try #require(transport.requests.first)
        #expect(queryItems(request)["pageToken"] == token)
        let raw = request.url.absoluteString
        #expect(!raw.contains("+c"))
        #expect(!raw.contains(" "))
        #expect(raw.contains("pageToken=a%2Fb%2Bc%3D%3D%26x%20y%3F%23%C3%A9"))
    }

    @Test func getSpaceAndGetMessagePaths() async throws {
        let transport = StubTransport(status: 200, body: Data(#"{"name":"spaces/AAAA","spaceType":"SPACE"}"#.utf8))
        let client = makeClient(transport)
        _ = try await client.getSpace(testSpace)
        let message = MessageName(unchecked: "spaces/AAAA/messages/M.1")
        _ = await thrownError { try await client.getMessage(message) }
        #expect(transport.requests.map(\.url.path) == ["/v1/spaces/AAAA", "/v1/spaces/AAAA/messages/M.1"])
        #expect(transport.requests.allSatisfy { $0.url.query == nil })
    }

    @Test func updatingTextPatchesOnlyTheTextAndChecksTheReturnedName() async throws {
        let message = MessageName(unchecked: "spaces/AAAA/messages/M.1")
        let reply = #"{"name":"spaces/AAAA/messages/M.1","createTime":"2026-10-14T12:00:00Z","text":"fixed"}"#
        let transport = StubTransport(status: 200, body: Data(reply.utf8))
        let updated = try await makeClient(transport).updateMessageText(message, text: "fixed")
        let request = try #require(transport.requests.first)
        #expect(request.method == .patch)
        #expect(request.url.path == "/v1/spaces/AAAA/messages/M.1")
        #expect(queryItems(request) == ["updateMask": "text"])
        let body = try #require(
            request.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["text": "fixed", "markupSyntax": "MARKUP_SYNTAX_CHAT"])
        #expect(updated.text == "fixed")

        let other = StubTransport(status: 200, body: Data(reply.replacingOccurrences(of: "M.1", with: "M.2").utf8))
        let error = await thrownError { try await makeClient(other).updateMessageText(message, text: "x") }
        #expect(error == .decoding(path: "name"))
        let long = await thrownError {
            try await makeClient(StubTransport()).updateMessageText(
                message, text: String(repeating: "a", count: 32_001))
        }
        guard case .invalidArgument = long else {
            Issue.record("expected a client-side length error")
            return
        }
    }

    @Test(arguments: [false, true])
    func deletingSendsForceOnlyWhenAsked(force: Bool) async throws {
        let transport = StubTransport(status: 200, body: Data("{}".utf8))
        try await makeClient(transport).deleteMessage(MessageName(unchecked: "spaces/AAAA/messages/M.1"), force: force)
        let request = try #require(transport.requests.first)
        #expect(request.method == .delete)
        #expect(request.url.path == "/v1/spaces/AAAA/messages/M.1")
        #expect(queryItems(request) == (force ? ["force": "true"] : [:]))
    }

    @Test func listMessagesFilterIsExactlyOrderedAndEncoded() async throws {
        let transport = StubTransport()
        let thread = ThreadName(unchecked: "spaces/AAAA/threads/THR1")
        _ = try await makeClient(transport).listMessages(
            in: testSpace, window: .init(after: ts("2026-10-14T12:00:00Z"), before: ts("2026-10-14T13:30:00.5Z")),
            thread: thread, order: .descending, pageSize: 2000, showDeleted: true, pageToken: "next")
        let request = try #require(transport.requests.first)
        #expect(request.url.path == "/v1/spaces/AAAA/messages")
        #expect(queryNames(request) == ["pageSize", "pageToken", "filter", "orderBy", "showDeleted"])

        let query = queryItems(request)
        #expect(
            query["filter"]
                == #"createTime > "2026-10-14T12:00:00Z" AND createTime < "2026-10-14T13:30:00.500Z" AND thread.name = spaces/AAAA/threads/THR1"#
        )
        #expect(query["orderBy"] == "createTime DESC")
        #expect(query["showDeleted"] == "true")
        #expect(query["pageSize"] == "1000")
        #expect(query["pageToken"] == "next")

        let raw = request.url.absoluteString
        #expect(raw.contains("createTime%20%3E%20%222026-10-14T12%3A00%3A00Z%22%20AND%20"))
        #expect(!raw.contains("\""))
        #expect(!raw.contains("filter=createTime >"))
    }

    @Test func listMessagesOmitsOptionalParameters() async throws {
        let transport = StubTransport()
        _ = try await makeClient(transport).listMessages(
            in: testSpace, window: .init(), thread: nil, order: .ascending, pageSize: 100, showDeleted: false,
            pageToken: nil)
        let request = try #require(transport.requests.first)
        #expect(queryItems(request) == ["pageSize": "100", "orderBy": "createTime ASC"])
    }

    @Test func listMessagesSingleClauses() async throws {
        let transport = StubTransport()
        let client = makeClient(transport)
        for window in [
            CreateTimeWindow(after: ts("2026-01-01T00:00:00Z")), CreateTimeWindow(before: ts("2026-01-02T00:00:00Z")),
        ] {
            _ = try await client.listMessages(
                in: testSpace, window: window, thread: nil, order: .ascending, pageSize: 10, showDeleted: false,
                pageToken: nil)
        }
        #expect(queryItems(transport.requests[0])["filter"] == #"createTime > "2026-01-01T00:00:00Z""#)
        #expect(queryItems(transport.requests[1])["filter"] == #"createTime < "2026-01-02T00:00:00Z""#)
    }

    @Test func listSpaceEventsFilter() async throws {
        let transport = StubTransport()
        _ = try await makeClient(transport).listSpaceEvents(
            in: testSpace,
            types: ["google.workspace.chat.message.v1.created", "google.workspace.chat.reaction.v1.deleted"],
            start: ts("2026-10-01T00:00:00Z"), end: ts("2026-10-14T00:00:00Z"), pageToken: "ev-tok")
        let request = try #require(transport.requests.first)
        #expect(request.url.path == "/v1/spaces/AAAA/spaceEvents")
        #expect(queryNames(request) == ["filter", "pageToken"])
        #expect(
            queryItems(request)["filter"]
                == #"startTime="2026-10-01T00:00:00Z" AND endTime="2026-10-14T00:00:00Z" AND (eventTypes:"google.workspace.chat.message.v1.created" OR eventTypes:"google.workspace.chat.reaction.v1.deleted")"#
        )
        #expect(queryItems(request)["pageToken"] == "ev-tok")
    }

    @Test func listSpaceEventsAllowsExactly28Days() async throws {
        let transport = StubTransport()
        _ = try await makeClient(transport).listSpaceEvents(
            in: testSpace, types: ["t.v1.created"], start: ts("2026-09-16T00:00:00Z"), end: ts("2026-10-14T00:00:00Z"),
            pageToken: nil)
        #expect(transport.requests.count == 1)
    }

    @Test(
        arguments: [
            ([String](), "2026-10-01T00:00:00Z", "2026-10-02T00:00:00Z"),
            (["t.v1.created"], "2026-10-02T00:00:00Z", "2026-10-02T00:00:00Z"),
            (["t.v1.created"], "2026-10-03T00:00:00Z", "2026-10-02T00:00:00Z"),
            (["t.v1.created"], "2026-09-16T00:00:00Z", "2026-10-14T00:00:00.001Z"),
            (["t.v1.created"], "2026-01-01T00:00:00Z", "2026-10-14T00:00:00Z"),
            (["t.v1\" OR eventTypes:\"x"], "2026-10-01T00:00:00Z", "2026-10-02T00:00:00Z"),
            ([""], "2026-10-01T00:00:00Z", "2026-10-02T00:00:00Z"),
        ])
    func listSpaceEventsRejectsBadWindowWithoutSending(types: [String], start: String, end: String) async {
        let transport = StubTransport()
        let error = await thrownError {
            try await makeClient(transport).listSpaceEvents(
                in: testSpace, types: types, start: ts(start), end: ts(end), pageToken: nil)
        }
        guard case .invalidArgument(let info) = error else {
            Issue.record("expected invalidArgument, got \(String(describing: error))")
            return
        }
        #expect(info.httpStatus == 0)
        #expect(info.status == "CLIENT_INVALID_WINDOW")
        #expect(transport.requests.isEmpty)
    }

    @Test func membershipsAndCustomEmojiPaths() async throws {
        let transport = StubTransport()
        let client = makeClient(transport)
        _ = try await client.listMemberships(in: testSpace, pageToken: "m")
        _ = try await client.listCustomEmojis(pageToken: nil)
        #expect(transport.requests.map(\.url.path) == ["/v1/spaces/AAAA/members", "/v1/customEmojis"])
        #expect(queryItems(transport.requests[0]) == ["pageToken": "m"])
        #expect(transport.requests[1].url.query == nil)
    }

    @Test func readStateAndNotificationPaths() async throws {
        let transport = StubTransport()
        let client = makeClient(transport)
        _ = try await client.getSpaceReadState(testSpace)
        _ = try await client.getThreadReadState(ThreadName(unchecked: "spaces/AAAA/threads/THR.1"))
        _ = try await client.getNotificationSetting(testSpace)
        #expect(
            transport.requests.map(\.url.path) == [
                "/v1/users/me/spaces/AAAA/spaceReadState", "/v1/users/me/spaces/AAAA/threads/THR.1/threadReadState",
                "/v1/users/me/spaces/AAAA/spaceNotificationSetting",
            ])
        #expect(transport.requests.allSatisfy { $0.method == .get })
    }

    @Test func updateSpaceReadStatePatchesLastReadTime() async throws {
        let transport = StubTransport(
            status: 200,
            body: Data(
                #"{"name":"users/me/spaces/AAAA/spaceReadState","lastReadTime":"2026-10-14T12:00:00.123456Z"}"#.utf8))
        let stored = try await makeClient(transport).updateSpaceReadState(
            testSpace, lastReadTime: ts("2026-10-14T12:00:00.123456Z"))
        let request = try #require(transport.requests.first)
        #expect(request.method == .patch)
        #expect(request.url.path == "/v1/users/me/spaces/AAAA/spaceReadState")
        #expect(queryItems(request) == ["updateMask": "lastReadTime"])
        #expect(bodyString(request) == #"{"lastReadTime":"2026-10-14T12:00:00.123456Z"}"#)
        #expect(request.headers["Content-Type"] == "application/json; charset=utf-8")
        #expect(stored == ts("2026-10-14T12:00:00.123456Z"))
    }

    // MARK: createMessage

    static let requestID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-ABCDEF012345")!

    @Test func createMessageNewThread() async throws {
        let transport = StubTransport(status: 200, body: fixture("message_full"))
        _ = try await makeClient(transport).createMessage(
            NewMessage(space: testSpace, text: "hello \"world\" / ✓", requestID: Self.requestID))
        let request = try #require(transport.requests.first)
        #expect(request.method == .post)
        #expect(request.url.path == "/v1/spaces/AAAA/messages")
        #expect(queryItems(request) == ["requestId": "a1b2c3d4-0000-4000-8000-abcdef012345"])
        #expect(bodyString(request) == #"{"markupSyntax":"MARKUP_SYNTAX_CHAT","text":"hello \"world\" / ✓"}"#)
    }

    @Test func createMessageReplyToThread() async throws {
        let transport = StubTransport(status: 200, body: fixture("message_full"))
        let thread = ThreadName(unchecked: "spaces/AAAA/threads/THR1")
        _ = try await makeClient(transport).createMessage(
            NewMessage(space: testSpace, text: "re", reply: .thread(thread), requestID: Self.requestID))
        let request = try #require(transport.requests.first)
        #expect(
            queryItems(request) == [
                "requestId": "a1b2c3d4-0000-4000-8000-abcdef012345", "messageReplyOption": "REPLY_MESSAGE_OR_FAIL",
            ])
        #expect(bodyString(request) == #"{"markupSyntax":"MARKUP_SYNTAX_CHAT","text":"re","thread":{"name":"spaces/AAAA/threads/THR1"}}"#)
    }

    @Test func createMessageWithAttachments() async throws {
        let transport = StubTransport(status: 200, body: fixture("message_full"))
        _ = try await makeClient(transport).createMessage(
            NewMessage(
                space: testSpace, text: "pics", requestID: Self.requestID, attachmentUploadTokens: ["tok1", "tok/2"]))
        let request = try #require(transport.requests.first)
        let body = try #require(bodyString(request))
        #expect(
            body
                == #"{"attachment":[{"attachmentDataRef":{"attachmentUploadToken":"tok1"}},{"attachmentDataRef":{"attachmentUploadToken":"tok/2"}}],"markupSyntax":"MARKUP_SYNTAX_CHAT","text":"pics"}"#
        )
    }

    @Test func createMessageOmitsAttachmentWhenEmpty() async throws {
        let transport = StubTransport(status: 200, body: fixture("message_full"))
        _ = try await makeClient(transport).createMessage(
            NewMessage(space: testSpace, text: "plain", requestID: Self.requestID))
        let request = try #require(transport.requests.first)
        let body = try #require(bodyString(request))
        #expect(!body.contains("attachment"))
        #expect(!body.contains("thread"))
    }

    @Test func createMessageTextLimitIsInUTF8Bytes() async throws {
        let transport = StubTransport(status: 200, body: fixture("message_full"))
        let client = makeClient(transport)

        _ = try await client.createMessage(
            NewMessage(space: testSpace, text: String(repeating: "a", count: 32_000), requestID: Self.requestID))
        _ = try await client.createMessage(
            NewMessage(space: testSpace, text: String(repeating: "é", count: 16_000), requestID: Self.requestID))
        #expect(transport.requests.count == 2)

        for text in [String(repeating: "a", count: 32_001), String(repeating: "é", count: 16_001)] {
            let error = await thrownError {
                try await client.createMessage(NewMessage(space: testSpace, text: text, requestID: Self.requestID))
            }
            #expect(error == .invalidArgument(GoogleErrorInfo(httpStatus: 0, status: "CLIENT_TEXT_TOO_LONG")))
        }
        #expect(transport.requests.count == 2)
    }
}
