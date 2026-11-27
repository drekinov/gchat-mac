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
    /// When the space had history off; messages it says Google has deleted must not be shown, wherever they came from.
    public var retention: HistoryRetention? = nil
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
    /// Spaces whose unread replies may still grow, because some of their threads' read times are due a check.
    public var discoveringSpaces: Set<SpaceName>
    /// Bumped when the session itself writes a draft, so composers and the sidebar re-read theirs.
    public var draftRevision: UInt64

    public init(
        account: AccountID, generation: Generation, status: AccountStatus, spaces: [SpaceSummary] = [],
        revision: UInt64 = 0, changedSpaces: Set<SpaceName> = [], discoveringSpaces: Set<SpaceName> = [],
        draftRevision: UInt64 = 0
    ) {
        self.account = account
        self.generation = generation
        self.status = status
        self.spaces = spaces
        self.revision = revision
        self.changedSpaces = changedSpaces
        self.discoveringSpaces = discoveringSpaces
        self.draftRevision = draftRevision
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
        return messages.filter { isUnread($0, lastReadTime: lastReadTime, me: me, threadReadTimes: threadReadTimes) }
    }

    /// The badge's count: the same rule, without building a list on the sync path.
    static func count(
        messages: [Message], lastReadTime: Timestamp?, me: UserName, muted: Bool,
        threadReadTimes: [ThreadName: Timestamp] = [:]
    ) -> Int {
        guard !muted else { return 0 }
        return messages.reduce(into: 0) { count, message in
            if isUnread(message, lastReadTime: lastReadTime, me: me, threadReadTimes: threadReadTimes) { count += 1 }
        }
    }

    static func isUnread(
        _ message: Message, lastReadTime: Timestamp?, me: UserName, threadReadTimes: [ThreadName: Timestamp]
    ) -> Bool {
        guard !message.isDeleted, message.sender.name != me else { return false }
        if message.isThreadReply {
            guard let thread = message.thread, let threadRead = threadReadTimes[thread] else { return false }
            return message.createTime > threadRead
        }
        guard let lastReadTime else { return true }
        return message.createTime > lastReadTime
    }
}
