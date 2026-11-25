import ChatModel
import ChatStore
import Foundation
import GoogleChat
import Synchronization

public enum SyncError: Error, Sendable, Equatable {
    case api(ChatAPIError, ChatOperation)
    case store(StoreError)
    /// The generation was retired; the result is discarded.
    case retired
    /// Another sync of the same space is running.
    case busy
    /// A page dropped malformed records; the checkpoint stays put so the range is fetched again.
    case incompletePage(ChatOperation)
}

/// The sync operations for one account. Each operation fetches everything first and then commits the data and its
/// checkpoint in a single store write, so a failure part-way leaves the checkpoint where it was.
public struct SyncEngine: Sendable {
    public static let overlap = Duration.seconds(2)
    public static let skew = Duration.seconds(2)
    public static let initialMessages = 50
    /// Bump when `Message` mapping gains content (e.g. cards): each space re-seeds once on its next sync.
    public static let messageFormat = "3"
    public static let pageSize = 200
    public static let maxCatchUpPages = 20
    public static let maxEventWindow = Duration.seconds(28 * 86_400 - 3600)
    public static let keptMessagesPerSpace = 500
    public static let memberTitleTTL = Duration.seconds(14 * 86_400)

    let api: any ChatAPI
    let store: any AccountStore
    let gate: SessionGate
    let clock: any SyncClock
    let me: UserName
    let inFlight = InFlight<String>()
    let incomplete = IncompleteTracker()
    /// After this many consecutive incomplete passes the range is accepted, so one bad record can't stall a space.
    static let incompleteTolerance = 3

    public init(api: any ChatAPI, store: any AccountStore, gate: SessionGate, clock: any SyncClock, me: UserName) {
        self.api = api
        self.store = store
        self.gate = gate
        self.clock = clock
        self.me = me
    }

    func commit(_ generation: Generation, _ build: (inout StoreWrite) -> Void) throws(SyncError) {
        do {
            try store.write(gate: gate, generation: generation, build)
        } catch .gateClosed {
            throw .retired
        } catch {
            throw .store(error)
        }
    }

    func read<T>(_ body: () throws(StoreError) -> T) throws(SyncError) -> T {
        do { return try body() } catch { throw .store(error) }
    }

    func call<T>(_ operation: ChatOperation, _ body: () async throws(ChatAPIError) -> T) async throws(SyncError) -> T {
        do { return try await body() } catch { throw .api(error, operation) }
    }

    func exclusive<T>(_ key: String, _ body: () async throws(SyncError) -> T) async throws(SyncError) -> T {
        guard inFlight.tryBegin(key) else { throw .busy }
        defer { inFlight.end(key) }
        return try await body()
    }

    /// Throws `.incompletePage` while a range keeps dropping records, until the tolerance is used up.
    func checkComplete(_ skipped: Int, _ key: String, _ operation: ChatOperation) throws(SyncError) {
        guard skipped > 0 else { return incomplete.reset(key) }
        if incomplete.record(key) < Self.incompleteTolerance { throw .incompletePage(operation) }
        incomplete.reset(key)
    }

    /// Committed sends whose server message just arrived: their optimistic rows can go.
    func resolvedSends(_ messages: [Message]) throws(SyncError) -> [UUID] {
        let names = Set(messages.map(\.name))
        guard !names.isEmpty else { return [] }
        return try read { () throws(StoreError) in try store.outbox() }.compactMap { item in
            if case .committed(let name) = item.state, names.contains(name) { return item.id }
            return nil
        }
    }

    /// The frozen upper bound for this poll.
    func frozenEnd() -> Timestamp { clock.now().adding(.zero - Self.skew) }

    // MARK: Spaces

    public struct SpacesResult: Sendable, Equatable {
        /// New spaces or spaces whose `lastActiveTime` moved, newest first.
        public var changed: [SpaceName]
        /// Spaces hidden because a complete listing no longer contains them.
        public var removed: [SpaceName]
    }

    /// Lists every page; only a complete listing can confirm a membership loss. Spaces whose activity moved get an
    /// owed row in the same commit, so a crash before their messages are fetched loses nothing.
    public func syncSpaces(_ generation: Generation) async throws(SyncError) -> SpacesResult {
        try await exclusive("spaces") { () async throws(SyncError) -> SpacesResult in
            let relistVersion = try read { () throws(StoreError) in try store.relist().requested }
            let owedBefore = try read { () throws(StoreError) in try store.owedRecords() }.mapValues(\.revision)
            var listed: [Space] = []
            var skipped = 0
            var token: String?
            var pages = 0
            repeat {
                let page = try await call(.listSpaces) { () async throws(ChatAPIError) in
                    try await api.listSpaces(pageSize: 1000, pageToken: token)
                }
                listed += page.items
                skipped += page.skipped
                token = page.nextPageToken
                pages += 1
            } while token != nil && pages < 10
            let complete = token == nil && skipped == 0

            let stored = try read { () throws(StoreError) in try store.spaces() }
            let storedByName = Dictionary(stored.map { ($0.space.name, $0) }, uniquingKeysWith: { a, _ in a })
            let listedNames = Set(listed.map(\.name))
            let changed = listed.filter { space in
                guard let old = storedByName[space.name] else { return true }
                return old.space.lastActiveTime != space.lastActiveTime || old.isHidden
            }
            let moved = listed.compactMap { space -> (SpaceName, Timestamp)? in
                guard let old = storedByName[space.name], let time = space.lastActiveTime,
                    old.space.lastActiveTime != time
                else { return nil }
                return (space.name, time)
            }
            let removed =
                complete ? stored.filter { !$0.isHidden && !listedNames.contains($0.space.name) }.map(\.space.name) : []
            let omitted =
                complete ? owedBefore.keys.filter { !listedNames.contains($0) && !removed.contains($0) }.sorted() : []

            var hiddenAnonymous: Set<SpaceName> = []
            for stored in stored where stored.isHidden {
                if try read({ () throws(StoreError) in try store.meta(Self.anonymousKey(stored.space.name)) }) != nil {
                    hiddenAnonymous.insert(stored.space.name)
                }
            }
            try commit(generation) { batch in
                for space in listed {
                    batch.append(.mergeSpace(space))
                    if storedByName[space.name]?.isHidden == true, !hiddenAnonymous.contains(space.name) {
                        batch.append(.setSpaceHidden(space.name, false))
                    }
                }
                for (name, time) in moved { batch.append(.mergeOwed(name, boundary: time, messages: [])) }
                for name in removed {
                    batch.append(.setSpaceHidden(name, true))
                    if let revision = owedBefore[name] { batch.append(.clearOwed(name, revision: revision)) }
                }
                for name in omitted {
                    if let revision = owedBefore[name] { batch.append(.owedOmitted(name, revision: revision)) }
                }
                batch.append(.resolveRelist(relistVersion))
            }
            let sorted = changed.sorted {
                ($0.lastActiveTime ?? .init(seconds: 0)) > ($1.lastActiveTime ?? .init(seconds: 0))
            }
            return SpacesResult(changed: sorted.map(\.name), removed: removed)
        }
    }

    // MARK: Messages

    /// Catches up `messages` from the checkpoint to a frozen end, or seeds the newest window on first sync. Resolves
    /// the space's owed row in the same commit and then fetches owed messages the listing didn't return.
    public func syncMessages(_ space: SpaceName, _ generation: Generation) async throws(SyncError) {
        try await exclusive("space|\(space)") { () async throws(SyncError) in
            let revision = try read { () throws(StoreError) in try store.owed(space)?.revision } ?? 0
            let end = frozenEnd()
            guard let checkpoint = try read({ () throws(StoreError) in try store.checkpoint(space, .messages) }),
                try read({ () throws(StoreError) in try store.meta(Self.formatKey(space)) }) == Self.messageFormat
            else {
                return try await seedWindow(space, end: end, revision: revision, generation)
            }
            let start = checkpoint.adding(.zero - Self.overlap)
            guard start < end else { return }

            var fetched: [Message] = []
            var skipped = 0
            var token: String?
            var pages = 0
            repeat {
                let page = try await call(.listMessages) { () async throws(ChatAPIError) in
                    try await api.listMessages(
                        in: space, window: CreateTimeWindow(after: start, before: end), thread: nil, order: .ascending,
                        pageSize: Self.pageSize, showDeleted: true, pageToken: token)
                }
                fetched += page.items
                skipped += page.skipped
                token = page.nextPageToken
                pages += 1
            } while token != nil && pages < Self.maxCatchUpPages

            if token != nil {
                return try await seedWindow(space, end: end, revision: revision, generation)
            }
            try checkComplete(skipped, "messages|\(space)", .listMessages)
            let resolved = try resolvedSends(fetched)
            let candidates = try notifyCandidates(space, fetched)
            try commit(generation) { batch in
                if !candidates.isEmpty { batch.append(.addNotifyCandidates(space, candidates)) }
                if !fetched.isEmpty { batch.append(.upsertMessages(fetched)) }
                for id in resolved { batch.append(.deleteOutbox(id)) }
                batch.append(.resolveOwed(space, revision: revision, coveredUpTo: end, fetched: []))
                batch.append(.setCheckpoint(space, .messages, end))
                batch.append(.pruneMessages(space, keep: Self.keptMessagesPerSpace))
            }
            try await recoverOwed(space, revision: revision, coveredUpTo: end, generation)
        }
    }

    /// Fetches the newest messages and sets both the message and event checkpoints to `end`. Used on first sync,
    /// when catch-up would be too long, and when the event checkpoint is older than the event window.
    func seedWindow(
        _ space: SpaceName, end: Timestamp, revision: UInt64? = nil, _ generation: Generation
    ) async throws(SyncError) {
        let stored = try read { () throws(StoreError) in try store.owed(space)?.revision }
        let revision = revision ?? stored ?? 0
        let previous = try read { () throws(StoreError) in try store.checkpoint(space, .messages) }
        let page = try await call(.listMessages) { () async throws(ChatAPIError) in
            try await api.listMessages(
                in: space, window: CreateTimeWindow(before: end), thread: nil, order: .descending,
                pageSize: Self.initialMessages, showDeleted: true, pageToken: nil)
        }
        try checkComplete(page.skipped, "seed|\(space)", .listMessages)
        let resolved = try resolvedSends(page.items)
        let candidates = try notifyCandidates(space, page.items)
        let oldest = page.items.map(\.createTime).min()
        let skippedUnfetched =
            page.items.count >= Self.initialMessages
            && previous.map { old in oldest.map { $0 > old } ?? false } ?? false
        let gap = skippedUnfetched ? try gapIsNotifiable(space) : false
        let covered = page.items.map(\.createTime).max().map { $0.adding(.nanoseconds(1)) }
        // Replacing, not merging: older cached rows can't be kept current once the event window is lost.
        try commit(generation) { batch in
            if !candidates.isEmpty { batch.append(.addNotifyCandidates(space, candidates)) }
            if gap { batch.append(.flagNotifyGap(space)) }
            batch.append(.replaceMessages(space, page.items, coveredBefore: end))
            for id in resolved { batch.append(.deleteOutbox(id)) }
            batch.append(.resolveOwed(space, revision: revision, coveredUpTo: covered, fetched: []))
            batch.append(.setCheckpoint(space, .messages, end))
            batch.append(.setCheckpoint(space, .events, end))
            batch.append(.setMeta(key: Self.formatKey(space), value: Self.messageFormat))
        }
        try await recoverOwed(space, revision: revision, coveredUpTo: covered, generation)
    }

    static func formatKey(_ space: SpaceName) -> String { "messageFormat|\(space.rawValue)" }

    // MARK: Events

    /// Applies edits, deletes, reactions and space updates made since the event checkpoint.
    public func syncEvents(_ space: SpaceName, _ generation: Generation) async throws(SyncError) {
        try await exclusive("space|\(space)") { () async throws(SyncError) in
            let end = frozenEnd()
            guard let checkpoint = try read({ () throws(StoreError) in try store.checkpoint(space, .events) }) else {
                return
            }
            let start = checkpoint.adding(.zero - Self.overlap)
            guard start < end else { return }
            guard start.adding(Self.maxEventWindow) > end else {
                return try await seedWindow(space, end: end, generation)
            }

            var events: [TimedSpaceEvent] = []
            var skipped = 0
            var token: String?
            repeat {
                let page = try await call(.listSpaceEvents) { () async throws(ChatAPIError) in
                    try await api.listSpaceEvents(
                        in: space, types: SpaceEvent.pollTypes, start: start, end: end, pageToken: token)
                }
                events += page.items
                skipped += page.skipped
                token = page.nextPageToken
            } while token != nil
            try checkComplete(skipped, "events|\(space)", .listSpaceEvents)

            var messages: [Message] = []
            var created: [Message] = []
            var reacted: [MessageName] = []
            var spaceUpdate: Space?
            for timed in events {
                switch timed.event {
                case .messageCreated(let message):
                    messages.append(message)
                    created.append(message)
                case .messageUpdated(let message), .messageDeleted(let message):
                    messages.append(message)
                case .reactionsChanged(let name):
                    if !reacted.contains(name) { reacted.append(name) }
                case .spaceUpdated(let space):
                    spaceUpdate = space
                case .membershipsChanged:
                    break
                }
            }
            var reactions: [(MessageName, [ReactionSummary])] = []
            for name in reacted {
                do throws(ChatAPIError) {
                    let refreshed = try await api.getMessage(name)
                    messages.append(refreshed)
                    reactions.append((name, refreshed.reactions))
                } catch .notFound, .permissionDenied, .failedPrecondition {
                    // A message this account can no longer read mustn't hold up the space's other events.
                    continue
                } catch {
                    throw .api(error, .readSpace)
                }
            }
            var staleMembers: (members: [Membership], title: String?)?
            if events.contains(where: { $0.event == .membershipsChanged }),
                let stored = try read({ () throws(StoreError) in try store.space(space) }),
                stored.memberTitleFetched != nil
            {
                staleMembers = (try read { () throws(StoreError) in try store.members(in: space) }, stored.memberTitle)
            }
            let candidates = try notifyCandidates(space, try undecided(created, in: space))
            try commit(generation) { batch in
                if !candidates.isEmpty { batch.append(.addNotifyCandidates(space, candidates)) }
                if let spaceUpdate { batch.append(.mergeSpace(spaceUpdate)) }
                if !messages.isEmpty { batch.append(.upsertMessages(messages)) }
                for (name, summary) in reactions { batch.append(.updateReactions(name, summary)) }
                if let staleMembers {
                    // Fetched time zero makes the next tick refetch the title.
                    batch.append(
                        .setMembers(
                            space, staleMembers.members, title: staleMembers.title, fetched: Timestamp(seconds: 0)))
                }
                batch.append(.setCheckpoint(space, .events, end))
            }
        }
    }

    /// Catch-up already decided on messages before its checkpoint, including ones pruned since; a message there that
    /// is newer than the oldest cached one was never fetched.
    func undecided(_ created: [Message], in space: SpaceName) throws(SyncError) -> [Message] {
        guard let caughtUp = try read({ () throws(StoreError) in try store.checkpoint(space, .messages) }) else {
            return created
        }
        var behind: [Message] = []
        for message in created where message.createTime < caughtUp {
            if try read({ () throws(StoreError) in try store.message(message.name) }) == nil { behind.append(message) }
        }
        guard !behind.isEmpty else { return created.filter { $0.createTime >= caughtUp } }
        let oldest = try read { () throws(StoreError) in
            try store.messages(in: space, before: nil, limit: Self.keptMessagesPerSpace).first?.createTime
        }
        let late = behind.filter { message in oldest.map { $0 < message.createTime } ?? true }
        return created.filter { $0.createTime >= caughtUp } + late
    }

    // MARK: Read state

    public func syncReadState(_ space: SpaceName, _ generation: Generation) async throws(SyncError) {
        let lastRead = try await call(.getSpaceReadState) { () async throws(ChatAPIError) in
            try await api.getSpaceReadState(space)
        }
        let now = clock.now()
        try commit(generation) { batch in
            batch.append(.setReadState(space, lastRead))
            batch.append(.setCheckpoint(space, .readState, now))
        }
    }

    public func syncThreadReadStates(_ threads: [ThreadName], _ generation: Generation) async throws(SyncError) {
        for thread in threads { _ = try await refreshThreadReadState(thread, generation) }
    }

    /// Fetches and stores one thread's read time. False when another lookup or save holds the thread; true for any
    /// answer, including the thread's read state being unavailable.
    func refreshThreadReadState(_ thread: ThreadName, _ generation: Generation) async throws(SyncError) -> Bool {
        do {
            try await exclusive("thread-read|\(thread)") { () async throws(SyncError) in
                let time = try await threadReadTime(thread)
                try commit(generation) { $0.append(.setThreadReadState(thread, time)) }
            }
            return true
        } catch .busy {
            return false
        } catch .api(let error, let operation) where error.spaceImpact(of: operation) == .featureUnavailable {
            return true
        }
    }

    /// The threads whose read times decide the space's unread replies: each thread among its recent messages with a
    /// reply from someone else. Threads with no stored time come first, then newest reply first. None when muted.
    func threadReadCandidates(in space: SpaceName) throws(SyncError) -> [ThreadName] {
        guard let stored = try read({ () throws(StoreError) in try store.space(space) }),
            stored.notificationSetting?.isMuted != true
        else { return [] }
        let recent = try read { () throws(StoreError) in try store.messages(in: space, before: nil, limit: 100) }
        var newest: [ThreadName: Timestamp] = [:]
        for message in recent where message.isThreadReply && !message.isDeleted && message.sender.name != me {
            guard let thread = message.thread else { continue }
            newest[thread] = max(newest[thread] ?? message.createTime, message.createTime)
        }
        var unfetched: Set<ThreadName> = []
        for thread in newest.keys where try read({ () throws(StoreError) in try store.threadReadState(thread) }) == nil
        {
            unfetched.insert(thread)
        }
        return newest.keys.sorted { a, b in
            let (aNew, bNew) = (unfetched.contains(a), unfetched.contains(b))
            if aNew != bNew { return aNew }
            return newest[a, default: Timestamp(seconds: 0)] > newest[b, default: Timestamp(seconds: 0)]
        }
    }

    private func threadReadTime(_ thread: ThreadName) async throws(SyncError) -> Timestamp? {
        try await call(.getThreadReadState) { () async throws(ChatAPIError) in
            try await api.getThreadReadState(thread)
        }
    }

    /// Saves `position` unless Google already has it, or the thread stopped being open meanwhile. Returns whether the
    /// store was written, so a superseded attempt doesn't make the caller republish.
    @discardableResult
    func markThreadRead(
        _ position: ThreadReadPosition, _ generation: Generation, stillOpen: () async -> Bool
    ) async throws(SyncError) -> Bool {
        let thread = position.thread
        return try await exclusive("thread-read|\(thread)") { () async throws(SyncError) -> Bool in
            guard gate.isCurrent(generation) else { throw .retired }
            let remote = try await threadReadTime(thread)
            var stored = remote
            if remote.map({ $0 < position.upTo }) ?? true {
                guard await stillOpen(), gate.isCurrent(generation), !Task.isCancelled else { return false }
                stored =
                    try await call(.updateThreadReadState) { () async throws(ChatAPIError) in
                        try await api.updateThreadReadState(thread, lastReadTime: position.upTo)
                    } ?? position.upTo
            }
            try commit(generation) { $0.append(.setThreadReadState(thread, stored)) }
            return true
        }
    }

    /// Marks the space read up to `time` on the server and locally.
    public func markRead(_ space: SpaceName, upTo time: Timestamp, _ generation: Generation) async throws(SyncError) {
        let stored = try await call(.updateSpaceReadState) { () async throws(ChatAPIError) in
            try await api.updateSpaceReadState(space, lastReadTime: time)
        }
        try commit(generation) { batch in batch.append(.setReadState(space, stored ?? time)) }
    }

    // MARK: Members and titles

    public func needsMemberTitle(_ stored: StoredSpace) -> Bool {
        guard stored.space.type != .space || stored.space.displayName.isEmpty else { return false }
        guard let fetched = stored.memberTitleFetched else { return true }
        return fetched.adding(Self.memberTitleTTL) < clock.now()
    }

    /// Builds a title from other members. A chat whose other members are all deleted is hidden.
    public func syncMemberTitle(_ space: SpaceName, _ generation: Generation) async throws(SyncError) {
        var members: [Membership] = []
        var token: String?
        var pages = 0
        repeat {
            let page = try await call(.listMemberships) { () async throws(ChatAPIError) in
                try await api.listMemberships(in: space, pageToken: token)
            }
            members += page.items
            token = page.nextPageToken
            pages += 1
        } while token != nil && pages < 5

        let others = members.filter { $0.member.name != me && $0.state == .joined }
        let named = others.filter { !$0.member.isAnonymous }.compactMap(\.member.displayName).filter { !$0.isEmpty }
        let title = named.sorted().prefix(4).joined(separator: ", ")
        let isSpace = (try read({ () throws(StoreError) in try store.space(space) }))?.space.type == .space
        let allDeleted = !isSpace && !others.isEmpty && others.allSatisfy(\.member.isAnonymous)
        let wasHiddenAnonymous = try isHiddenAnonymous(space)
        let now = clock.now()
        try commit(generation) { batch in
            batch.append(.setMembers(space, members, title: title, fetched: now))
            if allDeleted { batch.append(.setSpaceHidden(space, true)) }
            if !allDeleted, wasHiddenAnonymous { batch.append(.setSpaceHidden(space, false)) }
            batch.append(.setMeta(key: Self.anonymousKey(space), value: allDeleted ? "1" : nil))
        }
    }

    /// Marks a chat hidden because all other members are deleted, so relisting doesn't unhide it.
    static func anonymousKey(_ space: SpaceName) -> String { "hiddenAnonymous|\(space.rawValue)" }

    public func isHiddenAnonymous(_ space: SpaceName) throws(SyncError) -> Bool {
        try read { () throws(StoreError) in try store.meta(Self.anonymousKey(space)) } != nil
    }

    public func syncNotificationSetting(_ space: SpaceName, _ generation: Generation) async throws(SyncError) {
        let setting = try await call(.getNotificationSetting) { () async throws(ChatAPIError) in
            try await api.getNotificationSetting(space)
        }
        try commit(generation) { $0.append(.setNotificationSetting(space, setting)) }
    }

    // MARK: Snapshot

    /// The message-derived part of a summary, cached per space with the inputs it was computed from.
    public struct SpaceDigest: Sendable, Equatable {
        var unreadCount: Int
        var preview: String?
        var lastReadTime: Timestamp?
        var muted: Bool
    }

    public func snapshotSpaces() throws(SyncError) -> [SpaceSummary] {
        var digests: [SpaceName: SpaceDigest] = [:]
        return try snapshotSpaces(changed: nil, digests: &digests)
    }

    /// Rebuilds summaries, decrypting messages only for spaces in `changed` (all when `nil`) or whose read time or
    /// mute moved since their digest was computed. Space rows are cheap and always re-read.
    public func snapshotSpaces(
        changed: Set<SpaceName>?, digests: inout [SpaceName: SpaceDigest]
    ) throws(SyncError) -> [SpaceSummary] {
        let spaces = try read { () throws(StoreError) in try store.spaces() }
        var summaries: [SpaceSummary] = []
        var live: Set<SpaceName> = []
        for stored in spaces where !stored.isHidden {
            let name = stored.space.name
            live.insert(name)
            let muted = stored.notificationSetting?.isMuted ?? false
            var digest = digests[name]
            if digest == nil || changed?.contains(name) ?? true || digest?.lastReadTime != stored.lastReadTime
                || digest?.muted != muted
            {
                digest = try computeDigest(stored, muted: muted)
                digests[name] = digest
            }
            guard let digest else { continue }
            summaries.append(
                SpaceSummary(
                    name: name, type: stored.space.type, title: Self.title(of: stored),
                    lastActiveTime: stored.space.lastActiveTime, unreadCount: digest.unreadCount, isMuted: muted,
                    lastMessagePreview: digest.preview, isThreaded: stored.space.isThreaded,
                    isBotDM: stored.space.isSingleUserBotDM, historyOn: stored.space.historyOn,
                    membersFetched: stored.memberTitleFetched))
        }
        digests = digests.filter { live.contains($0.key) }
        return summaries.sorted { ($0.lastActiveTime ?? .init(seconds: 0)) > ($1.lastActiveTime ?? .init(seconds: 0)) }
    }

    /// The space's most recent messages, which its unread count covers, with the read times of their threads.
    func recentMessages(_ stored: StoredSpace) throws(SyncError) -> (
        messages: [Message], threadReads: [ThreadName: Timestamp]
    ) {
        let recent = try read { () throws(StoreError) in
            try store.messages(in: stored.space.name, before: nil, limit: 100)
        }
        var threadReads: [ThreadName: Timestamp] = [:]
        for thread in Set(recent.filter(\.isThreadReply).compactMap(\.thread)) {
            if let time = try read({ () throws(StoreError) in try store.threadReadState(thread) }) {
                threadReads[thread] = time
            }
        }
        return (recent, threadReads)
    }

    /// The space's unread messages: the same rule over the same recent messages as its unread count.
    public func unread(in space: SpaceName) throws(SyncError) -> UnreadMessages {
        guard let stored = try read({ () throws(StoreError) in try store.space(space) }) else {
            return UnreadMessages()
        }
        let (recent, threadReads) = try recentMessages(stored)
        let unread = Unread.messages(
            messages: recent, lastReadTime: stored.lastReadTime, me: me,
            muted: stored.notificationSetting?.isMuted ?? false, threadReadTimes: threadReads)
        let threads = Set(unread.filter(\.isThreadReply).compactMap(\.thread))
        var roots: [ThreadName: Message] = [:]
        for message in recent where !message.isThreadReply {
            if let thread = message.thread, threads.contains(thread) { roots[thread] = message }
        }
        return UnreadMessages(messages: unread, roots: roots)
    }

    func computeDigest(_ stored: StoredSpace, muted: Bool) throws(SyncError) -> SpaceDigest {
        let (recent, threadReads) = try recentMessages(stored)
        let unread = Unread.count(
            messages: recent, lastReadTime: stored.lastReadTime, me: me, muted: muted, threadReadTimes: threadReads)
        let last = recent.last { !$0.isDeleted }
        return SpaceDigest(
            unreadCount: unread, preview: last.map { String(($0.contentPreview ?? "").prefix(140)) },
            lastReadTime: stored.lastReadTime,
            muted: muted)
    }

    static func title(of stored: StoredSpace) -> String {
        if !stored.space.displayName.isEmpty { return stored.space.displayName }
        if let title = stored.memberTitle, !title.isEmpty { return title }
        return stored.space.type == .directMessage ? "Direct message" : "Group chat"
    }
}

final class IncompleteTracker: Sendable {
    private let counts = Mutex<[String: Int]>([:])

    /// Returns the number of consecutive incomplete passes, including this one.
    func record(_ key: String) -> Int {
        counts.withLock { counts in
            counts[key, default: 0] += 1
            return counts[key]!
        }
    }

    func reset(_ key: String) { _ = counts.withLock { $0.removeValue(forKey: key) } }
}
