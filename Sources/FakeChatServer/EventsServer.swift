import ChatModel
import Foundation

struct FakeEventSubscription: Sendable {
    var name: String
    var authority: UserName
    var targetResource: String
    var eventTypes: [String]
    var topic: String
    var state = "ACTIVE"
    var suspensionReason: String?
    var createTime: Timestamp
    var updateTime: Timestamp
    var expireTime: Timestamp
}

struct FakeEventOperation: Sendable {
    var name: String
    var remainingPolls: Int
    /// Nil for a delete, whose response is empty.
    var subscription: String?
    var failureCode: Int?
}

struct FakePubSubMessage: Sendable {
    var messageID: String
    var attributes: [String: String]
    var data: Data
    var publishTime: Timestamp
    var ackID: String?
    var leaseExpires: Timestamp?
    var deliveries = 0
}

struct FakePullSubscription: Sendable {
    var topic: String
    var ackDeadline: Duration
    var messages: [FakePubSubMessage] = []
}

struct EventsState: Sendable {
    var subscriptions: [String: FakeEventSubscription] = [:]
    var operations: [String: FakeEventOperation] = [:]
    var pullSubscriptions: [String: FakePullSubscription] = [:]
    var pollsBeforeDone = 0
    var failNextOperationCodes: [Int] = []
    var counter = 0
}

extension State {
    private static let subscriptionType = "type.googleapis.com/google.apps.events.subscriptions.v1.Subscription"

    private mutating func nextEventID(_ prefix: String) -> String {
        events.counter += 1
        return "\(prefix)\(events.counter)-\(newID())"
    }

    private func wireEventSubscription(_ sub: FakeEventSubscription) -> JSON {
        var out: JSON = [
            "name": sub.name, "uid": "uid-" + sub.name.dropFirst("subscriptions/".count),
            "targetResource": sub.targetResource, "eventTypes": sub.eventTypes,
            "payloadOptions": ["includeResource": false], "notificationEndpoint": ["pubsubTopic": sub.topic],
            "state": sub.state, "authority": sub.authority.rawValue, "createTime": sub.createTime.rfc3339,
            "updateTime": sub.updateTime.rfc3339, "expireTime": sub.expireTime.rfc3339, "reconciling": false,
            "etag": "etag-\(sub.updateTime.seconds)",
        ]
        if let reason = sub.suspensionReason { out["suspensionReason"] = reason }
        return out
    }

    private func wireOperation(_ operation: FakeEventOperation) -> JSON {
        var out: JSON = ["name": operation.name]
        guard operation.remainingPolls <= 0 else { return out }
        out["done"] = true
        if let code = operation.failureCode {
            out["error"] = ["code": code, "message": "Scripted operation failure"]
        } else if let name = operation.subscription, let sub = events.subscriptions[name] {
            var response = wireEventSubscription(sub)
            response["@type"] = Self.subscriptionType
            out["response"] = response
        } else {
            out["response"] = ["@type": "type.googleapis.com/google.protobuf.Empty"]
        }
        return out
    }

    private mutating func newOperation(subscription: String?) -> Reply {
        let failure = events.failNextOperationCodes.isEmpty ? nil : events.failNextOperationCodes.removeFirst()
        let operation = FakeEventOperation(
            name: "operations/" + nextEventID("op"), remainingPolls: events.pollsBeforeDone, subscription: subscription,
            failureCode: failure)
        events.operations[operation.name] = operation
        return .json(wireOperation(operation))
    }

    private func visibleEventSubscription(_ name: String, _ account: FakeAccount) throws(WireError)
        -> FakeEventSubscription
    {
        guard let sub = events.subscriptions[name], sub.authority == account.user.name, sub.expireTime > now else {
            throw .notFound("Subscription not found.")
        }
        return sub
    }

    static func parseTTL(_ text: String) -> Duration? {
        guard text.hasSuffix("s"), let seconds = Int(text.dropLast()), seconds > 0 else { return nil }
        return .seconds(seconds)
    }

    mutating func createEventSubscription(_ incoming: IncomingRequest, _ account: FakeAccount) throws(WireError)
        -> Reply
    {
        guard let body = incoming.jsonBody, let target = body["targetResource"] as? String,
            let types = body["eventTypes"] as? [String], !types.isEmpty,
            let topic = (body["notificationEndpoint"] as? JSON)?["pubsubTopic"] as? String
        else { throw .invalidArgument("targetResource, eventTypes and notificationEndpoint.pubsubTopic are required") }
        let ttl = (body["ttl"] as? String).flatMap(Self.parseTTL) ?? .seconds(4 * 60 * 60)
        if let existing = events.subscriptions.values.first(where: {
            $0.authority == account.user.name && $0.targetResource == target && Set($0.eventTypes) == Set(types)
                && $0.topic == topic && $0.expireTime > now
        }) {
            throw WireError(
                status: 409, googleStatus: "ALREADY_EXISTS",
                message: "Subscription already exists: \(existing.name)")
        }
        let time = now
        let sub = FakeEventSubscription(
            name: "subscriptions/" + nextEventID("sub"), authority: account.user.name, targetResource: target,
            eventTypes: types, topic: topic, createTime: time, updateTime: time, expireTime: time.adding(ttl))
        events.subscriptions[sub.name] = sub
        return newOperation(subscription: sub.name)
    }

    func getEventSubscription(_ name: String, _ account: FakeAccount) throws(WireError) -> Reply {
        .json(wireEventSubscription(try visibleEventSubscription(name, account)))
    }

    func listEventSubscriptions(_ incoming: IncomingRequest, _ account: FakeAccount) throws(WireError) -> Reply {
        let filter = incoming.value("filter") ?? ""
        guard !filter.isEmpty else { throw .invalidArgument("filter is required") }
        func quoted(after marker: String) -> [String] {
            var values: [String] = []
            var rest = Substring(filter)
            while let range = rest.range(of: marker + "\"") {
                rest = rest[range.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { break }
                values.append(String(rest[..<end]))
                rest = rest[end...]
            }
            return values
        }
        let types = quoted(after: "event_types:")
        let target = quoted(after: "target_resource=").first
        guard !types.isEmpty else { throw .invalidArgument("filter needs event_types") }
        let matches = events.subscriptions.values
            .filter {
                $0.authority == account.user.name && $0.expireTime > now
                    && (target == nil || $0.targetResource == target)
                    && !Set($0.eventTypes).isDisjoint(with: types)
            }
            .sorted { $0.name < $1.name }
        return .json(["subscriptions": matches.map(wireEventSubscription)])
    }

    mutating func patchEventSubscription(_ name: String, _ incoming: IncomingRequest, _ account: FakeAccount)
        throws(WireError) -> Reply
    {
        var sub = try visibleEventSubscription(name, account)
        guard incoming.value("updateMask") == "ttl" else { throw .invalidArgument("updateMask must be ttl") }
        guard let ttl = (incoming.jsonBody?["ttl"] as? String).flatMap(Self.parseTTL) else {
            throw .invalidArgument("ttl is required")
        }
        sub.expireTime = now.adding(ttl)
        sub.updateTime = now
        events.subscriptions[name] = sub
        return newOperation(subscription: name)
    }

    mutating func reactivateEventSubscription(_ name: String, _ account: FakeAccount) throws(WireError) -> Reply {
        var sub = try visibleEventSubscription(name, account)
        guard sub.state == "SUSPENDED" else { throw .failedPrecondition("Subscription is not suspended.") }
        sub.state = "ACTIVE"
        sub.suspensionReason = nil
        sub.updateTime = now
        events.subscriptions[name] = sub
        return newOperation(subscription: name)
    }

    mutating func deleteEventSubscription(_ name: String, _ account: FakeAccount) throws(WireError) -> Reply {
        _ = try visibleEventSubscription(name, account)
        events.subscriptions[name] = nil
        return newOperation(subscription: nil)
    }

    mutating func getEventOperation(_ name: String) throws(WireError) -> Reply {
        guard var operation = events.operations[name] else { throw .notFound("Operation not found.") }
        operation.remainingPolls -= 1
        events.operations[name] = operation
        return .json(wireOperation(operation))
    }

    func getPullSubscription(_ path: String) throws(WireError) -> Reply {
        guard let sub = events.pullSubscriptions[path] else {
            throw .notFound("Resource not found (resource=\(path)).")
        }
        return .json([
            "name": path, "topic": sub.topic, "ackDeadlineSeconds": Int(sub.ackDeadline.components.seconds),
        ])
    }

    mutating func pull(_ path: String, _ incoming: IncomingRequest) throws(WireError) -> Reply {
        guard var sub = events.pullSubscriptions[path] else {
            throw .notFound("Resource not found (resource=\(path)).")
        }
        let limit = max(1, incoming.jsonBody?["maxMessages"] as? Int ?? 100)
        let current = now
        var received: [JSON] = []
        for index in sub.messages.indices where received.count < limit {
            if let lease = sub.messages[index].leaseExpires, lease > current { continue }
            let ackID = nextEventID("ack")
            sub.messages[index].ackID = ackID
            sub.messages[index].leaseExpires = current.adding(sub.ackDeadline)
            sub.messages[index].deliveries += 1
            let message = sub.messages[index]
            received.append([
                "ackId": ackID, "deliveryAttempt": message.deliveries,
                "message": [
                    "data": message.data.base64EncodedString(), "attributes": message.attributes,
                    "messageId": message.messageID, "publishTime": message.publishTime.rfc3339,
                ] as JSON,
            ])
        }
        events.pullSubscriptions[path] = sub
        return .json(received.isEmpty ? [:] : ["receivedMessages": received])
    }

    mutating func acknowledge(_ path: String, _ incoming: IncomingRequest) throws(WireError) -> Reply {
        guard var sub = events.pullSubscriptions[path] else {
            throw .notFound("Resource not found (resource=\(path)).")
        }
        guard let ids = incoming.jsonBody?["ackIds"] as? [String], !ids.isEmpty else {
            throw .invalidArgument("ackIds is required")
        }
        let acked = Set(ids)
        sub.messages.removeAll { $0.ackID.map(acked.contains) == true }
        events.pullSubscriptions[path] = sub
        return .json([:])
    }

    mutating func publish(
        topic: String, attributes: [String: String], data: Data
    ) {
        let time = now
        for path in events.pullSubscriptions.keys.sorted() where events.pullSubscriptions[path]?.topic == topic {
            let id = nextEventID("msg")
            events.pullSubscriptions[path]?.messages.append(
                FakePubSubMessage(messageID: id, attributes: attributes, data: data, publishTime: time))
        }
    }
}

extension WireError {
    static func failedPrecondition(_ message: String) -> WireError {
        WireError(status: 400, googleStatus: "FAILED_PRECONDITION", message: message)
    }
}

extension FakeChatServer {
    public struct EventSubscriptionInfo: Sendable, Equatable {
        public var name: String
        public var targetResource: String
        public var eventTypes: [String]
        public var pubsubTopic: String
        public var state: String
        public var expireTime: Timestamp
    }

    public enum Lifecycle: String, Sendable {
        case expirationReminder = "google.workspace.events.subscription.v1.expirationReminder"
        case suspended = "google.workspace.events.subscription.v1.suspended"
        case expired = "google.workspace.events.subscription.v1.expired"
    }

    // MARK: Pub/Sub

    /// Registers a pull subscription. Every message published to `topic` is queued on each one.
    public func addPullSubscription(_ path: String, topic: String, ackDeadline: Duration = .seconds(10)) {
        state.withLock {
            $0.events.pullSubscriptions[path] = FakePullSubscription(topic: topic, ackDeadline: ackDeadline)
        }
    }

    /// Messages queued on `path` that are not yet acknowledged, whether or not they are currently leased.
    public func unackedCount(_ path: String) -> Int {
        state.withLock { $0.events.pullSubscriptions[path]?.messages.count ?? 0 }
    }

    /// Publishes a binary-mode CloudEvent: `ce-*` attributes plus a JSON body.
    public func publishCloudEvent(
        topic: String, type: String, source: String, subject: String? = nil, time: Timestamp? = nil,
        data: [String: Any] = [:]
    ) {
        state.withLock { state in
            var attributes = [
                "ce-specversion": "1.0", "ce-type": type, "ce-source": source,
                "ce-id": "event-\(state.newID())", "ce-time": (time ?? state.now).rfc3339,
                "content-type": "application/json",
            ]
            if let subject { attributes["ce-subject"] = subject }
            let body = (try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])) ?? Data()
            state.publish(topic: topic, attributes: attributes, data: body)
        }
    }

    private static func source(_ subscription: String) -> String {
        "//workspaceevents.googleapis.com/" + subscription
    }

    /// `message.v1.created` for one message, or `message.v1.batchCreated` when `messages` has several.
    public func publishMessagesCreated(
        topic: String, subscription: String, space: SpaceName, messages: [MessageName], time: Timestamp? = nil
    ) {
        let single = messages.count == 1
        publishCloudEvent(
            topic: topic,
            type: "google.workspace.chat.message.v1.\(single ? "created" : "batchCreated")",
            source: Self.source(subscription), subject: "//chat.googleapis.com/\(space.rawValue)", time: time,
            data: single
                ? ["message": ["name": messages[0].rawValue]]
                : ["messages": messages.map { ["message": ["name": $0.rawValue]] }])
    }

    public func publishMembershipsCreated(
        topic: String, subscription: String, space: SpaceName, memberships: [MembershipName], time: Timestamp? = nil
    ) {
        let single = memberships.count == 1
        publishCloudEvent(
            topic: topic,
            type: "google.workspace.chat.membership.v1.\(single ? "created" : "batchCreated")",
            source: Self.source(subscription), subject: "//chat.googleapis.com/\(space.rawValue)", time: time,
            data: single
                ? ["membership": ["name": memberships[0].rawValue]]
                : ["memberships": memberships.map { ["membership": ["name": $0.rawValue]] }])
    }

    public func publishLifecycle(_ event: Lifecycle, topic: String, subscription: String) {
        let expire = state.withLock { $0.events.subscriptions[subscription]?.expireTime }
        var info: [String: Any] = ["name": subscription]
        if let expire { info["expireTime"] = expire.rfc3339 }
        publishCloudEvent(
            topic: topic, type: event.rawValue, source: Self.source(subscription),
            subject: "//workspaceevents.googleapis.com/" + subscription, data: ["subscription": info])
    }

    // MARK: Workspace Events

    /// Operations answer not-done for this many `operations.get` calls before completing.
    public var eventOperationPollsBeforeDone: Int {
        get { state.withLock { $0.events.pollsBeforeDone } }
        set { state.withLock { $0.events.pollsBeforeDone = newValue } }
    }

    /// The next operation created finishes with a google.rpc `code` instead of a response.
    public func failNextEventOperation(code: Int) {
        state.withLock { $0.events.failNextOperationCodes.append(code) }
    }

    public var eventSubscriptions: [EventSubscriptionInfo] {
        state.withLock { state in
            state.events.subscriptions.values.sorted { $0.name < $1.name }.map {
                EventSubscriptionInfo(
                    name: $0.name, targetResource: $0.targetResource, eventTypes: $0.eventTypes, pubsubTopic: $0.topic,
                    state: $0.state, expireTime: $0.expireTime)
            }
        }
    }

    public func suspendEventSubscription(_ name: String, reason: String = "USER_SCOPE_REVOKED") {
        state.withLock {
            $0.events.subscriptions[name]?.state = "SUSPENDED"
            $0.events.subscriptions[name]?.suspensionReason = reason
        }
    }

    public func removeEventSubscription(_ name: String) {
        state.withLock { $0.events.subscriptions[name] = nil }
    }
}
