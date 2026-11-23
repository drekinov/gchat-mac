import ChatModel
import ChatStore
import Foundation
import GoogleChat

public enum AccountStatus: Sendable, Equatable {
    case starting
    case ok
    case syncing
    case offline
    /// Retrying after rate limits or server errors.
    case backingOff(until: Timestamp)
    case needsLogin
    /// Keychain or store unavailable; holds a content-free error class.
    case failed(String)
    case closing
}

public struct SpaceSummary: Hashable, Sendable, Identifiable {
    public var name: SpaceName
    public var type: SpaceType
    public var title: String
    public var lastActiveTime: Timestamp?
    public var unreadCount: Int
    public var isMuted: Bool
    public var lastMessagePreview: String?
    public var isThreaded: Bool = true
    public var isBotDM: Bool = false
    public var historyOn: Bool? = nil
    /// When the member cache was last filled; the open conversation rereads its members when this changes.
    public var membersFetched: Timestamp? = nil

    public var id: SpaceName { name }
    public var hasUnread: Bool { unreadCount > 0 }
}

/// Immutable per-account state for the UI. Consumers drop snapshots whose generation is retired.
public struct AccountSnapshot: Sendable {
    public var account: AccountID
    public var generation: Generation
    public var status: AccountStatus
    public var spaces: [SpaceSummary]
    /// Bumped on every commit; the open space re-reads the store when it changes.
    public var revision: UInt64
    public var changedSpaces: Set<SpaceName>

    public init(
        account: AccountID, generation: Generation, status: AccountStatus, spaces: [SpaceSummary] = [],
        revision: UInt64 = 0, changedSpaces: Set<SpaceName> = []
    ) {
        self.account = account
        self.generation = generation
        self.status = status
        self.spaces = spaces
        self.revision = revision
        self.changedSpaces = changedSpaces
    }
}

/// A conversation's unread messages, oldest first, by the same rule as its unread count.
public struct UnreadMessages: Sendable {
    public var messages: [Message]
    /// The first message of each thread an unread reply belongs to, when it's among the recent messages.
    public var roots: [ThreadName: Message]

    public init(messages: [Message] = [], roots: [ThreadName: Message] = [:]) {
        self.messages = messages
        self.roots = roots
    }
}

enum Unread {
    /// Top-level messages from others after the space read time, and replies from others after their thread's read
    /// time; muted spaces count as read.
    static func messages(
        messages: [Message], lastReadTime: Timestamp?, me: UserName, muted: Bool,
        threadReadTimes: [ThreadName: Timestamp] = [:]
    ) -> [Message] {
        guard !muted else { return [] }
        return messages.filter { message in
            guard !message.isDeleted, message.sender.name != me else { return false }
            if message.isThreadReply {
                guard let thread = message.thread, let threadRead = threadReadTimes[thread] else { return false }
                return message.createTime > threadRead
            }
            guard let lastReadTime else { return true }
            return message.createTime > lastReadTime
        }
    }

    static func count(
        messages: [Message], lastReadTime: Timestamp?, me: UserName, muted: Bool,
        threadReadTimes: [ThreadName: Timestamp] = [:]
    ) -> Int {
        Self.messages(
            messages: messages, lastReadTime: lastReadTime, me: me, muted: muted, threadReadTimes: threadReadTimes
        ).count
    }
}
