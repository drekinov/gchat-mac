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

    public init() {}

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

    // MARK: Writes

    public func write(_ batch: StoreWrite, gate: SessionGate, generation: Generation) throws(StoreError) {
        do {
            try gate.commit(generation) { () throws(StoreError) in
                state.withLock { state in
                    for operation in batch.operations { Self.apply(operation, &state) }
                }
            }
        } catch {
            throw .gateClosed
        }
    }

    private static func apply(_ operation: StoreWrite.Operation, _ state: inout State) {
        switch operation {
        case .mergeSpace(let space):
            if state.spaces[space.name] != nil {
                state.spaces[space.name]?.space = space
            } else {
                let members = state.members[space.name]
                state.spaces[space.name] = SpaceRecord(
                    space: space, memberTitle: members?.title, memberTitleFetched: members?.fetched)
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
        }
    }
}
