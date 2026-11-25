import ChatModel
import ChatNet
import Foundation
import Synchronization
import Testing

@testable import GoogleChat

private let topic = PubSubTopicPath("projects/example-project/topics/events-1")!
private let pullPath = PubSubSubscriptionPath("projects/example-project/subscriptions/events-1-mac")!
private let subName = EventSubscriptionName("subscriptions/sub-abc123")!

private func jsonResponse(_ name: String, status: Int = 200) -> Result<HTTPResponse, TransportError> {
    .success(HTTPResponse(status: status, body: fixture(name)))
}

private final class SleepLog: Sendable {
    private let items = Mutex<[Duration]>([])
    var count: Int { items.withLock { $0.count } }
    func record(_ duration: Duration) { items.withLock { $0.append(duration) } }
}

private func eventsClient(
    _ transport: StubTransport, sleeps: SleepLog = SleepLog()
) -> WorkspaceEventsClient {
    WorkspaceEventsClient(
        transport: transport, tokens: StubTokens(), eventsBaseURL: URL(string: "https://events.test")!,
        pubsubBaseURL: URL(string: "https://pubsub.test")!, maxOperationPolls: 3, pollDelay: .milliseconds(10),
        sleeper: { sleeps.record($0) })
}

private func json(_ request: HTTPRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
}

@Suite struct WorkspaceEventsClientTests {
    @Test func createBuildsExactBody() async throws {
        let transport = StubTransport([jsonResponse("events_operation_done")])
        let created = try await eventsClient(transport).createSubscription(topic: topic)
        let request = transport.requests[0]
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://events.test/v1/subscriptions")
        #expect(
            bodyString(request)
                == #"{"eventTypes":["google.workspace.chat.message.v1.created","google.workspace.chat.membership.v1.created"],"#
                + #""notificationEndpoint":{"pubsubTopic":"projects/example-project/topics/events-1"},"#
                + #""payloadOptions":{"includeResource":false},"targetResource":"//chat.googleapis.com/spaces/-","ttl":"604800s"}"#
        )
        #expect(created.name == subName)
        #expect(created.state == .active)
        #expect(created.pubsubTopic == topic.rawValue)
        #expect(created.expireTime == ts("2026-01-08T00:00:00.123456Z"))
        #expect(created.authority == "users/100000000000001")
        #expect(created.eventTypes == EventSubscription.requiredEventTypes)
    }

    @Test func renewPatchesTTLOnly() async throws {
        let transport = StubTransport([jsonResponse("events_operation_done")])
        _ = try await eventsClient(transport).renewSubscription(subName)
        let request = transport.requests[0]
        #expect(request.method == .patch)
        #expect(request.url.absoluteString == "https://events.test/v1/subscriptions/sub-abc123?updateMask=ttl")
        #expect(bodyString(request) == #"{"ttl":"604800s"}"#)
    }

    @Test func reactivateAndDeleteUseDocumentedPaths() async throws {
        let transport = StubTransport([
            jsonResponse("events_operation_done"), jsonResponse("events_operation_delete_done"),
        ])
        let client = eventsClient(transport)
        _ = try await client.reactivateSubscription(subName)
        try await client.deleteSubscription(subName)
        #expect(transport.requests[0].method == .post)
        #expect(transport.requests[0].url.path == "/v1/subscriptions/sub-abc123:reactivate")
        #expect(transport.requests[1].method == .delete)
        #expect(transport.requests[1].url.path == "/v1/subscriptions/sub-abc123")
    }

    @Test func getDecodesSuspension() async throws {
        let transport = StubTransport([jsonResponse("events_subscription_suspended")])
        let sub = try await eventsClient(transport).getSubscription(subName)
        #expect(sub.state == .suspended)
        #expect(sub.suspensionReason == "USER_SCOPE_REVOKED")
        #expect(sub.authority == nil)
    }

    @Test func unknownStateIsPreserved() {
        #expect(EventSubscription.State("STATE_UNSPECIFIED") == .unknown("STATE_UNSPECIFIED"))
        #expect(EventSubscription.State("DELETED") == .deleted)
    }

    @Test func listBuildsDocumentedFilter() async throws {
        let transport = StubTransport([jsonResponse("events_subscriptions_list")])
        let subs = try await eventsClient(transport).listSubscriptions(filter: .chat)
        #expect(subs.map(\.name) == [subName])
        let filter = queryItems(transport.requests[0])["filter"]
        #expect(
            filter
                == #"(event_types:"google.workspace.chat.message.v1.created" OR event_types:"google.workspace.chat.membership.v1.created") AND target_resource="//chat.googleapis.com/spaces/-""#
        )
    }

    @Test func pendingOperationIsPolledUntilDone() async throws {
        let sleeps = SleepLog()
        let transport = StubTransport([
            jsonResponse("events_operation_pending"), jsonResponse("events_operation_pending"),
            jsonResponse("events_operation_done"),
        ])
        let created = try await eventsClient(transport, sleeps: sleeps).createSubscription(topic: topic)
        #expect(created.name == subName)
        #expect(transport.requests.map(\.method) == [.post, .get, .get])
        #expect(transport.requests[1].url.absoluteString == "https://events.test/v1/operations/op-1")
        #expect(sleeps.count == 2)
    }

    @Test func operationStillPendingFailsWithTypedError() async {
        let transport = StubTransport([jsonResponse("events_operation_pending")])
        let error = await thrownError { try await eventsClient(transport).createSubscription(topic: topic) }
        #expect(error?.isOperationPending == true)
        #expect(transport.requests.count == 4)
    }

    @Test func operationErrorMapsToTypedError() async {
        let transport = StubTransport([jsonResponse("events_operation_error")])
        let error = await thrownError { try await eventsClient(transport).renewSubscription(subName) }
        guard case .permissionDenied(let info)? = error else {
            Issue.record("expected permissionDenied, got \(String(describing: error))")
            return
        }
        #expect(info.status == "PERMISSION_DENIED")
        #expect(!"\(error!)".contains("CANARY"))
    }

    @Test func alreadyExistsIsDetectable() async {
        let transport = StubTransport(
            status: 409, body: Data(#"{"error":{"code":409,"status":"ALREADY_EXISTS"}}"#.utf8))
        let error = await thrownError { try await eventsClient(transport).createSubscription(topic: topic) }
        #expect(error?.isAlreadyExists == true)
        #expect(ChatAPIError.notFound(GoogleErrorInfo(httpStatus: 404)).isAlreadyExists == false)
    }

    @Test func operationAlreadyExistsCodeIsDetectable() async {
        let body = Data(#"{"name":"operations/op-1","done":true,"error":{"code":6,"message":"x"}}"#.utf8)
        let transport = StubTransport(status: 200, body: body)
        let error = await thrownError { try await eventsClient(transport).createSubscription(topic: topic) }
        #expect(error?.isAlreadyExists == true)
    }

    @Test func refreshesTokenOn401() async throws {
        let unauthorized = Result<HTTPResponse, TransportError>.success(HTTPResponse(status: 401))
        let transport = StubTransport([unauthorized, jsonResponse("events_subscription")])
        let tokens = StubTokens()
        let client = WorkspaceEventsClient(
            transport: transport, tokens: tokens, eventsBaseURL: URL(string: "https://events.test")!)
        _ = try await client.getSubscription(subName)
        #expect(tokens.invalidated == ["token-1"])
        #expect(transport.requests.map { $0.headers["Authorization"] } == ["Bearer token-1", "Bearer token-2"])
    }

    @Test func operationNamesAreValidated() {
        #expect(WorkspaceEventsClient.isValidOperationName("operations/op-1"))
        #expect(!WorkspaceEventsClient.isValidOperationName("operations/../x"))
        #expect(!WorkspaceEventsClient.isValidOperationName("subscriptions/x"))
        #expect(!WorkspaceEventsClient.isValidOperationName("operations/a?b"))
    }
}

@Suite struct PubSubClientTests {
    @Test func pathValidationRejectsBadPaths() {
        let good = "projects/example-project/subscriptions/events-1-mac"
        #expect(PubSubSubscriptionPath(good) != nil)
        for bad in [
            "projects/Example/subscriptions/abc", "projects/abc/subscriptions/abc",
            "projects/example-project/subscriptions/ab",
            "projects/example-project/subscriptions/1abc", "projects/example-project/subscriptions/abc/../x",
            "projects/example-project/subscriptions/abc?x=1", "projects/example-project/topics/abc",
            "projects/example-project-/subscriptions/abc", "projects/-example/subscriptions/abc",
            "projects/example-project/subscriptions/abc/def", "/projects/example-project/subscriptions/abc",
            "projects/example-project/subscriptions/" + String(repeating: "a", count: 256),
        ] {
            #expect(PubSubSubscriptionPath(bad) == nil, "\(bad)")
        }
        #expect(PubSubTopicPath("projects/example-project/topics/events-1") != nil)
        #expect(PubSubTopicPath("projects/example-project/subscriptions/events-1") == nil)
        #expect(PubSubTopicPath("projects/example-project/topics/e/../x") == nil)
        #expect(PubSubSubscriptionPath("projects/example-project/subscriptions/a.b~c+d%e_f-g") != nil)
    }

    @Test func projectNumbersAreAccepted() {
        #expect(PubSubSubscriptionPath("projects/123456789012/subscriptions/events-1-mac") != nil)
        #expect(PubSubTopicPath("projects/123456789012/topics/events-1") != nil)
        for bad in ["projects/12-34/topics/events-1", "projects/" + String(repeating: "1", count: 31) + "/topics/t1"] {
            #expect(PubSubTopicPath(bad) == nil, "\(bad)")
        }
    }

    @Test func getReadsTopic() async throws {
        let transport = StubTransport([jsonResponse("pubsub_subscription")])
        let sub = try await eventsClient(transport).getSubscription(pullPath)
        #expect(sub.topic == topic)
        #expect(sub.ackDeadlineSeconds == 10)
        #expect(
            transport.requests[0].url.absoluteString
                == "https://pubsub.test/v1/projects/example-project/subscriptions/events-1-mac")
    }

    @Test func getRejectsMalformedTopic() async {
        let body = Data(
            #"{"name":"projects/example-project/subscriptions/events-1-mac","topic":"_deleted-topic_"}"#.utf8)
        let transport = StubTransport(status: 200, body: body)
        let error = await thrownError { try await eventsClient(transport).getSubscription(pullPath) }
        #expect(error == .decoding(path: "topic"))
    }

    @Test func pullBuildsRequestAndDecodes() async throws {
        let transport = StubTransport([jsonResponse("pubsub_pull_two")])
        let events = try await eventsClient(transport).pull(pullPath, maxMessages: 50)
        let request = transport.requests[0]
        #expect(request.method == .post)
        #expect(
            request.url.absoluteString
                == "https://pubsub.test/v1/projects/example-project/subscriptions/events-1-mac:pull")
        #expect(bodyString(request) == #"{"maxMessages":50,"returnImmediately":false}"#)
        #expect(request.timeout == .seconds(90))
        #expect(events.map(\.ackID) == ["ack-1", "ack-2"])
        #expect(events[0].time == ts("2026-01-01T00:00:05.5Z"))
        #expect(events[0].subscription == subName)
        #expect(
            events[0].chatEvents == [
                .messagesCreated(
                    space: SpaceName("spaces/AAAA")!, messages: [MessageName("spaces/AAAA/messages/m1.m1")!],
                    time: ts("2026-01-01T00:00:05.5Z"))
            ])
        #expect(events[1].chatEvents.count == 1)
    }

    @Test func emptyPullYieldsNoEvents() async throws {
        let transport = StubTransport(status: 200, body: Data("{}".utf8))
        let events = try await eventsClient(transport).pull(pullPath, maxMessages: 50)
        #expect(events.isEmpty)
    }

    @Test func pullRejectsBadBase64() async {
        let body = Data(#"{"receivedMessages":[{"ackId":"a","message":{"data":"!!!","attributes":{}}}]}"#.utf8)
        let transport = StubTransport(status: 200, body: body)
        let error = await thrownError { try await eventsClient(transport).pull(pullPath, maxMessages: 50) }
        #expect(error == .decoding(path: "receivedMessages.message.data"))
    }

    @Test func acknowledgeSendsIDs() async throws {
        let transport = StubTransport(status: 200, body: Data("{}".utf8))
        try await eventsClient(transport).acknowledge(pullPath, ackIDs: ["a", "b"])
        let request = transport.requests[0]
        #expect(request.url.path == "/v1/projects/example-project/subscriptions/events-1-mac:acknowledge")
        #expect(bodyString(request) == #"{"ackIds":["a","b"]}"#)
        #expect(request.timeout == .seconds(30))
    }

    @Test func acknowledgeSplitsLargeBatches() async throws {
        let transport = StubTransport(status: 200, body: Data("{}".utf8))
        try await eventsClient(transport).acknowledge(pullPath, ackIDs: (0..<501).map(String.init))
        #expect(transport.requests.count == 2)
        #expect((json(transport.requests[1])["ackIds"] as? [String])?.count == 1)
    }
}

@Suite struct ChatEventDecodingTests {
    func event(
        _ type: String, data: String, subject: String? = "//chat.googleapis.com/spaces/AAAA",
        time: String? = "2026-01-01T00:00:05Z",
        source: String = "//workspaceevents.googleapis.com/subscriptions/sub-abc123"
    ) -> ReceivedEvent {
        var attributes = ["ce-type": type, "ce-source": source]
        if let subject { attributes["ce-subject"] = subject }
        if let time { attributes["ce-time"] = time }
        return ReceivedEvent(ackID: "a", attributes: attributes, data: Data(data.utf8))
    }

    func fixtureString(_ name: String) -> String { String(decoding: fixture(name), as: UTF8.self) }

    @Test func singleMessage() {
        let e = event("google.workspace.chat.message.v1.created", data: fixtureString("cloudevent_message_created"))
        #expect(
            e.chatEvents == [
                .messagesCreated(
                    space: SpaceName("spaces/AAAA")!, messages: [MessageName("spaces/AAAA/messages/m1.m1")!],
                    time: ts("2026-01-01T00:00:05Z"))
            ])
    }

    @Test func batchMessage() {
        let e = event(
            "google.workspace.chat.message.v1.batchCreated", data: fixtureString("cloudevent_message_batch_created"))
        #expect(
            e.chatEvents == [
                .messagesCreated(
                    space: SpaceName("spaces/AAAA")!,
                    messages: [MessageName("spaces/AAAA/messages/m1.m1")!, MessageName("spaces/AAAA/messages/m2.m2")!],
                    time: ts("2026-01-01T00:00:05Z"))
            ])
    }

    @Test func batchAcrossSpacesYieldsOneEventPerSpace() {
        let data =
            #"{"messages":[{"message":{"name":"spaces/A/messages/1"}},{"message":{"name":"spaces/B/messages/2"}}]}"#
        let events = event("google.workspace.chat.message.v1.batchCreated", data: data, subject: nil).chatEvents
        #expect(events.count == 2)
    }

    @Test func messageWithoutNamesFallsBackToSubject() {
        let e = event("google.workspace.chat.message.v1.created", data: "{}")
        #expect(
            e.chatEvents == [
                .messagesCreated(space: SpaceName("spaces/AAAA")!, messages: [], time: ts("2026-01-01T00:00:05Z"))
            ])
    }

    @Test func messageWithoutAnySpaceIsUnknown() {
        let e = event("google.workspace.chat.message.v1.created", data: "{}", subject: nil)
        #expect(e.chatEvents == [.unknown(type: "google.workspace.chat.message.v1.created")])
    }

    @Test func invalidMessageNamesNeverEscape() {
        let data = #"{"message":{"name":"spaces/AAAA/messages/../../x"}}"#
        let e = event("google.workspace.chat.message.v1.created", data: data)
        #expect(
            e.chatEvents == [
                .messagesCreated(space: SpaceName("spaces/AAAA")!, messages: [], time: ts("2026-01-01T00:00:05Z"))
            ])
    }

    @Test func singleMembership() {
        let e = event(
            "google.workspace.chat.membership.v1.created", data: fixtureString("cloudevent_membership_created"))
        #expect(
            e.chatEvents == [.membershipCreated(space: SpaceName("spaces/AAAA")!, time: ts("2026-01-01T00:00:05Z"))])
    }

    @Test func batchMembership() {
        let e = event(
            "google.workspace.chat.membership.v1.batchCreated",
            data: fixtureString("cloudevent_membership_batch_created"))
        #expect(
            e.chatEvents == [
                .membershipCreated(space: SpaceName("spaces/AAAA")!, time: ts("2026-01-01T00:00:05Z")),
                .membershipCreated(space: SpaceName("spaces/BBBB")!, time: ts("2026-01-01T00:00:05Z")),
            ])
    }

    @Test func lifecycleEvents() {
        let reminder = event(
            "google.workspace.events.subscription.v1.expirationReminder",
            data: fixtureString("cloudevent_expiration_reminder"), subject: nil)
        #expect(
            reminder.chatEvents == [.expirationReminder(subscription: subName, expireTime: ts("2026-01-08T00:00:00Z"))])
        let suspended = event(
            "google.workspace.events.subscription.v1.suspended", data: fixtureString("cloudevent_lifecycle"),
            subject: nil)
        #expect(suspended.chatEvents == [.suspended(subscription: subName)])
        let expired = event(
            "google.workspace.events.subscription.v1.expired", data: fixtureString("cloudevent_lifecycle"),
            subject: nil)
        #expect(expired.chatEvents == [.expired(subscription: subName)])
    }

    @Test func lifecycleFallsBackToSourceWhenPayloadIsEmpty() {
        let e = event("google.workspace.events.subscription.v1.expired", data: "", subject: nil)
        #expect(e.chatEvents == [.expired(subscription: subName)])
    }

    @Test func unknownAndMalformed() {
        #expect(
            event("google.workspace.chat.space.v1.updated", data: "{}").chatEvents == [
                .unknown(type: "google.workspace.chat.space.v1.updated")
            ])
        #expect(event("google.workspace.chat.message.v1.created", data: "not json").chatEvents.count == 1)
        #expect(ReceivedEvent(ackID: "a", attributes: [:], data: Data()).chatEvents == [.unknown(type: nil)])
    }

    @Test func missingCeTimeFallsBackToPublishTime() {
        var e = event("google.workspace.chat.message.v1.created", data: "{}", time: nil)
        e.publishTime = ts("2026-01-01T00:00:09Z")
        #expect(
            e.chatEvents == [
                .messagesCreated(space: SpaceName("spaces/AAAA")!, messages: [], time: ts("2026-01-01T00:00:09Z"))
            ])
    }

    @Test func sourceNormalization() {
        #expect(
            ReceivedEvent.subscriptionName(fromSource: "//workspaceevents.googleapis.com/subscriptions/sub-abc123")
                == subName)
        #expect(ReceivedEvent.subscriptionName(fromSource: "subscriptions/sub-abc123") == subName)
        #expect(ReceivedEvent.subscriptionName(fromSource: "//evil.example/subscriptions/x") == nil)
        #expect(ReceivedEvent.subscriptionName(fromSource: nil) == nil)
        #expect(ReceivedEvent.subscriptionName(fromSource: "//workspaceevents.googleapis.com/subscriptions/a/b") == nil)
    }

    @Test func subjectSpaceParsing() {
        let e = event("x", data: "{}", subject: "//chat.googleapis.com/spaces/AAAA/messages/m1")
        #expect(e.subjectSpace == SpaceName("spaces/AAAA"))
        #expect(event("x", data: "{}", subject: "//other/spaces/AAAA").subjectSpace == nil)
    }
}
