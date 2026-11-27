import ChatModel
import Foundation
import Synchronization

/// Dictionary-backed store with the same semantics as `SQLiteAccountStore`, for tests of the sync core.
public final class InMemoryAccountStore: AccountStore {
    private struct SpaceRecord {
        var space: Space
        var notificationSetting: SpaceNotificationSetting?
        var memberTitle: String?
        var memberTitleFetched: Timestamp?
        var isHidden = false
    }

    private struct MembersRecord {
        var members: [Membership]
        var title: String?
        var fetched: Timestamp
    }

    private struct CheckpointKey: Hashable {
        var space: SpaceName
        var stream: SyncStream
    }

    private struct State {
        var spaces: [SpaceName: SpaceRecord] = [:]
        var messages: [MessageName: Message] = [:]
        var members: [SpaceName: MembersRecord] = [:]
        var drafts: [String: Draft] = [:]
        var spaceReads: [SpaceName: Timestamp] = [:]
        var threadReads: [ThreadName: Timestamp] = [:]
        var checkpoints: [CheckpointKey: Timestamp] = [:]
        var outbox: [UUID: OutboxItem] = [:]
        var notified: [MessageName: Timestamp] = [:]
        var meta: [String: String] = [:]
    }

    private let state = Mutex(State())
    /// The time `HistoryRetention` is applied at.
    private let now: @Sendable () -> Timestamp

    public init(now: @escaping @Sendable () -> Timestamp = { Timestamp(Date()) }) {
        self.now = now
    }

    // MARK: Reads

    public func spaces() throws(StoreError) -> [StoredSpace] {
        state.withLock { state in
            state.spaces.values.sorted { $0.space.name < $1.space.name }.map { Self.stored($0, state) }
        }
    }

    public func space(_ name: SpaceName) throws(StoreError) -> StoredSpace? {
        state.withLock { state in state.spaces[name].map { Self.stored($0, state) } }
    }

    private static func stored(_ record: SpaceRecord, _ state: State) -> StoredSpace {
        StoredSpace(
            space: record.space, lastReadTime: state.spaceReads[record.space.name],
            notificationSetting: record.notificationSetting, memberTitle: record.memberTitle,
            memberTitleFetched: record.memberTitleFetched, isHidden: record.isHidden)
    }

    public func messages(in space: SpaceName, before: Timestamp?, limit: Int) throws(StoreError) -> [Message] {
        guard limit > 0 else { return [] }
        return state.withLock { state in
            Self.newest(
                state.messages.values.filter { message in
                    message.space == space && (before.map { message.createTime < $0 } ?? true)
                }, limit)
        }
    }

    public func messages(inThread thread: ThreadName, limit: Int) throws(StoreError) -> [Message] {
        guard limit > 0 else { return [] }
        return state.withLock { state in Self.newest(state.messages.values.filter { $0.thread == thread }, limit) }
    }

    private static func newest(_ messages: some Sequence<Message>, _ limit: Int) -> [Message] {
        Array(messages.sorted(by: newerFirst).prefix(limit).reversed())
    }

    private static func newerFirst(_ lhs: Message, _ rhs: Message) -> Bool {
        (lhs.createTime, lhs.name) > (rhs.createTime, rhs.name)
    }

    public func message(_ name: MessageName) throws(StoreError) -> Message? {
        state.withLock { $0.messages[name] }
    }

    public func checkpoint(_ space: SpaceName, _ stream: SyncStream) throws(StoreError) -> Timestamp? {
        state.withLock { $0.checkpoints[CheckpointKey(space: space, stream: stream)] }
    }

    public func threadReadState(_ thread: ThreadName) throws(StoreError) -> Timestamp? {
        state.withLock { $0.threadReads[thread] }
    }

    public func members(in space: SpaceName) throws(StoreError) -> [Membership] {
        state.withLock { $0.members[space]?.members ?? [] }
    }

    public func drafts() throws(StoreError) -> [Draft] {
        state.withLock { state in state.drafts.sorted { $0.key < $1.key }.map(\.value) }
    }

    public func outbox() throws(StoreError) -> [OutboxItem] {
        state.withLock { state in
            state.outbox.values.sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
        }
    }

    public func isNotified(_ message: MessageName) throws(StoreError) -> Bool {
        state.withLock { $0.notified[message] != nil }
    }

    public func meta(_ key: String) throws(StoreError) -> String? {
        state.withLock { $0.meta[key] }
    }

    public func metas(prefix: String) throws(StoreError) -> [String: String] {
        state.withLock { state in state.meta.filter { $0.key.hasPrefix(prefix) } }
    }

    // MARK: Writes

    @discardableResult
    public func write(
        _ batch: StoreWrite, gate: SessionGate, generation: Generation
    ) throws(StoreError) -> StoreWriteResult {
        do {
            return try gate.commit(generation) { () throws(StoreError) -> StoreWriteResult in
                state.withLock { state in
                    var result = StoreWriteResult()
                    let now = self.now()
                    var touched: [SpaceName] = []
                    for operation in batch.operations {
                        if let space = operation.dropsMessages { Self.expire(space, now, &state) }
                        if Self.apply(operation, now, &state, &result) {
                            for space in operation.writtenSpaces where !touched.contains(space) {
                                touched.append(space)
                            }
                        }
                    }
                    for space in touched { Self.expire(space, now, &state) }
                    return result
                }
            }
        } catch {
            throw .gateClosed
        }
    }

    private static func expire(_ space: SpaceName, _ now: Timestamp, _ state: inout State) {
        let historyOn = state.spaces[space]?.space.historyOn
        // Captured by reference through the closures below; the store is single-threaded under its lock.
        var rows = state
        let retention = RetentionRows(
            expire: { (space, window, cutoff) in
                let doomed = rows.messages.values.filter {
                    $0.space == space && $0.createTime < cutoff && window.contains($0.createTime)
                }
                for message in doomed { rows.messages[message.name] = nil }
                return doomed.sorted { ($0.createTime, $0.name) < ($1.createTime, $1.name) }
            },
            expireOutbox: { (space, window, cutoff) in
                rows.outbox = rows.outbox.filter { _, item in
                    guard item.space == space, item.created < cutoff, window.contains(item.created),
                        case .committed = item.state
                    else { return true }
                    return false
                }
            },
            oldest: { (space, window) in
                rows.messages.values.lazy.filter { $0.space == space && window.contains($0.createTime) }
                    .map(\.createTime).min()
            })
        try? Bookkeeping.expire(
            space, historyOn: historyOn, now: now, rows: retention, get: { rows.meta[$0] }, set: { rows.meta[$0] = $1 })
        state = rows
    }

    private static func candidates(_ state: State) -> [SpaceName] {
        var names = state.spaces.values.filter { $0.space.historyOn == false }.map(\.space.name).sorted()
        for key in state.meta.keys.sorted() where key.hasPrefix(HistoryRetention.keyPrefix) {
            if let name = SpaceName(String(key.dropFirst(HistoryRetention.keyPrefix.count))), !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// Returns whether the batch must apply retention to `operation.writtenSpaces` at its end.
    private static func apply(
        _ operation: StoreWrite.Operation, _ now: Timestamp, _ state: inout State, _ result: inout StoreWriteResult
    ) -> Bool {
        let handled = try? Bookkeeping.apply(
            operation, get: { state.meta[$0] }, set: { state.meta[$0] = $1 },
            hasMessage: { state.messages[$0] != nil }, isNotified: { state.notified[$0] != nil }, result: &result)
        if handled == true { return false }
        switch operation {
        case .mergeSpace(var space):
            if let stored = state.spaces[space.name] {
                let previous = stored.space.historyOn
                space.historyOn = space.historyOn ?? previous
                state.spaces[space.name]?.space = space
                guard let historyOn = space.historyOn, previous != historyOn else { return false }
                guard let previous else { return true }
                try? Bookkeeping.observeHistory(
                    space.name, historyOn: historyOn, previous: previous, at: now,
                    margin: HistoryRetention.observationMargin, get: { state.meta[$0] }, set: { state.meta[$0] = $1 })
            } else {
                let members = state.members[space.name]
                state.spaces[space.name] = SpaceRecord(
                    space: space, memberTitle: members?.title, memberTitleFetched: members?.fetched)
                return false
            }
        case .setSpaceHidden(let name, let hidden):
            state.spaces[name]?.isHidden = hidden
        case .deleteSpace(let name):
            state.spaces[name] = nil
            state.messages = state.messages.filter { $0.key.space != name }
            state.members[name] = nil
            state.drafts = state.drafts.filter { $0.value.space != name }
            state.spaceReads[name] = nil
            state.threadReads = state.threadReads.filter { $0.key.space != name }
            state.checkpoints = state.checkpoints.filter { $0.key.space != name }
            state.notified = state.notified.filter { $0.key.space != name }
            state.meta[NotifyRecord.key(name)] = nil
            state.meta[HistoryRetention.key(name)] = nil
        case .upsertMessages(let messages):
            for message in messages {
                guard let kept = Message.merge(message, over: state.messages[message.name]) else { continue }
                state.messages[message.name] = kept
            }
        case .replaceMessages(let space, let messages, let coveredBefore):
            let keep = Set(messages.map(\.name))
            state.messages = state.messages.filter {
                $0.value.space != space || $0.value.createTime >= coveredBefore || keep.contains($0.key)
            }
            for message in messages where message.space == space {
                let stored = state.messages[message.name]
                guard let kept = Message.merge(message, over: stored, rewriteEqual: true) else { continue }
                state.messages[message.name] = kept
            }
        case .updateReactions(let name, let reactions):
            state.messages[name]?.reactions = reactions
        case .setCheckpoint(let space, let stream, let value):
            let key = CheckpointKey(space: space, stream: stream)
            if let stored = state.checkpoints[key], value < stored { break }
            state.checkpoints[key] = value
        case .setReadState(let space, let time):
            state.spaceReads[space] = time
        case .setThreadReadState(let thread, let time):
            state.threadReads[thread] = time
        case .setNotificationSetting(let name, let setting):
            state.spaces[name]?.notificationSetting = setting
        case .setMembers(let space, let members, let title, let fetched):
            state.members[space] = MembersRecord(members: members, title: title, fetched: fetched)
            state.spaces[space]?.memberTitle = title
            state.spaces[space]?.memberTitleFetched = fetched
        case .putDraft(let draft):
            state.drafts[draft.key] = draft
        case .putDraftIfAbsent(let draft):
            if state.drafts[draft.key]?.isEmpty ?? true { state.drafts[draft.key] = draft }
        case .deleteDraft(let key):
            state.drafts[key] = nil
        case .putOutbox(let item):
            state.outbox[item.id] = item
        case .deleteOutbox(let id):
            state.outbox[id] = nil
        case .markNotified(let names, let time):
            for name in names where state.notified[name] == nil { state.notified[name] = time }
        case .setMeta(let key, let value):
            state.meta[key] = value
        case .pruneMessages(let space, let keep):
            let ordered = state.messages.values.filter { $0.space == space }.sorted(by: newerFirst)
            for message in ordered.dropFirst(max(0, keep)) { state.messages[message.name] = nil }
        case .mergeOwed, .resolveOwed, .deferOwed, .owedOmitted, .clearOwed, .bumpRelist, .resolveRelist,
            .addNotifyCandidates, .flagNotifyGap, .removeNotifyPending, .clearExpiredCleanup:
            break
        case .observeHistory(let space, let historyOn, let at):
            guard let stored = state.spaces[space] else { return false }
            try? Bookkeeping.observeHistory(
                space, historyOn: historyOn, previous: stored.space.historyOn, at: at, margin: .zero,
                get: { state.meta[$0] },
                set: { state.meta[$0] = $1 })
            state.spaces[space]?.space.historyOn = historyOn
        case .expireHistoryOff(let spaces):
            for space in spaces ?? candidates(state) { expire(space, now, &state) }
        }
        return true
    }
}
