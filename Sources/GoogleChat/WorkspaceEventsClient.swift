import ChatModel
import ChatNet
import Foundation

/// `subscriptions/{id}`, a Workspace Events subscription.
public struct EventSubscriptionName: ResourceName {
    public static let pattern = ["subscriptions"]
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

public struct EventSubscription: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case active, suspended, deleted
        case unknown(String)

        init(_ raw: String?) {
            switch raw {
            case "ACTIVE": self = .active
            case "SUSPENDED": self = .suspended
            case "DELETED": self = .deleted
            default: self = .unknown(raw ?? "")
            }
        }
    }

    public static let chatTarget = "//chat.googleapis.com/spaces/-"
    public static let requiredEventTypes = [
        "google.workspace.chat.message.v1.created", "google.workspace.chat.membership.v1.created",
    ]
    public static let ttl: Duration = .seconds(7 * 24 * 60 * 60)

    public var name: EventSubscriptionName
    public var targetResource: String
    public var eventTypes: [String]
    public var pubsubTopic: String?
    public var state: State
    public var suspensionReason: String?
    public var expireTime: Timestamp?
    /// The user the subscription acts for, `users/{id}`.
    public var authority: String?

    public init(
        name: EventSubscriptionName, targetResource: String, eventTypes: [String], pubsubTopic: String?,
        state: State, suspensionReason: String? = nil, expireTime: Timestamp? = nil, authority: String? = nil
    ) {
        self.name = name
        self.targetResource = targetResource
        self.eventTypes = eventTypes
        self.pubsubTopic = pubsubTopic
        self.state = state
        self.suspensionReason = suspensionReason
        self.expireTime = expireTime
        self.authority = authority
    }
}

/// What `subscriptions.list` is asked for: subscriptions that carry any of `eventTypes`, optionally on `targetResource`.
public struct EventSubscriptionFilter: Sendable, Equatable {
    public var eventTypes: [String]
    public var targetResource: String?

    public init(eventTypes: [String], targetResource: String? = nil) {
        self.eventTypes = eventTypes
        self.targetResource = targetResource
    }

    public static let chat = EventSubscriptionFilter(
        eventTypes: EventSubscription.requiredEventTypes, targetResource: EventSubscription.chatTarget)

    /// `(event_types:"a" OR event_types:"b") AND target_resource="..."`.
    public var query: String {
        var clauses = ["(" + eventTypes.map { "event_types:\"\($0)\"" }.joined(separator: " OR ") + ")"]
        if let targetResource { clauses.append("target_resource=\"\(targetResource)\"") }
        return clauses.joined(separator: " AND ")
    }
}

public protocol WorkspaceEventsAPI: Sendable {
    /// Creates the shared Chat subscription that publishes to `topic`. Throws a conflict for which
    /// `isAlreadyExists` is true when an equivalent subscription exists.
    func createSubscription(topic: PubSubTopicPath) async throws(ChatAPIError) -> EventSubscription
    func getSubscription(_ name: EventSubscriptionName) async throws(ChatAPIError) -> EventSubscription
    func listSubscriptions(filter: EventSubscriptionFilter) async throws(ChatAPIError) -> [EventSubscription]
    /// Extends the subscription's TTL to 7 days from now.
    func renewSubscription(_ name: EventSubscriptionName) async throws(ChatAPIError) -> EventSubscription
    func reactivateSubscription(_ name: EventSubscriptionName) async throws(ChatAPIError) -> EventSubscription
    func deleteSubscription(_ name: EventSubscriptionName) async throws(ChatAPIError)
}

/// Both Workspace Events and Pub/Sub REST calls, through the same transport and token provider.
public struct WorkspaceEventsClient: Sendable {
    public typealias Sleeper = @Sendable (Duration) async -> Void

    public static let eventsProductionBaseURL = URL(string: "https://workspaceevents.googleapis.com")!
    public static let pubsubProductionBaseURL = URL(string: "https://pubsub.googleapis.com")!
    public static let pullTimeout: Duration = .seconds(90)

    let core: GoogleChatClient
    let pubsubBaseURL: URL
    let maxOperationPolls: Int
    let pollDelay: Duration
    let sleeper: Sleeper

    public init(
        transport: any HTTPTransport, tokens: any TokenProvider,
        eventsBaseURL: URL = eventsProductionBaseURL, pubsubBaseURL: URL = pubsubProductionBaseURL,
        maxOperationPolls: Int = 5, pollDelay: Duration = .milliseconds(500),
        sleeper: @escaping Sleeper = { try? await Task.sleep(for: $0) }
    ) {
        core = GoogleChatClient(transport: transport, tokens: tokens, baseURL: eventsBaseURL)
        self.pubsubBaseURL = pubsubBaseURL
        self.maxOperationPolls = maxOperationPolls
        self.pollDelay = pollDelay
        self.sleeper = sleeper
    }
}

struct WireEventSubscription: Decodable {
    struct Endpoint: Decodable { var pubsubTopic: String? }

    var name: EventSubscriptionName
    var targetResource: String?
    var eventTypes: [String]?
    var notificationEndpoint: Endpoint?
    var state: String?
    var suspensionReason: String?
    var expireTime: Timestamp?
    var authority: String?

    var model: EventSubscription {
        EventSubscription(
            name: name, targetResource: targetResource ?? "", eventTypes: eventTypes ?? [],
            pubsubTopic: notificationEndpoint?.pubsubTopic, state: .init(state), suspensionReason: suspensionReason,
            expireTime: expireTime, authority: authority)
    }
}

private struct WireOperation<Response: Decodable>: Decodable {
    struct Failure: Decodable { var code: Int? }

    var name: String?
    var done: Bool?
    var response: Response?
    var error: Failure?
}

private struct CreateSubscriptionBody: Encodable {
    struct Payload: Encodable { var includeResource = false }
    struct Endpoint: Encodable { var pubsubTopic: String }

    var targetResource = EventSubscription.chatTarget
    var eventTypes = EventSubscription.requiredEventTypes
    var payloadOptions = Payload()
    var notificationEndpoint: Endpoint
    var ttl = WorkspaceEventsClient.ttlString
}

private struct RenewBody: Encodable {
    var ttl = WorkspaceEventsClient.ttlString
}

private struct WireSubscriptionList: Decodable {
    var subscriptions: [WireEventSubscription]?
    var nextPageToken: String?
}

extension WorkspaceEventsClient {
    static let ttlString = "\(EventSubscription.ttl.components.seconds)s"
    static let maxListPages = 10

    static func isValidOperationName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count), parts.count.isMultiple(of: 2), parts[parts.count - 2] == "operations"
        else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.utf8.count <= 256 && part != "." && part != ".."
                && part.utf8.allSatisfy {
                    ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z"))
                        || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z"))
                        || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                        || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
                        || $0 == UInt8(ascii: "~") || $0 == UInt8(ascii: "=")
                }
        }
    }

    private static func operationFailure(code: Int?) -> ChatAPIError {
        let (http, status) =
            switch code {
            case 3: (400, "INVALID_ARGUMENT")
            case 5: (404, "NOT_FOUND")
            case 6: (409, "ALREADY_EXISTS")
            case 7: (403, "PERMISSION_DENIED")
            case 8: (429, "RESOURCE_EXHAUSTED")
            case 9: (400, "FAILED_PRECONDITION")
            case 14: (503, "UNAVAILABLE")
            default: (500, "UNKNOWN")
            }
        return ChatAPIError(status: http, headers: [:], body: Data(#"{"error":{"status":"\#(status)"}}"#.utf8))
    }

    /// Polls `operations.get` up to `maxOperationPolls` times. A `done` operation without a `response` yields nil.
    private func complete<Response: Decodable & Sendable>(
        _ first: WireOperation<Response>
    ) async throws(ChatAPIError) -> Response? {
        var operation = first
        var polls = 0
        while true {
            if operation.done == true {
                if let failure = operation.error { throw Self.operationFailure(code: failure.code) }
                return operation.response
            }
            guard polls < maxOperationPolls, let name = operation.name, Self.isValidOperationName(name) else {
                throw .server(GoogleErrorInfo(httpStatus: 0, status: ChatAPIError.operationPendingStatus))
            }
            polls += 1
            await sleeper(pollDelay)
            if Task.isCancelled { throw .transport(.cancelled) }
            operation = try await core.send(.get, core.url("/v1/" + name))
        }
    }

    private func subscription(from operation: WireOperation<WireEventSubscription>) async throws(ChatAPIError)
        -> EventSubscription
    {
        guard let wire = try await complete(operation) else { throw .decoding(path: "response") }
        return wire.model
    }
}

extension WorkspaceEventsClient: WorkspaceEventsAPI {
    public func createSubscription(topic: PubSubTopicPath) async throws(ChatAPIError) -> EventSubscription {
        let body = CreateSubscriptionBody(notificationEndpoint: .init(pubsubTopic: topic.rawValue))
        let operation: WireOperation<WireEventSubscription> = try await core.send(
            .post, core.url("/v1/subscriptions"), body: body)
        return try await subscription(from: operation)
    }

    public func getSubscription(_ name: EventSubscriptionName) async throws(ChatAPIError) -> EventSubscription {
        let wire: WireEventSubscription = try await core.send(.get, core.url("/v1/" + name.rawValue))
        return wire.model
    }

    public func listSubscriptions(
        filter: EventSubscriptionFilter
    ) async throws(ChatAPIError) -> [EventSubscription] {
        var result: [EventSubscription] = []
        var pageToken: String?
        for _ in 0..<Self.maxListPages {
            var query = [
                URLQueryItem(name: "filter", value: filter.query), URLQueryItem(name: "pageSize", value: "100"),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: WireSubscriptionList = try await core.send(.get, core.url("/v1/subscriptions", query: query))
            result += (page.subscriptions ?? []).map(\.model)
            guard let next = page.nextPageToken, !next.isEmpty else { return result }
            pageToken = next
        }
        return result
    }

    public func renewSubscription(_ name: EventSubscriptionName) async throws(ChatAPIError) -> EventSubscription {
        let url = core.url("/v1/" + name.rawValue, query: [URLQueryItem(name: "updateMask", value: "ttl")])
        let operation: WireOperation<WireEventSubscription> = try await core.send(.patch, url, body: RenewBody())
        return try await subscription(from: operation)
    }

    public func reactivateSubscription(_ name: EventSubscriptionName) async throws(ChatAPIError) -> EventSubscription {
        let operation: WireOperation<WireEventSubscription> = try await core.send(
            .post, core.url("/v1/" + name.rawValue + ":reactivate"), body: Empty())
        return try await subscription(from: operation)
    }

    public func deleteSubscription(_ name: EventSubscriptionName) async throws(ChatAPIError) {
        let operation: WireOperation<Empty> = try await core.send(.delete, core.url("/v1/" + name.rawValue))
        _ = try await complete(operation)
    }
}
