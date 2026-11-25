import ChatModel
import Foundation

public enum ChatEvent: Sendable, Equatable {
    /// `messages` may be empty when the payload named none; the space and time still say where to look.
    case messagesCreated(space: SpaceName, messages: [MessageName], time: Timestamp)
    case membershipCreated(space: SpaceName, time: Timestamp)
    case expirationReminder(subscription: EventSubscriptionName, expireTime: Timestamp?)
    case suspended(subscription: EventSubscriptionName)
    case expired(subscription: EventSubscriptionName)
    case unknown(type: String?)
}

/// One Pub/Sub message carrying a CloudEvent in binary content mode: the `ce-*` attributes plus a JSON body.
public struct ReceivedEvent: Sendable, Equatable {
    public static let sourcePrefix = "//workspaceevents.googleapis.com/"

    public var ackID: String
    public var messageID: String?
    public var publishTime: Timestamp?
    public var attributes: [String: String]
    public var data: Data

    public init(
        ackID: String, messageID: String? = nil, publishTime: Timestamp? = nil, attributes: [String: String],
        data: Data
    ) {
        self.ackID = ackID
        self.messageID = messageID
        self.publishTime = publishTime
        self.attributes = attributes
        self.data = data
    }

    public var type: String? { attributes["ce-type"] }
    public var source: String? { attributes["ce-source"] }
    public var subject: String? { attributes["ce-subject"] }
    public var id: String? { attributes["ce-id"] }
    public var time: Timestamp? { attributes["ce-time"].flatMap { Timestamp(rfc3339: $0) } ?? publishTime }

    /// `ce-source` without its `//workspaceevents.googleapis.com/` prefix, as `subscriptions/{id}`.
    public var subscription: EventSubscriptionName? { Self.subscriptionName(fromSource: source) }

    public static func subscriptionName(fromSource source: String?) -> EventSubscriptionName? {
        guard var source else { return nil }
        if source.hasPrefix(sourcePrefix) { source.removeFirst(sourcePrefix.count) }
        return EventSubscriptionName(source)
    }

    /// The subject's space, from `//chat.googleapis.com/spaces/{id}[/...]`.
    public var subjectSpace: SpaceName? {
        let prefix = "//chat.googleapis.com/"
        guard let subject, subject.hasPrefix(prefix) else { return nil }
        let parts = subject.dropFirst(prefix.count).split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return SpaceName("\(parts[0])/\(parts[1])")
    }

    /// Usually one event. A batch whose resources span several spaces yields one per space, so none is dropped.
    public var chatEvents: [ChatEvent] {
        let payload = try? JSONDecoder().decode(CloudEventPayload.self, from: data.isEmpty ? Data("{}".utf8) : data)
        switch type {
        case "google.workspace.chat.message.v1.created", "google.workspace.chat.message.v1.batchCreated":
            guard let time else { return [.unknown(type: type)] }
            let names = payload?.names(.message) ?? []
            var groups: [(space: SpaceName, messages: [MessageName])] = []
            var sawInvalid = false
            for raw in names {
                guard let message = MessageName(raw) else {
                    sawInvalid = true
                    continue
                }
                if let index = groups.firstIndex(where: { $0.space == message.space }) {
                    groups[index].messages.append(message)
                } else {
                    groups.append((message.space, [message]))
                }
            }
            if let space = subjectSpace, groups.isEmpty || sawInvalid, !groups.contains(where: { $0.space == space }) {
                groups.append((space, []))
            }
            guard !groups.isEmpty else { return [.unknown(type: type)] }
            return groups.map { .messagesCreated(space: $0.space, messages: $0.messages, time: time) }
        case "google.workspace.chat.membership.v1.created", "google.workspace.chat.membership.v1.batchCreated":
            guard let time else { return [.unknown(type: type)] }
            var spaces: [SpaceName] = []
            for raw in payload?.names(.membership) ?? [] {
                if let space = MembershipName(raw).map({ SpaceName(unchecked: "spaces/\($0.id(at: 0))") }),
                    !spaces.contains(space)
                {
                    spaces.append(space)
                }
            }
            if let space = subjectSpace, spaces.isEmpty || !spaces.contains(space) { spaces.append(space) }
            guard !spaces.isEmpty else { return [.unknown(type: type)] }
            return spaces.map { .membershipCreated(space: $0, time: time) }
        case "google.workspace.events.subscription.v1.expirationReminder":
            guard let name = lifecycleSubscription(payload) else { return [.unknown(type: type)] }
            return [
                .expirationReminder(
                    subscription: name, expireTime: payload?.subscription?.expireTime.flatMap { Timestamp(rfc3339: $0) }
                )
            ]
        case "google.workspace.events.subscription.v1.suspended":
            return lifecycleSubscription(payload).map { [.suspended(subscription: $0)] } ?? [.unknown(type: type)]
        case "google.workspace.events.subscription.v1.expired":
            return lifecycleSubscription(payload).map { [.expired(subscription: $0)] } ?? [.unknown(type: type)]
        default:
            return [.unknown(type: type)]
        }
    }

    private func lifecycleSubscription(_ payload: CloudEventPayload?) -> EventSubscriptionName? {
        payload?.subscription?.name.flatMap { EventSubscriptionName($0) } ?? subscription
    }
}

struct CloudEventPayload: Decodable {
    struct Named: Decodable { var name: String? }
    struct Item: Decodable {
        var name: String?
        var message: Named?
        var membership: Named?
    }
    struct SubscriptionInfo: Decodable {
        var name: String?
        var expireTime: String?
    }
    enum Kind { case message, membership }

    var message: Named?
    var messages: [Item]?
    var membership: Named?
    var memberships: [Item]?
    var subscription: SubscriptionInfo?

    func names(_ kind: Kind) -> [String] {
        switch kind {
        case .message:
            (message?.name.map { [$0] } ?? []) + (messages ?? []).compactMap { $0.message?.name ?? $0.name }
        case .membership:
            (membership?.name.map { [$0] } ?? []) + (memberships ?? []).compactMap { $0.membership?.name ?? $0.name }
        }
    }
}
