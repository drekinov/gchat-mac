import ChatModel
import ChatNet
import FakeChatServer
import Foundation
import Testing

@testable import GoogleChat

private struct FixedTokens: TokenProvider {
    var token: String
    func accessToken() async throws(ChatAPIError) -> String { token }
    func invalidate(_ token: String) async {}
}

private let topic = PubSubTopicPath("projects/example-project/topics/events-1")!
private let macA = PubSubSubscriptionPath("projects/example-project/subscriptions/events-1-mac-a")!
private let macB = PubSubSubscriptionPath("projects/example-project/subscriptions/events-1-mac-b")!

private struct EventsHarness {
    let server = FakeChatServer()
    let account: FakeAccount
    let client: WorkspaceEventsClient
    let space: SpaceName

    init() {
        account = server.addAccount(displayName: "Alice")
        space = server.addSpace(.space, displayName: "Team", members: [account])
        client = WorkspaceEventsClient(
            transport: server.makeTransport(), tokens: FixedTokens(token: account.token),
            sleeper: { _ in })
        server.addPullSubscription(macA.rawValue, topic: topic.rawValue)
        server.addPullSubscription(macB.rawValue, topic: topic.rawValue)
    }

    func publish(_ messages: [MessageName]) {
        server.publishMessagesCreated(
            topic: topic.rawValue, subscription: "subscriptions/sub-1", space: space, messages: messages)
    }
}

@Suite struct FakeEventsServerTests {
    @Test func createReturnsActiveSubscriptionAndDuplicateConflicts() async throws {
        let h = EventsHarness()
        let created = try await h.client.createSubscription(topic: topic)
        #expect(created.state == .active)
        #expect(created.authority == h.account.user.name.rawValue)
        #expect(created.expireTime == h.server.now.adding(.seconds(7 * 86400)))
        let error = await thrownError { try await h.client.createSubscription(topic: topic) }
        #expect(error?.isAlreadyExists == true)
        let other = PubSubTopicPath("projects/example-project/topics/events-2")!
        _ = try await h.client.createSubscription(topic: other)
        let listed = try await h.client.listSubscriptions(filter: .chat)
        #expect(listed.count == 2)
        #expect(listed.first { $0.name == created.name }?.pubsubTopic == topic.rawValue)
    }

    @Test func operationNotDoneFirstIsPolled() async throws {
        let h = EventsHarness()
        h.server.eventOperationPollsBeforeDone = 2
        let created = try await h.client.createSubscription(topic: topic)
        #expect(try await h.client.getSubscription(created.name).name == created.name)
        let operationGets = h.server.requests.filter { $0.path.hasPrefix("/v1/operations/") }
        #expect(operationGets.count == 2)
    }

    @Test func operationPendingBeyondBoundFails() async {
        let h = EventsHarness()
        h.server.eventOperationPollsBeforeDone = 50
        let error = await thrownError { try await h.client.createSubscription(topic: topic) }
        #expect(error?.isOperationPending == true)
    }

    @Test func operationFailureIsTyped() async {
        let h = EventsHarness()
        h.server.failNextEventOperation(code: 7)
        let error = await thrownError { try await h.client.createSubscription(topic: topic) }
        guard case .permissionDenied? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
    }

    @Test func renewExtendsExpiryAndSuspendedReactivates() async throws {
        let h = EventsHarness()
        let created = try await h.client.createSubscription(topic: topic)
        h.server.advance(.seconds(86400))
        let renewed = try await h.client.renewSubscription(created.name)
        #expect(renewed.expireTime == h.server.now.adding(.seconds(7 * 86400)))
        h.server.suspendEventSubscription(created.name.rawValue)
        #expect(try await h.client.getSubscription(created.name).state == .suspended)
        #expect(try await h.client.reactivateSubscription(created.name).state == .active)
        let notSuspended = await thrownError { try await h.client.reactivateSubscription(created.name) }
        guard case .failedPrecondition? = notSuspended else {
            Issue.record("got \(String(describing: notSuspended))")
            return
        }
    }

    @Test func deleteRemovesAndExpiredIsNotFound() async throws {
        let h = EventsHarness()
        let created = try await h.client.createSubscription(topic: topic)
        try await h.client.deleteSubscription(created.name)
        let gone = await thrownError { try await h.client.getSubscription(created.name) }
        guard case .notFound? = gone else {
            Issue.record("got \(String(describing: gone))")
            return
        }
        let second = try await h.client.createSubscription(topic: topic)
        h.server.advance(.seconds(8 * 86400))
        let expired = await thrownError { try await h.client.getSubscription(second.name) }
        guard case .notFound? = expired else {
            Issue.record("got \(String(describing: expired))")
            return
        }
    }

    @Test func otherAccountCannotSeeSubscription() async throws {
        let h = EventsHarness()
        let created = try await h.client.createSubscription(topic: topic)
        let bob = h.server.addAccount(displayName: "Bob")
        let bobClient = WorkspaceEventsClient(
            transport: h.server.makeTransport(), tokens: FixedTokens(token: bob.token), sleeper: { _ in })
        let error = await thrownError { try await bobClient.getSubscription(created.name) }
        guard case .notFound? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
        #expect(try await bobClient.listSubscriptions(filter: .chat).isEmpty)
    }

    @Test func pubsubGetReturnsTopicAndUnknownIs404() async throws {
        let h = EventsHarness()
        #expect(try await h.client.getSubscription(macA).topic == topic)
        let missing = PubSubSubscriptionPath("projects/example-project/subscriptions/nope-nope")!
        let error = await thrownError { try await h.client.getSubscription(missing) }
        guard case .notFound? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
    }

    @Test func publishFansOutToEveryPullSubscription() async throws {
        let h = EventsHarness()
        let other = PubSubTopicPath("projects/example-project/topics/other")!
        let solo = PubSubSubscriptionPath("projects/example-project/subscriptions/other-sub")!
        h.server.addPullSubscription(solo.rawValue, topic: other.rawValue)
        let message = MessageName("\(h.space.rawValue)/messages/m1.m1")!
        h.publish([message])
        let a = try await h.client.pull(macA, maxMessages: 50)
        let b = try await h.client.pull(macB, maxMessages: 50)
        #expect(a.count == 1 && b.count == 1)
        #expect(a[0].subscription?.rawValue == "subscriptions/sub-1")
        #expect(a[0].chatEvents.count == 1)
        guard case .messagesCreated(let space, let names, _) = a[0].chatEvents[0] else {
            Issue.record("wrong event")
            return
        }
        #expect(space == h.space && names == [message])
        #expect(try await h.client.pull(solo, maxMessages: 50).isEmpty)
        #expect(a[0].ackID != b[0].ackID)
    }

    @Test func unackedMessagesAreRedeliveredAfterDeadline() async throws {
        let h = EventsHarness()
        h.publish([MessageName("\(h.space.rawValue)/messages/m1.m1")!])
        let first = try await h.client.pull(macA, maxMessages: 50)
        #expect(first.count == 1)
        #expect(try await h.client.pull(macA, maxMessages: 50).isEmpty)
        h.server.advance(.seconds(11))
        let second = try await h.client.pull(macA, maxMessages: 50)
        #expect(second.count == 1)
        #expect(second[0].ackID != first[0].ackID)
        #expect(second[0].attributes["ce-id"] == first[0].attributes["ce-id"])
        try await h.client.acknowledge(macA, ackIDs: [second[0].ackID])
        h.server.advance(.seconds(11))
        #expect(try await h.client.pull(macA, maxMessages: 50).isEmpty)
        #expect(h.server.unackedCount(macA.rawValue) == 0)
        #expect(h.server.unackedCount(macB.rawValue) == 1)
    }

    @Test func pullRespectsMaxMessages() async throws {
        let h = EventsHarness()
        for index in 0..<5 { h.publish([MessageName("\(h.space.rawValue)/messages/m\(index).m")!]) }
        #expect(try await h.client.pull(macA, maxMessages: 3).count == 3)
        #expect(try await h.client.pull(macA, maxMessages: 3).count == 2)
    }

    @Test func publishedShapesDecode() async throws {
        let h = EventsHarness()
        let names = (1...2).map { MessageName("\(h.space.rawValue)/messages/m\($0).m")! }
        h.publish(names)
        h.server.publishMembershipsCreated(
            topic: topic.rawValue, subscription: "subscriptions/sub-1", space: h.space,
            memberships: [MembershipName("\(h.space.rawValue)/members/1")!])
        h.server.publishLifecycle(.suspended, topic: topic.rawValue, subscription: "subscriptions/sub-1")
        let events = try await h.client.pull(macA, maxMessages: 50)
        let decoded = events.flatMap(\.chatEvents)
        guard decoded.count == 3, case .messagesCreated(_, let batch, _) = decoded[0] else {
            Issue.record("got \(decoded)")
            return
        }
        #expect(batch == names)
        #expect(decoded[1] == .membershipCreated(space: h.space, time: h.server.now))
        #expect(decoded[2] == .suspended(subscription: EventSubscriptionName("subscriptions/sub-1")!))
    }

    @Test func failureRulesApplyToEventsRoutes() async throws {
        let h = EventsHarness()
        h.server.fail(.unavailable(route: .pull, times: 1))
        let error = await thrownError { try await h.client.pull(macA, maxMessages: 50) }
        guard case .server? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
        #expect(try await h.client.pull(macA, maxMessages: 50).isEmpty)
        h.server.fail(.permissionDenied(route: .getPullSubscription))
        let denied = await thrownError { try await h.client.getSubscription(macA) }
        guard case .permissionDenied? = denied else {
            Issue.record("got \(String(describing: denied))")
            return
        }
        h.server.fail(.rateLimited(route: .createEventSubscription, retryAfter: 3))
        let limited = await thrownError { try await h.client.createSubscription(topic: topic) }
        #expect(limited == .rateLimited(retryAfter: .seconds(3)))
    }
}
