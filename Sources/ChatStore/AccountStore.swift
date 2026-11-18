import ChatModel
import Foundation

public enum StoreError: Error, Sendable, Equatable {
    case gateClosed
    case sqlite(code: Int32)
    case crypto(StoreCryptoError)
    case schemaTooNew(Int)
    case io(code: Int)
}

/// A space plus local, per-account state.
public struct StoredSpace: Hashable, Sendable, Codable {
    public var space: Space
    public var lastReadTime: Timestamp?
    public var notificationSetting: SpaceNotificationSetting?
    /// Title built from members for DMs and unnamed group chats.
    public var memberTitle: String?
    public var memberTitleFetched: Timestamp?
    /// Set only after reconciliation confirms the membership loss.
    public var isHidden: Bool

    public init(
        space: Space, lastReadTime: Timestamp? = nil, notificationSetting: SpaceNotificationSetting? = nil,
        memberTitle: String? = nil, memberTitleFetched: Timestamp? = nil, isHidden: Bool = false
    ) {
        self.space = space
        self.lastReadTime = lastReadTime
        self.notificationSetting = notificationSetting
        self.memberTitle = memberTitle
        self.memberTitleFetched = memberTitleFetched
        self.isHidden = isHidden
    }
}

/// One batch of writes, applied atomically in a single transaction. Order of operations is preserved.
public struct StoreWrite: Sendable {
    public enum Operation: Sendable, Equatable {
        /// Replaces API fields of the space, keeping local fields; inserts if new.
        case mergeSpace(Space)
        case setSpaceHidden(SpaceName, Bool)
        case deleteSpace(SpaceName)
        /// Per message: replaces the stored copy only if `version` is not older; at equal version a tombstone wins.
        case upsertMessages([Message])
        /// A fresh authoritative window: cached messages of the space created before `coveredBefore` that aren't in
        /// `messages` are dropped; `messages` then replace rows of the same or an older version. Newer rows stay.
        case replaceMessages(SpaceName, [Message], coveredBefore: Timestamp)
        /// Reactions change without a new message version, so they're updated separately; no-op if not cached.
        case updateReactions(MessageName, [ReactionSummary])
        /// Monotonic: a value older than the stored checkpoint is ignored.
        case setCheckpoint(SpaceName, SyncStream, Timestamp)
        case setReadState(SpaceName, Timestamp?)
        case setThreadReadState(ThreadName, Timestamp?)
        case setNotificationSetting(SpaceName, SpaceNotificationSetting?)
        case setMembers(SpaceName, [Membership], title: String?, fetched: Timestamp)
        case putDraft(Draft)
        case deleteDraft(key: String)
        case putOutbox(OutboxItem)
        case deleteOutbox(UUID)
        case markNotified([MessageName], at: Timestamp)
        case setMeta(key: String, value: String?)
        /// Keeps the newest `keep` messages of a space by `createTime`.
        case pruneMessages(SpaceName, keep: Int)
    }

    public private(set) var operations: [Operation] = []

    public init() {}

    public mutating func append(_ operation: Operation) { operations.append(operation) }
    public var isEmpty: Bool { operations.isEmpty }
}

/// The per-account cache. Reads are synchronous and safe from any thread. Writes go through `write`, which applies
/// the batch inside `gate.commit`, so a retired generation can never commit.
public protocol AccountStore: AnyObject, Sendable {
    func spaces() throws(StoreError) -> [StoredSpace]
    func space(_ name: SpaceName) throws(StoreError) -> StoredSpace?
    /// Ascending by `createTime`, the newest `limit` messages strictly before `before` (or overall). Includes
    /// tombstones and thread replies.
    func messages(in space: SpaceName, before: Timestamp?, limit: Int) throws(StoreError) -> [Message]
    func messages(inThread thread: ThreadName, limit: Int) throws(StoreError) -> [Message]
    func message(_ name: MessageName) throws(StoreError) -> Message?
    func checkpoint(_ space: SpaceName, _ stream: SyncStream) throws(StoreError) -> Timestamp?
    func threadReadState(_ thread: ThreadName) throws(StoreError) -> Timestamp?
    func members(in space: SpaceName) throws(StoreError) -> [Membership]
    func drafts() throws(StoreError) -> [Draft]
    func outbox() throws(StoreError) -> [OutboxItem]
    func isNotified(_ message: MessageName) throws(StoreError) -> Bool
    func meta(_ key: String) throws(StoreError) -> String?

    func write(_ batch: StoreWrite, gate: SessionGate, generation: Generation) throws(StoreError)
}

extension AccountStore {
    public func write(
        gate: SessionGate, generation: Generation, _ build: (inout StoreWrite) -> Void
    ) throws(StoreError) {
        var batch = StoreWrite()
        build(&batch)
        guard !batch.isEmpty else { return }
        try write(batch, gate: gate, generation: generation)
    }
}
