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
        /// Per message, by `Message.merge`: a copy that isn't older replaces the stored one, and deletes are terminal.
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
        /// Writes `draft` only if its composer has no draft, or only an empty one.
        case putDraftIfAbsent(Draft)
        case deleteDraft(key: String)
        case putOutbox(OutboxItem)
        case deleteOutbox(UUID)
        case markNotified([MessageName], at: Timestamp)
        case setMeta(key: String, value: String?)
        /// Keeps the newest `keep` messages of a space by `createTime`.
        case pruneMessages(SpaceName, keep: Int)
        /// Raises the owed boundary, adds the IDs (up to `OwedRecord.maxMessages`), resets attempts and takes a new
        /// revision. IDs that don't fit are reported in `StoreWriteResult.rejectedOwed`.
        case mergeOwed(SpaceName, boundary: Timestamp, messages: [MessageName])
        /// Drops IDs now stored or in `fetched` (deleted on the server). Deletes the row only if its revision is
        /// still `revision`, `coveredUpTo` is strictly past the boundary, and no ID is left.
        case resolveOwed(SpaceName, revision: UInt64, coveredUpTo: Timestamp?, fetched: [MessageName])
        /// A failed attempt at `revision`: backs off, or drops a row without IDs after `OwedRecord.maxAttempts`.
        case deferOwed(SpaceName, revision: UInt64, at: Timestamp)
        /// A complete listing omitted the space; a row without IDs goes after `OwedRecord.maxOmissions`.
        /// Like `clearOwed`, it skips a row whose revision is no longer the one the listing started with.
        case owedOmitted(SpaceName, revision: UInt64)
        case clearOwed(SpaceName, revision: UInt64)
        case bumpRelist
        /// Resolves relist requests up to `version`, the requested version seen when the listing started.
        case resolveRelist(UInt64)
        /// Must precede the batch's message writes: IDs already stored or notified are skipped.
        case addNotifyCandidates(SpaceName, [MessageName])
        case flagNotifyGap(SpaceName)
        /// Removes posted or suppressed IDs, from the overflow for those folded into it since; subtracts `overflow`
        /// and, if `gap`, clears the gap flag.
        case removeNotifyPending(SpaceName, messages: [MessageName], overflow: Int, gap: Bool)
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
    /// Every meta entry whose key starts with `prefix`.
    func metas(prefix: String) throws(StoreError) -> [String: String]

    @discardableResult
    func write(_ batch: StoreWrite, gate: SessionGate, generation: Generation) throws(StoreError) -> StoreWriteResult
}

extension AccountStore {
    @discardableResult
    public func write(
        gate: SessionGate, generation: Generation, _ build: (inout StoreWrite) -> Void
    ) throws(StoreError) -> StoreWriteResult {
        var batch = StoreWrite()
        build(&batch)
        guard !batch.isEmpty else { return StoreWriteResult() }
        return try write(batch, gate: gate, generation: generation)
    }

    public func owed(_ space: SpaceName) throws(StoreError) -> OwedRecord? {
        Bookkeeping.decode(try meta(OwedRecord.key(space)), as: OwedRecord.self)
    }

    public func owedRecords() throws(StoreError) -> [SpaceName: OwedRecord] {
        try records(OwedRecord.keyPrefix, as: OwedRecord.self)
    }

    public func notifyRecords() throws(StoreError) -> [SpaceName: NotifyRecord] {
        try records(NotifyRecord.keyPrefix, as: NotifyRecord.self)
    }

    public func relist() throws(StoreError) -> RelistRecord {
        Bookkeeping.decode(try meta(RelistRecord.key), as: RelistRecord.self) ?? RelistRecord()
    }

    /// Listing-derived owed rows given up on, for Diagnostics.
    public func droppedOwedCount() throws(StoreError) -> Int {
        Int(try meta(Bookkeeping.droppedKey) ?? "") ?? 0
    }

    private func records<T: Decodable>(_ prefix: String, as type: T.Type) throws(StoreError) -> [SpaceName: T] {
        var records: [SpaceName: T] = [:]
        for (key, value) in try metas(prefix: prefix) {
            guard let space = SpaceName(String(key.dropFirst(prefix.count))),
                let record = Bookkeeping.decode(value, as: T.self)
            else { continue }
            records[space] = record
        }
        return records
    }
}
