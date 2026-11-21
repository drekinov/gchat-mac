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

enum Unread {
    /// Top-level messages from others after the space read time; muted spaces count as read.
    static func count(
        messages: [Message], lastReadTime: Timestamp?, me: UserName, muted: Bool,
        threadReadTimes: [ThreadName: Timestamp] = [:]
    ) -> Int {
        guard !muted else { return 0 }
        return messages.reduce(0) { count, message in
            guard !message.isDeleted, message.sender.name != me else { return count }
            if message.isThreadReply {
                guard let thread = message.thread, let threadRead = threadReadTimes[thread] else { return count }
                return message.createTime > threadRead ? count + 1 : count
            }
            guard let lastReadTime else { return count + 1 }
            return message.createTime > lastReadTime ? count + 1 : count
        }
    }
}
