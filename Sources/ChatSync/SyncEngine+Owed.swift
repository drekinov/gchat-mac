import ChatModel
import ChatStore
import Foundation
import GoogleChat

extension SyncEngine {
    /// Owed messages fetched one by one per sync; the rest wait for the next one.
    static let maxOwedFetches = 25

    public struct RecordedEvents: Sendable, Equatable {
        /// Messages that didn't fit their space's owed row; their deliveries must not be acked.
        public var rejected: [MessageName]
        public var relistRequested: Bool
        public var spaces: Set<SpaceName>
    }

    /// Commits owed rows and relist requests for incoming events in one transaction, so the caller can ack after it.
    public func recordEvents(_ events: [ChatEvent], _ generation: Generation) throws(SyncError) -> RecordedEvents {
        let known = Set(
            try read { () throws(StoreError) in try store.spaces() }.filter { !$0.isHidden }.map(\.space.name))
        var relist = false
        var spaces: Set<SpaceName> = []
        var batch = StoreWrite()
        for event in events {
            switch event {
            case .messagesCreated(let space, let messages, let time):
                batch.append(.mergeOwed(space, boundary: time, messages: messages))
                spaces.insert(space)
                if !known.contains(space) { relist = true }
            case .membershipCreated:
                relist = true
            case .expirationReminder, .suspended, .expired, .unknown:
                break
            }
        }
        if relist { batch.append(.bumpRelist) }
        guard !batch.isEmpty else { return RecordedEvents(rejected: [], relistRequested: false, spaces: []) }
        let result: StoreWriteResult
        do {
            result = try store.write(batch, gate: gate, generation: generation)
        } catch .gateClosed {
            throw .retired
        } catch {
            throw .store(error)
        }
        return RecordedEvents(rejected: result.rejectedOwed, relistRequested: relist, spaces: spaces)
    }

    public func owedRecords() throws(SyncError) -> [SpaceName: OwedRecord] {
        try read { () throws(StoreError) in try store.owedRecords() }
    }

    /// Counts a failed attempt, unless new events reached the row since `revision` was read.
    public func deferOwed(_ space: SpaceName, revision: UInt64, _ generation: Generation) throws(SyncError) {
        let now = clock.now()
        try commit(generation) { $0.append(.deferOwed(space, revision: revision, at: now)) }
    }

    /// Fetches owed IDs still missing after a sync with `messages.get`. A 404 resolves an ID; so does a 403 once a
    /// complete listing has omitted the space.
    func recoverOwed(
        _ space: SpaceName, revision: UInt64, coveredUpTo: Timestamp?, keep: Bool = true, _ generation: Generation
    ) async throws(SyncError) {
        guard let record = try read({ () throws(StoreError) in try store.owed(space) }), record.hasMessages else {
            return
        }
        var missing: [MessageName] = []
        for name in record.messages(in: space) where missing.count < Self.maxOwedFetches {
            if try read({ () throws(StoreError) in try store.message(name) }) == nil { missing.append(name) }
        }
        guard !missing.isEmpty else { return }
        var recovered: [Message] = []
        var gone: [MessageName] = []
        var failure: ChatAPIError?
        for name in missing {
            do throws(ChatAPIError) {
                recovered.append(try await api.getMessage(name))
            } catch .notFound {
                gone.append(name)
            } catch .permissionDenied where record.omitted > 0 {
                gone.append(name)
            } catch {
                failure = error
                break
            }
        }
        if !keep { recovered = [] }
        if !recovered.isEmpty || !gone.isEmpty {
            let candidates = try notifyCandidates(space, recovered)
            try commit(generation) { batch in
                if !candidates.isEmpty { batch.append(.addNotifyCandidates(space, candidates)) }
                if !recovered.isEmpty { batch.append(.upsertMessages(recovered)) }
                batch.append(.resolveOwed(space, revision: revision, coveredUpTo: coveredUpTo, fetched: gone))
                batch.append(.pruneMessages(space, keep: Self.keptMessagesPerSpace))
            }
        }
        if let failure { throw .api(failure, .readSpace) }
    }

    /// Resolves IDs of a space the store doesn't show without storing what it fetches.
    func probeOwed(_ space: SpaceName, revision: UInt64, _ generation: Generation) async throws(SyncError) {
        try await exclusive("space|\(space)") { () async throws(SyncError) in
            try await recoverOwed(space, revision: revision, coveredUpTo: nil, keep: false, generation)
        }
    }

    /// The fetched messages that pass `NotificationPolicy` against stored state. Focus is checked when posting.
    func notifyCandidates(_ space: SpaceName, _ fetched: [Message]) throws(SyncError) -> [MessageName] {
        let fresh = fetched.filter { !$0.isDeleted && $0.sender.name != me }
        guard !fresh.isEmpty,
            let firstSync = try read({ () throws(StoreError) in try store.meta("firstSyncCompleted") }).flatMap({
                Timestamp(rfc3339: $0)
            }),
            let stored = try read({ () throws(StoreError) in try store.space(space) }), !stored.isHidden
        else { return [] }
        var context = PolicyContext(me: me, appIsActive: false, firstSyncCompleted: firstSync)
        if NotificationPolicy.effectiveLevel(for: stored) == .mainConversations, fresh.contains(where: \.isThreadReply)
        {
            context.participatingThreads = try read { () throws(StoreError) in
                try ParticipationTracker.threads(in: space, store: store, me: me, including: fetched)
            }
        }
        return fresh.filter { NotificationPolicy.shouldNotify($0, in: stored, context: context) }.map(\.name)
    }

    /// A reseed gap is announced only where a new message could notify at all.
    func gapIsNotifiable(_ space: SpaceName) throws(SyncError) -> Bool {
        guard try read({ () throws(StoreError) in try store.meta("firstSyncCompleted") }) != nil,
            let stored = try read({ () throws(StoreError) in try store.space(space) }), !stored.isHidden
        else { return false }
        return stored.notificationSetting?.isMuted != true && NotificationPolicy.effectiveLevel(for: stored) != .off
    }
}
