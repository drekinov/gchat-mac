import ChatModel
import ChatNet
import Foundation

private func isValidProjectID(_ id: Substring) -> Bool {
    let bytes = Array(id.utf8)
    guard (6...30).contains(bytes.count), (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(bytes[0]) else {
        return false
    }
    let last = bytes[bytes.count - 1]
    guard
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(last) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(last)
    else { return false }
    return bytes.allSatisfy {
        ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
            || $0 == UInt8(ascii: "-")
    }
}

/// `[A-Za-z][\w.~+%-]{2,254}`
private func isValidPubSubID(_ id: Substring) -> Bool {
    let bytes = Array(id.utf8)
    guard (3...255).contains(bytes.count),
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(bytes[0] | 0x20)
    else { return false }
    return bytes.dropFirst().allSatisfy {
        ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z"))
            || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || $0 == UInt8(ascii: "_")
            || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "~") || $0 == UInt8(ascii: "+")
            || $0 == UInt8(ascii: "%") || $0 == UInt8(ascii: "-")
    }
}

private func isValidPubSubPath(_ raw: String, collection: String) -> Bool {
    let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 4 && parts[0] == "projects" && isValidProjectID(parts[1]) && parts[2] == collection
        && isValidPubSubID(parts[3])
}

/// `projects/{project}/subscriptions/{id}`, checked before it goes into a URL path.
public struct PubSubSubscriptionPath: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard isValidPubSubPath(rawValue, collection: "subscriptions") else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid subscription path"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// `projects/{project}/topics/{id}`, checked before it goes into a URL path or a request body.
public struct PubSubTopicPath: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard isValidPubSubPath(rawValue, collection: "topics") else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid topic path"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PubSubSubscription: Sendable, Equatable {
    public var name: PubSubSubscriptionPath
    /// Throws `.decoding` when the topic was deleted (`_deleted-topic_`).
    public var topic: PubSubTopicPath
    public var ackDeadlineSeconds: Int?

    public init(name: PubSubSubscriptionPath, topic: PubSubTopicPath, ackDeadlineSeconds: Int? = nil) {
        self.name = name
        self.topic = topic
        self.ackDeadlineSeconds = ackDeadlineSeconds
    }
}

public protocol PubSubAPI: Sendable {
    func getSubscription(_ path: PubSubSubscriptionPath) async throws(ChatAPIError) -> PubSubSubscription
    /// Holds up to the request timeout (90 s) when nothing is queued, then returns `[]`.
    func pull(_ path: PubSubSubscriptionPath, maxMessages: Int) async throws(ChatAPIError) -> [ReceivedEvent]
    func acknowledge(_ path: PubSubSubscriptionPath, ackIDs: [String]) async throws(ChatAPIError)
}

extension PubSubAPI {
    public func pull(_ path: PubSubSubscriptionPath) async throws(ChatAPIError) -> [ReceivedEvent] {
        try await pull(path, maxMessages: 50)
    }
}

private struct WirePubSubSubscription: Decodable {
    var name: PubSubSubscriptionPath
    var topic: PubSubTopicPath
    var ackDeadlineSeconds: Int?
}

private struct WirePull: Decodable {
    struct Received: Decodable {
        struct Message: Decodable {
            var data: String?
            var attributes: [String: String]?
            var messageId: String?
            var publishTime: String?
        }
        var ackId: String
        var message: Message?
    }
    var receivedMessages: [Received]?
}

private struct PullBody: Encodable {
    var maxMessages: Int
    var returnImmediately = false
}

private struct AcknowledgeBody: Encodable {
    var ackIds: [String]
}

extension WorkspaceEventsClient: PubSubAPI {
    static let maxAckIDsPerRequest = 500

    public func getSubscription(_ path: PubSubSubscriptionPath) async throws(ChatAPIError) -> PubSubSubscription {
        let wire: WirePubSubSubscription = try await core.send(
            .get, core.url("/v1/" + path.rawValue, base: pubsubBaseURL))
        return PubSubSubscription(name: wire.name, topic: wire.topic, ackDeadlineSeconds: wire.ackDeadlineSeconds)
    }

    public func pull(
        _ path: PubSubSubscriptionPath, maxMessages: Int
    ) async throws(ChatAPIError) -> [ReceivedEvent] {
        let url = core.url("/v1/" + path.rawValue + ":pull", base: pubsubBaseURL)
        let wire: WirePull = try await core.send(
            .post, url, body: PullBody(maxMessages: min(max(maxMessages, 1), 1000)), timeout: Self.pullTimeout)
        var events: [ReceivedEvent] = []
        for received in wire.receivedMessages ?? [] {
            let message = received.message
            var data = Data()
            if let encoded = message?.data, !encoded.isEmpty {
                guard let decoded = Data(base64Encoded: encoded) else {
                    throw .decoding(path: "receivedMessages.message.data")
                }
                data = decoded
            }
            events.append(
                ReceivedEvent(
                    ackID: received.ackId, messageID: message?.messageId,
                    publishTime: message?.publishTime.flatMap { Timestamp(rfc3339: $0) },
                    attributes: message?.attributes ?? [:], data: data))
        }
        return events
    }

    public func acknowledge(_ path: PubSubSubscriptionPath, ackIDs: [String]) async throws(ChatAPIError) {
        let url = core.url("/v1/" + path.rawValue + ":acknowledge", base: pubsubBaseURL)
        var index = 0
        while index < ackIDs.count {
            let end = min(index + Self.maxAckIDsPerRequest, ackIDs.count)
            let _: Empty = try await core.send(.post, url, body: AcknowledgeBody(ackIds: Array(ackIDs[index..<end])))
            index = end
        }
    }
}
