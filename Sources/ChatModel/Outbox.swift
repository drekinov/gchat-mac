import Foundation

public struct Draft: Hashable, Sendable, Codable {
    public var space: SpaceName
    /// `nil` for the space's composer; a thread for a reply composer.
    public var thread: ThreadName?
    public var text: String
    public var updated: Timestamp

    public init(space: SpaceName, thread: ThreadName?, text: String, updated: Timestamp) {
        self.space = space
        self.thread = thread
        self.text = text
        self.updated = updated
    }

    /// Stable row key: one draft per composer.
    public var key: String { thread?.rawValue ?? space.rawValue }
}

/// A file the user attached. `bookmark` is a security-scoped bookmark (sealed with the outbox row); the upload token
/// is saved as soon as the upload succeeds, so a retry doesn't upload again.
public struct PendingAttachment: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var bookmark: Data
    public var filename: String
    public var contentType: String
    public var byteCount: Int
    public var uploadToken: String?

    public init(
        id: UUID = UUID(), bookmark: Data, filename: String, contentType: String, byteCount: Int,
        uploadToken: String? = nil
    ) {
        self.id = id
        self.bookmark = bookmark
        self.filename = filename
        self.contentType = contentType
        self.byteCount = byteCount
        self.uploadToken = uploadToken
    }
}

public struct OutboxPayload: Hashable, Sendable, Codable {
    public var text: String
    public var thread: ThreadName?
    public var attachmentUploadTokens: [String]
    public var attachments: [PendingAttachment]

    public init(
        text: String, thread: ThreadName?, attachmentUploadTokens: [String] = [], attachments: [PendingAttachment] = []
    ) {
        self.text = text
        self.thread = thread
        self.attachmentUploadTokens = attachmentUploadTokens
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey { case text, thread, attachmentUploadTokens, attachments }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        thread = try container.decodeIfPresent(ThreadName.self, forKey: .thread)
        attachmentUploadTokens = try container.decodeIfPresent([String].self, forKey: .attachmentUploadTokens) ?? []
        attachments = try container.decodeIfPresent([PendingAttachment].self, forKey: .attachments) ?? []
    }

    /// Every upload token, once all attachments are uploaded; `nil` while any upload is outstanding.
    public var allUploadTokens: [String]? {
        let uploaded = attachments.compactMap(\.uploadToken)
        guard uploaded.count == attachments.count else { return nil }
        return attachmentUploadTokens + uploaded
    }
}

public enum OutboxState: Hashable, Sendable, Codable {
    case queued
    case sending
    case committed(MessageName)
    /// The request may have been applied; resolved by retrying with the same request ID.
    case unknown
    case failed(reason: String)

    /// Still needs a send attempt or, once committed, a metadata fetch.
    public var needsWork: Bool {
        if case .committed = self { return true }
        return !isTerminal
    }

    public var isTerminal: Bool {
        switch self {
        case .committed, .failed: true
        case .queued, .sending, .unknown: false
        }
    }
}

/// A durable send. `requestID` is fixed at creation and reused for every attempt by the same account.
public struct OutboxItem: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let requestID: UUID
    public let space: SpaceName
    public var payload: OutboxPayload
    public var state: OutboxState
    public var attempts: Int
    public let created: Timestamp
    public var nextAttempt: Timestamp?

    public var needsWork: Bool { state.needsWork }

    public init(
        id: UUID = UUID(), requestID: UUID = UUID(), space: SpaceName, payload: OutboxPayload,
        state: OutboxState = .queued, attempts: Int = 0, created: Timestamp, nextAttempt: Timestamp? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.space = space
        self.payload = payload
        self.state = state
        self.attempts = attempts
        self.created = created
        self.nextAttempt = nextAttempt
    }
}

/// Independent per-space sync streams, each with its own durable checkpoint.
public enum SyncStream: String, Sendable, Codable, CaseIterable {
    case messages
    case events
    case readState
}
