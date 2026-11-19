import ChatModel
import ChatStore
import Foundation
import GoogleChat

public struct SessionTiming: Sendable {
    public var sidebarInterval: Duration = .seconds(60)
    public var inactiveSidebarInterval: Duration = .seconds(30)
    /// While the app is inactive and the event channel delivers new messages.
    public var liveSidebarInterval: Duration = .seconds(120)
    public var focusInterval: ClosedRange<Double> = 15...20
    public var spacesPerTick = 40
    public var concurrentSpaceSyncs = 8
    public var reconcilePerTick = 5
    public var titlesPerTick = 3
    /// Until the first full sync completes, so DMs show names right after sign-in.
    public var initialTitles = 40
    public var activeWindow: Duration = .seconds(30 * 86_400)
    public var logoutDrain: Duration = .seconds(5)
    /// The longest single sleep of the poll loop; it normally sleeps until its next deadline and is woken early.
    public var idleSleep: Duration = .seconds(600)
    /// Event polls after a delete, waiting out the poll's trailing window and any sync already running.
    public var deleteReconcileDelays: [Duration] = [.seconds(3), .seconds(10), .seconds(30)]

    public init() {}

    public func sidebarInterval(appActive: Bool, liveChannel: Bool) -> Duration {
        guard !appActive else { return sidebarInterval }
        return liveChannel ? liveSidebarInterval : inactiveSidebarInterval
    }
}

public enum Connectivity: Sendable, Equatable {
    case reachable
    case unreachable
}

public struct ThreadReadPosition: Equatable, Sendable {
    public let thread: ThreadName
    public let upTo: Timestamp

    public init(thread: ThreadName, upTo: Timestamp) {
        self.thread = thread
        self.upTo = upTo
    }
}

/// Everything one account owns. Accounts share nothing but the manager's registry and the memory budget.
public actor AccountSession {
    public nonisolated let account: AccountID
    public nonisolated let gate: SessionGate
    public nonisolated let snapshots = LatestValue<AccountSnapshot>()
    /// Attachment downloads, image decoding and exports; `nil` when the account has no media cache.
    public nonisolated let mediaLoader: MediaLoader?
    /// The user's own reactions (for highlighting and toggling) and the org's custom emoji.
    public nonisolated let reactions: Reactions
    /// People to start a DM with, from cached chats and (if granted) the Workspace directory.
    public nonisolated let contacts: Contacts
    public nonisolated let photos: ProfilePhotos

    let engine: SyncEngine
    let sends: SendQueue
    let store: any AccountStore
    let clock: any SyncClock
    let timing: SessionTiming
    let work = WorkRegistry()
    let logoutRunner: LogoutRunner
    let revoker: (any TokenRevoker)?
    let backoff = Backoff()
    let notifier: Notifier?

    var appActive = true
    var liveChannel = false
    var reachable = true
    /// Bumped on every path change; an offline result from an older epoch is stale.
    var connectivityEpoch: UInt64 = 0
    var catchUpPending = false
    var catchUpGeneration: UInt64 = 0
    var closing = false
    var blockedDrains: Set<SpaceName> = []
    var blockedMarkReads: [SpaceName: Timestamp] = [:]
    var restartEventChannel: (@Sendable () -> Void)?
    var notifyPending: Set<SpaceName> = []
    var notifyRunning = false
    var notifyForced = false
    var notifyRetryArmed = false
    var notifyRetryAttempts = 0
    var owedSyncWanted = false
    var owedSyncArmed = false
    var owedFirstRequest: Timestamp?
    var status: AccountStatus = .starting
    var paused = false
    var focused: SpaceName?
    var visibleThreads: [ThreadName] = []
    var openThreadRead: ThreadReadPosition?
    var pendingThreadRead: ThreadReadPosition?
    var updatingThreadRead = false
    /// A save was asked for while one was running, so a `.busy` answer to the running one mustn't end the flush.
    var threadReadRetryRequested = false
    /// When each thread outside the visible ones last had its read time checked, for the recheck interval.
    var threadReadsChecked: [ThreadName: Timestamp] = [:]
    var threadReadsGeneration: Generation?
    var discoveringThreads = false
    /// The focused space while some of its threads' read times are still due a check.
    var discoveringSpace: SpaceName?
    static let threadReadRecheck = Duration.seconds(600)
    static let threadReadDiscoveryBudget = 5
    var memberFetches: [SpaceName: Task<Result<Bool, SyncError>, Never>] = [:]
    var nextSidebar: Timestamp?
    var nextFocus: Timestamp?
    /// Only `.transport(.offline)`; a reconnect clears it.
    var offlineUntil: Timestamp?
    /// Rate limits, server errors and other retryable failures; honored whatever the connectivity.
    var retryUntil: Timestamp?
    var consecutiveFailures = 0
    var offlineFailures = 0
    /// Set whenever admission closes; the next admitted loop pass reruns the work that was turned away.
    var admissionWasClosed = false
    var reconcileCursor = 0
    var revision: UInt64 = 0
    var changedSinceSnapshot: Set<SpaceName> = []
    var unavailable: Set<String> = []
    var retryScheduled: Set<SpaceName> = []
    /// Set when an error suggests a membership loss; the next loop pass relists spaces instead of waiting a tick.
    var sidebarRequested = false
    var sleepTask: Task<Void, Never>?
    /// Cached unread/preview per space, so a commit re-decrypts only the spaces it touched.
    var digests: [SpaceName: SyncEngine.SpaceDigest] = [:]
    var digestsPrimed = false

    public init(
        account: AccountID, me: UserName, api: any ChatAPI, store: any AccountStore, clock: any SyncClock,
        logoutRunner: LogoutRunner, revoker: (any TokenRevoker)? = nil, directory: (any PeopleDirectoryAPI)? = nil,
        gate: SessionGate = SessionGate(),
        timing: SessionTiming = SessionTiming(), notifications: (any NotificationPoster)? = nil,
        media: (any ChatMediaAPI)? = nil, files: any FileAccess = SecurityScopedFileAccess(),
        mediaLoader: MediaLoader? = nil
    ) {
        self.mediaLoader = mediaLoader
        self.account = account
        self.gate = gate
        self.store = store
        self.clock = clock
        self.timing = timing
        self.logoutRunner = logoutRunner
        self.revoker = revoker
        engine = SyncEngine(api: api, store: store, gate: gate, clock: clock, me: me)
        sends = SendQueue(api: api, store: store, gate: gate, clock: clock, media: media, files: files)
        reactions = Reactions(api: api, store: store, gate: gate, clock: clock, me: me)
        contacts = Contacts(api: api, directory: directory, engine: engine, store: store, gate: gate, me: me)
        photos = ProfilePhotos(directory: directory, clock: clock)
        notifier = notifications.map {
            Notifier(account: account, store: store, gate: gate, me: me, poster: $0, clock: clock)
        }
    }

    // MARK: Reads for the UI (synchronous store reads; call off the main actor)

    public nonisolated var me: UserName { engine.me }

    public nonisolated func messages(in space: SpaceName, limit: Int = 200) throws(StoreError) -> [Message] {
        try store.messages(in: space, before: nil, limit: limit)
    }

    public nonisolated func messages(inThread thread: ThreadName, limit: Int = 200) throws(StoreError) -> [Message] {
        try store.messages(inThread: thread, limit: limit)
    }

    public nonisolated func outbox(in space: SpaceName) throws(StoreError) -> [OutboxItem] {
        try store.outbox().filter { $0.space == space }.sorted { $0.created < $1.created }
    }

    public nonisolated func draft(space: SpaceName, thread: ThreadName?) throws(StoreError) -> Draft? {
        let key = thread?.rawValue ?? space.rawValue
        return try store.drafts().first { $0.key == key }
    }

    public nonisolated func storedSpace(_ space: SpaceName) throws(StoreError) -> StoredSpace? {
        try store.space(space)
    }

    /// The space's unread messages, by the same rule as its unread count.
    public nonisolated func unread(in space: SpaceName) throws(SyncError) -> UnreadMessages {
        try engine.unread(in: space)
    }

    public func searchMessages(_ query: String, pageToken: String?) async throws(SyncError) -> Page<Message> {
        guard let generation = gate.current else { throw .retired }
        guard admitted else { throw admissionError(.searchMessages) }
        let page = try await engine.call(.searchMessages) { () async throws(ChatAPIError) in
            try await engine.api.searchMessages(query, pageSize: 25, pageToken: pageToken)
        }
        guard gate.isCurrent(generation), !Task.isCancelled else { throw .retired }
        return page
    }

    /// A small historical window around a search hit, independent of the live conversation's checkpoints.
    public func searchContext(around hit: Message) async throws(SyncError) -> [Message] {
        guard let generation = gate.current else { throw .retired }
        guard admitted else { throw admissionError(.listMessages) }
        let thread = hit.isThreadReply ? hit.thread : nil
        let before = try await engine.call(.listMessages) { () async throws(ChatAPIError) in
            try await engine.api.listMessages(
                in: hit.space, window: .init(before: hit.createTime), thread: thread, order: .descending,
                pageSize: 5, showDeleted: false, pageToken: nil)
        }
        guard gate.isCurrent(generation), !Task.isCancelled else { throw .retired }
        let after = try await engine.call(.listMessages) { () async throws(ChatAPIError) in
            try await engine.api.listMessages(
                in: hit.space, window: .init(after: hit.createTime), thread: thread, order: .ascending,
                pageSize: 5, showDeleted: false, pageToken: nil)
        }
        guard gate.isCurrent(generation), !Task.isCancelled else { throw .retired }
        return before.items.reversed() + [hit] + after.items
    }

    /// A page of messages older than `before`, newest last, for display only; nothing is stored.
    public func olderMessages(
        in space: SpaceName, before: Timestamp, pageToken: String?
    ) async throws(SyncError) -> Page<Message> {
        guard let generation = gate.current else { throw .retired }
        let page = try await engine.call(.listMessages) { () async throws(ChatAPIError) in
            try await engine.api.listMessages(
                in: space, window: .init(before: before), thread: nil, order: .descending, pageSize: 50,
                showDeleted: false, pageToken: pageToken)
        }
        guard gate.isCurrent(generation), !Task.isCancelled else { throw .retired }
        return Page(items: page.items.reversed(), nextPageToken: page.nextPageToken)
    }

    // MARK: Lifecycle

    public func start() {
        guard let generation = gate.current else { return }
        try? sends.recoverInterrupted(generation)
        publish(generation)
        scheduleNotifications([], generation, force: true)
        work.spawn { [weak self] in await self?.runLoop(generation) }
        work.spawn { [weak self] in await self?.drainAllOutboxes(generation) }
    }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused { admissionWasClosed = true }
        wake()
        if !paused, status == .offline, reachable, !isFuture(offlineUntil) { status = .ok }
    }

    /// Re-enables polling after a successful re-login.
    public func resumeAfterLogin() {
        guard status == .needsLogin, let generation = gate.current else { return }
        status = reachable ? .ok : .offline
        nextSidebar = nil
        wake()
        work.spawn { [weak self] in await self?.drainAllOutboxes(generation) }
    }

    // MARK: Focus

    /// The open space polls every 15–20 s and immediately on focus.
    public func setFocus(
        _ space: SpaceName?, visibleThreads: [ThreadName] = [], threadRead: ThreadReadPosition? = nil
    ) {
        let changed = space != focused
        focused = space
        if changed { discoveringSpace = nil }
        self.visibleThreads = Array(visibleThreads.filter { $0.space == space }.prefix(10))
        let position = threadRead.flatMap { $0.thread.space == space ? $0 : nil }
        if position != openThreadRead {
            openThreadRead = position
            pendingThreadRead = position
            if position != nil, let generation = gate.current {
                work.spawn { [weak self] in await self?.flushThreadRead(generation) }
            }
        }
        guard changed, let space, let generation = gate.current else { return wake() }
        nextFocus = nil
        wake()
        guard admitted else { return }
        work.spawn { [weak self] in await self?.focusTick(space, generation) }
    }

    /// Saves the open thread's read position. A newer position that arrives while one is being saved, as it does
    /// while a jump scrolls the thread's replies into view, is saved straight after it rather than at the next
    /// focus tick.
    func flushThreadRead(_ generation: Generation) async {
        guard !updatingThreadRead else {
            threadReadRetryRequested = true
            return
        }
        let epoch = connectivityEpoch
        updatingThreadRead = true
        defer {
            updatingThreadRead = false
            threadReadRetryRequested = false
        }
        while let position = pendingThreadRead, admitted, gate.isCurrent(generation) {
            threadReadRetryRequested = false
            do {
                let wrote = try await engine.markThreadRead(position, generation) { [weak self] in
                    await self?.openThreadRead == position
                }
                if pendingThreadRead == position { pendingThreadRead = nil }
                if wrote { didCommit(position.thread.space, generation) }
            } catch {
                switch error {
                case .busy:
                    guard threadReadRetryRequested else { return }
                case .retired:
                    return
                case .api(let apiError, _) where apiError.isRetryable:
                    handle(error, generation, epoch: epoch)
                    return
                default:
                    // This position can't be saved, but a newer one for another thread still can.
                    if pendingThreadRead == position { pendingThreadRead = nil }
                    handle(error, generation, epoch: epoch)
                }
            }
        }
    }

    public func markRead(_ space: SpaceName, upTo time: Timestamp) {
        guard let generation = gate.current else { return }
        guard admitted else { return holdMarkRead(space, upTo: time) }
        let epoch = connectivityEpoch
        work.spawn { [weak self] in
            guard let self else { return }
            do throws(SyncError) {
                try await engine.markRead(space, upTo: time, generation)
                await self.didCommit(space, generation)
            } catch {
                await self.markReadFailed(space, upTo: time, error, generation, epoch: epoch)
            }
        }
    }

    func markReadFailed(
        _ space: SpaceName, upTo time: Timestamp, _ error: SyncError, _ generation: Generation, epoch: UInt64
    ) {
        handle(error, generation, epoch: epoch)
        if case .api(let apiError, _) = error, apiError.isRetryable { holdMarkRead(space, upTo: time) }
    }

    func holdMarkRead(_ space: SpaceName, upTo time: Timestamp) {
        blockedMarkReads[space] = max(blockedMarkReads[space] ?? time, time)
        admissionWasClosed = true
    }

    // MARK: Sending

    @discardableResult
    public func send(
        _ text: String, in space: SpaceName, thread: ThreadName?, attachments: [PendingAttachment] = []
    ) throws(SyncError) -> OutboxItem {
        guard let generation = gate.current else { throw .retired }
        let item = try sends.enqueue(text: text, space: space, thread: thread, attachments: attachments, generation)
        changedSinceSnapshot.insert(space)
        publish(generation)
        work.spawn { [weak self] in await self?.drainOutbox(space, generation) }
        return item
    }

    /// "Post as new message" for a reply whose thread is gone.
    @discardableResult
    public func repostAsNewMessage(_ failed: OutboxItem) throws(SyncError) -> OutboxItem {
        guard let generation = gate.current else { throw .retired }
        let item = try sends.enqueue(text: failed.payload.text, space: failed.space, thread: nil, generation)
        try sends.discard(failed.id, generation)
        work.spawn { [weak self] in await self?.drainOutbox(failed.space, generation) }
        return item
    }

    public func discard(_ item: OutboxItem) throws(SyncError) {
        guard let generation = gate.current else { throw .retired }
        guard case .failed = item.state else { return }
        try sends.discard(item.id, generation)
        didCommit(item.space, generation)
    }

    /// Everyone who reacted to `message`, by emoji; nil when Google can't be asked right now.
    public func reactors(on message: MessageName, matching summaries: [ReactionSummary]) async -> ReactorList? {
        guard let generation = gate.current, admitted else { return nil }
        return try? await reactions.reactors(on: message, matching: summaries, generation)
    }

    /// Adds the reaction, or removes it if it's already the user's.
    public func toggleReaction(_ emoji: Emoji, on message: MessageName) {
        guard let generation = gate.current, admitted else { return }
        let epoch = connectivityEpoch
        work.spawn { [weak self, reactions] in
            do throws(SyncError) {
                try await reactions.toggle(emoji, on: message, generation)
            } catch {
                await self?.handle(error, generation, epoch: epoch, space: message.space)
            }
            await self?.didCommit(message.space, generation)
        }
    }

    /// Opens (or creates) the DM with `contact` and returns its space, already in the store.
    public func startDirectMessage(with contact: Contact) async throws(SyncError) -> SpaceName {
        guard let generation = gate.current else { throw .retired }
        guard admitted else { throw admissionError(.setUpDirectMessage) }
        let space = try await contacts.startDirectMessage(with: contact, generation)
        didCommit(space, generation)
        return space
    }

    /// Makes sure the open space's members are cached for @-mention autocomplete; call when its composer appears.
    public func prepareMentions(in space: SpaceName) {
        guard let generation = gate.current, admitted else { return }
        let epoch = connectivityEpoch
        work.spawn { [weak self] in await self?.refreshMentions(in: space, generation, epoch: epoch) }
    }

    private func refreshMentions(in space: SpaceName, _ generation: Generation, epoch: UInt64) async {
        do throws(SyncError) {
            if try await fetchMembers(in: space, generation) { didCommit(space, generation) }
        } catch {
            handle(error, generation, epoch: epoch, space: space)
        }
    }

    /// Fetches `space`'s members if stale, one fetch per space at a time; a caller that finds one running waits
    /// for it. True for the caller whose fetch wrote the cache.
    private func fetchMembers(in space: SpaceName, _ generation: Generation) async throws(SyncError) -> Bool {
        if let running = memberFetches[space] {
            _ = try await running.value.get()
            return false
        }
        let task = Task { [contacts] () -> Result<Bool, SyncError> in
            do throws(SyncError) {
                return .success(try await contacts.ensureMembers(in: space, generation))
            } catch {
                return .failure(error)
            }
        }
        memberFetches[space] = task
        let result = await task.value
        memberFetches[space] = nil
        return try result.get()
    }

    /// Makes sure `space`'s members are cached, for the members list. False when they're missing and couldn't be
    /// fetched now (offline, backing off, or the request failed).
    public func ensureMembers(in space: SpaceName) async -> Bool {
        guard let generation = gate.current else { return false }
        let epoch = connectivityEpoch
        do throws(SyncError) {
            guard try contacts.needsMembers(in: space) else { return true }
            guard admitted else { return false }
            if try await fetchMembers(in: space, generation) { didCommit(space, generation) }
            return true
        } catch .busy {
            return true
        } catch {
            handle(error, generation, epoch: epoch, space: space)
            return false
        }
    }

    /// Fills the member cache for the first `Contacts.memberRefreshLimit` of `spaces` that lack it or have it stale,
    /// one at a time, for the sidebar's pictures. The first error ends the pass, so a rate limit isn't hit repeatedly.
    public func prepareMembers(in spaces: [SpaceName]) async {
        let stale = spaces.lazy.filter { [contacts] in (try? contacts.needsMembers(in: $0)) == true }
        for space in stale.prefix(Contacts.memberRefreshLimit) {
            guard let generation = gate.current, admitted else { return }
            let epoch = connectivityEpoch
            do throws(SyncError) {
                _ = try await fetchMembers(in: space, generation)
            } catch {
                handle(error, generation, epoch: epoch, space: space)
                return
            }
        }
    }

    /// Fills the member cache used by `contacts.fromChats()`; call when the new-message sheet opens.
    public func refreshContacts() {
        guard let generation = gate.current, admitted else { return }
        let epoch = connectivityEpoch
        work.spawn { [weak self, contacts] in
            do throws(SyncError) {
                try await contacts.refreshMembers(generation)
            } catch {
                await self?.handle(error, generation, epoch: epoch)
            }
        }
    }

    public func saveDraft(_ draft: Draft) throws(SyncError) {
        guard let generation = gate.current else { throw .retired }
        do {
            try store.write(gate: gate, generation: generation) { batch in
                batch.append(draft.text.isEmpty ? .deleteDraft(key: draft.key) : .putDraft(draft))
            }
        } catch .gateClosed {
            throw .retired
        } catch {
            throw .store(error)
        }
    }

    func retryFired(_ space: SpaceName) { retryScheduled.remove(space) }

    func drainAllOutboxes(_ generation: Generation) async {
        let spaces = Set(((try? store.outbox()) ?? []).filter(\.needsWork).map(\.space))
        for space in spaces { await drainOutbox(space, generation) }
    }

    func drainOutbox(_ space: SpaceName, _ generation: Generation) async {
        guard admitted else { return holdDrain(space, generation) }
        let epoch = connectivityEpoch
        let outcomes: [UUID: SendOutcome]?
        do {
            outcomes = try await sends.drain(space, generation) { [weak self] in await self?.admitted ?? false }
        } catch {
            return handle(error, generation, epoch: epoch)
        }
        guard let outcomes else { return }
        didCommit(space, generation)
        var retryAt: Timestamp?
        var held = false
        for outcome in outcomes.values {
            switch outcome {
            case .needsLogin:
                setStatus(.needsLogin, generation)
            case .willRetry(let at):
                retryAt = min(retryAt ?? at, at)
            case .offline:
                handle(.api(.transport(.offline), .createMessage), generation, epoch: epoch)
                held = true
            case .notAdmitted:
                held = true
            case .sent, .failed, .retired:
                break
            }
        }
        if held { return holdDrain(space, generation) }
        let awaitingHydration = ((try? store.outbox()) ?? []).contains {
            if case .committed = $0.state { $0.space == space } else { false }
        }
        if awaitingHydration { retryAt = min(retryAt ?? .init(seconds: .max), clock.now().adding(.seconds(30))) }
        if let retryAt { scheduleDrain(space, at: retryAt, generation) }
    }

    /// Parks the space until admission reopens; if it already has, retries after the usual pause instead.
    func holdDrain(_ space: SpaceName, _ generation: Generation) {
        guard !admitted else { return scheduleDrain(space, at: clock.now(), generation) }
        blockedDrains.insert(space)
        admissionWasClosed = true
    }

    /// At most one pending retry timer per space.
    func scheduleDrain(_ space: SpaceName, at: Timestamp, _ generation: Generation) {
        guard retryScheduled.insert(space).inserted else { return }
        work.spawn { [weak self, clock] in
            let now = clock.now()
            let wait = Duration.seconds(max(0, at.seconds - now.seconds) + 1)
            try? await clock.sleep(for: wait)
            await self?.retryFired(space)
            guard !Task.isCancelled else { return }
            await self?.drainOutbox(space, generation)
        }
    }

    // MARK: Polling loop

    func runLoop(_ generation: Generation) async {
        while !Task.isCancelled, gate.isCurrent(generation) {
            if admitted {
                if admissionWasClosed { reopenAdmission(generation) }
                if nextSidebar.map({ $0 <= clock.now() }) ?? true {
                    sidebarRequested = false
                    let catchUp = catchUpGeneration
                    let completed = await sidebarTick(generation)
                    let reset = catchUpGeneration != catchUp
                    if reset || sidebarRequested || (catchUpPending && !admitted) {
                        nextSidebar = nil
                    } else {
                        nextSidebar = clock.now().adding(
                            timing.sidebarInterval(appActive: appActive, liveChannel: liveChannel))
                    }
                    sidebarRequested = false
                    if catchUpPending, completed, !reset, admitted { await finishCatchUp(catchUp, generation) }
                }
                if let space = focused, nextFocus.map({ $0 <= clock.now() }) ?? true {
                    let catchUp = catchUpGeneration
                    await focusTick(space, generation)
                    nextFocus =
                        catchUpGeneration == catchUp
                        ? clock.now().adding(.seconds(Double.random(in: timing.focusInterval))) : nil
                }
            }
            await sleepUntilNextDeadline()
        }
    }

    /// One timer per account instead of a periodic tick: idle accounts cost no wake-ups between polls.
    func sleepUntilNextDeadline() async {
        guard gate.current != nil, !Task.isCancelled else { return }
        let now = clock.now()
        var deadlines: [Timestamp] = []
        if !standingBlock {
            for until in [offlineUntil, retryUntil] { if let until, until > now { deadlines.append(until) } }
            if deadlines.isEmpty {
                deadlines.append(nextSidebar ?? now)
                if focused != nil { deadlines.append(nextFocus ?? now) }
            }
        }
        var wait = timing.idleSleep
        if let next = deadlines.min() {
            let remaining =
                Duration.seconds(next.seconds - now.seconds) + .nanoseconds(Int64(next.nanos) - Int64(now.nanos))
            wait = min(wait, max(remaining, .milliseconds(1)))
        }
        let clock = clock
        let sleeper = Task { _ = try? await clock.sleep(for: wait) }
        sleepTask = sleeper
        await sleeper.value
        sleepTask = nil
    }

    /// Re-evaluates deadlines now (focus change, resume, login).
    func wake() { sleepTask?.cancel() }

    /// Returns whether every step ran with admission open.
    @discardableResult
    func sidebarTick(_ generation: Generation) async -> Bool {
        setStatus(.syncing, generation)
        let result: SyncEngine.SpacesResult
        var pathEpoch = connectivityEpoch
        do {
            result = try await engine.syncSpaces(generation)
        } catch {
            handle(error, generation, epoch: pathEpoch)
            return false
        }
        changedSinceSnapshot.formUnion(result.changed)
        changedSinceSnapshot.formUnion(result.removed)
        guard admitted else { return false }

        let stored = (try? store.spaces()) ?? []
        let cutoff = clock.now().adding(.zero - timing.activeWindow)
        let active = stored.filter { !$0.isHidden && ($0.space.lastActiveTime ?? .init(seconds: 0)) > cutoff }
            .sorted { ($0.space.lastActiveTime ?? .init(seconds: 0)) > ($1.space.lastActiveTime ?? .init(seconds: 0)) }
        let unseeded = active.filter { (try? store.checkpoint($0.space.name, .messages)) == nil }.map(\.space.name)
        let owed = owedPlan(limit: timing.spacesPerTick / 2)
        var candidates: [SpaceName] = []
        for name in owed.due + result.changed + unseeded where !candidates.contains(name) { candidates.append(name) }
        await syncSpaces(Array(candidates.prefix(timing.spacesPerTick)), generation)
        guard admitted else { return false }
        await probeUnknownOwed(owed.unknown, generation)
        guard admitted else { return false }

        let changed = Set(result.changed)
        let firstSync = (try? store.meta("firstSyncCompleted")) == nil
        let epoch = Timestamp(seconds: 0)
        let needingTitles = stored.filter { stored in
            guard stored.isHidden else { return engine.needsMemberTitle(stored) }
            // Hidden for having only deleted members: recheck on new activity or when the title expires.
            guard (try? engine.isHiddenAnonymous(stored.space.name)) == true else { return false }
            return changed.contains(stored.space.name) || engine.needsMemberTitle(stored)
        }
        .sorted { ($0.space.lastActiveTime ?? epoch) > ($1.space.lastActiveTime ?? epoch) }
        .prefix(firstSync ? timing.initialTitles : timing.titlesPerTick)
        for space in needingTitles where admitted {
            pathEpoch = connectivityEpoch
            do {
                try await engine.syncMemberTitle(space.space.name, generation)
                changedSinceSnapshot.insert(space.space.name)
            } catch {
                handle(error, generation, epoch: pathEpoch, space: space.space.name)
            }
        }

        let unsettled = active.filter {
            $0.notificationSetting == nil && !unavailable.contains("notification|\($0.space.name)")
        }
        for stored in unsettled.prefix(timing.titlesPerTick * 3) where admitted {
            pathEpoch = connectivityEpoch
            do {
                try await engine.syncNotificationSetting(stored.space.name, generation)
                changedSinceSnapshot.insert(stored.space.name)
            } catch {
                handle(error, generation, epoch: pathEpoch, space: stored.space.name)
            }
        }

        if admitted {
            pathEpoch = connectivityEpoch
            do throws(SyncError) {
                try await reactions.refreshCustomEmojis(generation)
            } catch {
                handle(error, generation, epoch: pathEpoch)
            }
        }

        await reconcile(active.map(\.space.name), generation)

        if (try? store.meta("firstSyncCompleted")) == nil {
            let now = clock.now()
            _ = try? store.write(gate: gate, generation: generation) {
                $0.append(.setMeta(key: "firstSyncCompleted", value: now.rfc3339))
            }
        }
        succeeded(generation)
        return admitted
    }

    /// New-message catch-up plus read state for spaces whose activity moved.
    func syncSpaces(_ spaces: [SpaceName], _ generation: Generation) async {
        let engine = engine
        let limit = timing.concurrentSpaceSyncs
        let epoch = connectivityEpoch
        let revisions = ((try? engine.owedRecords()) ?? [:]).mapValues(\.revision)
        let failures = await withTaskGroup(of: (SpaceName, SyncError?).self) { group in
            var failures: [(SpaceName, SyncError)] = []
            var iterator = spaces.makeIterator()
            func add(_ space: SpaceName) {
                group.addTask {
                    do throws(SyncError) {
                        try await engine.syncMessages(space, generation)
                        try await engine.syncReadState(space, generation)
                        return (space, nil)
                    } catch {
                        return (space, error)
                    }
                }
            }
            for _ in 0..<limit { if let space = iterator.next() { add(space) } }
            var stopped = false
            for await (space, error) in group {
                if let error {
                    failures.append((space, error))
                    if case .api(let apiError, _) = error,
                        apiError.isRetryable || apiError == .unauthorized || apiError == .noCredentials
                    {
                        stopped = true
                    }
                }
                if !stopped, let next = iterator.next() { add(next) }
            }
            return failures
        }
        changedSinceSnapshot.formUnion(spaces)
        for (space, error) in failures {
            handle(error, generation, epoch: epoch, space: space)
            if let revision = revisions[space], error.countsAsOwedAttempt {
                try? engine.deferOwed(space, revision: revision, generation)
            }
        }
    }

    /// Round-robin over recently active spaces so edits, deletes and read changes made elsewhere arrive.
    func reconcile(_ active: [SpaceName], _ generation: Generation) async {
        guard !active.isEmpty else { return }
        for offset in 0..<min(timing.reconcilePerTick, active.count) where admitted {
            let space = active[(reconcileCursor + offset) % active.count]
            let epoch = connectivityEpoch
            do {
                try await engine.syncEvents(space, generation)
                if !unavailable.contains("readState|\(space)") { try await engine.syncReadState(space, generation) }
                changedSinceSnapshot.insert(space)
            } catch {
                handle(error, generation, epoch: epoch, space: space)
            }
        }
        reconcileCursor = (reconcileCursor + timing.reconcilePerTick) % active.count
    }

    func focusTick(_ space: SpaceName, _ generation: Generation) async {
        guard admitted else { return }
        let epoch = connectivityEpoch
        var committed = false
        var finished = false
        // Ends the tick once. After a commit the space's digest is marked stale before any error is handled, so a
        // status the error publishes carries the new badge with it; if nothing published, the badge goes out on its
        // own. A tick that committed nothing only applies its error.
        func finish(_ error: SyncError? = nil) {
            guard !finished else { return }
            finished = true
            if committed { changedSinceSnapshot.insert(space) }
            if let error { handle(error, generation, epoch: epoch, space: space) }
            if committed, changedSinceSnapshot.contains(space) { publish(generation) }
        }
        defer { finish() }
        do {
            try await engine.syncMessages(space, generation)
            committed = true
            try await engine.syncEvents(space, generation)
            if !unavailable.contains("readState|\(space)") { try await engine.syncReadState(space, generation) }
            guard focused == space else { return }
            await flushThreadRead(generation)
            guard admitted, focused == space else { return }
            if !visibleThreads.isEmpty {
                // A save that found a thread busy with this check runs once the check lets go of it, rather than at
                // the next tick. A failed check's error (a rate limit's back-off, say) applies first, and the save then
                // runs only if the session may still call Google and the space is still open.
                if case .failure(let error) = await threadReadRefresh(generation) {
                    finish(error)
                    if admitted, focused == space { await flushThreadRead(generation) }
                    return
                }
                guard admitted, focused == space else { return }
                await flushThreadRead(generation)
                guard admitted, focused == space else { return }
            }
            if case .failure(let error) = await discoverThreadReads(space, generation) {
                finish(error)
                if admitted, focused == space { await flushThreadRead(generation) }
                return
            }
            guard admitted, focused == space else { return }
            let reacted = (try? store.messages(in: space, before: nil, limit: 40)) ?? []
            let names = reacted.filter { !$0.reactions.isEmpty && !$0.isDeleted }.suffix(20).map(\.name)
            try await reactions.refreshMine(Array(names), generation)
            // One snapshot carries the new badge and the success status.
            changedSinceSnapshot.insert(space)
            finished = true
            succeeded(generation)
        } catch {
            finish(error)
        }
    }

    /// Checks the read times that decide the focused space's unread replies beyond the visible threads: a few per
    /// tick, each at most every `threadReadRecheck`. A save that found its thread held by a check runs right after it.
    func discoverThreadReads(_ space: SpaceName, _ generation: Generation) async -> Result<Void, SyncError> {
        guard !discoveringThreads else { return .success(()) }
        discoveringThreads = true
        defer { discoveringThreads = false }
        if threadReadsGeneration != generation {
            threadReadsChecked = [:]
            threadReadsGeneration = generation
        }
        // A store hiccup here only skips this tick's checks; it mustn't mark the account failed.
        let due = (try? dueThreadReads(in: space)) ?? []
        if due.isEmpty {
            discoveringSpace = nil
            return .success(())
        }
        if discoveringSpace != space {
            discoveringSpace = space
            publish(generation)
        }
        for thread in due.prefix(Self.threadReadDiscoveryBudget) {
            guard admitted, focused == space, gate.isCurrent(generation) else { return .success(()) }
            do {
                if try await engine.refreshThreadReadState(thread, generation) {
                    threadReadsChecked[thread] = clock.now()
                }
            } catch {
                return .failure(error)
            }
            if pendingThreadRead != nil, admitted, focused == space { await flushThreadRead(generation) }
        }
        if (try? dueThreadReads(in: space))?.isEmpty ?? true { discoveringSpace = nil }
        return .success(())
    }

    private func dueThreadReads(in space: SpaceName) throws(SyncError) -> [ThreadName] {
        let now = clock.now()
        return try engine.threadReadCandidates(in: space).filter { thread in
            !visibleThreads.contains(thread)
                && (threadReadsChecked[thread].map { $0.adding(Self.threadReadRecheck) <= now } ?? true)
        }
    }

    private func threadReadRefresh(_ generation: Generation) async -> Result<Void, SyncError> {
        do throws(SyncError) {
            try await engine.syncThreadReadStates(visibleThreads, generation)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: Errors and status

    /// The one admission predicate: new network work may start only while this holds.
    var admitted: Bool {
        guard !standingBlock else { return false }
        return !isFuture(offlineUntil) && !isFuture(retryUntil)
    }

    /// Blocks that only an event (reconnect, login, unpause) lifts, unlike the retry deadlines.
    var standingBlock: Bool { closing || paused || !reachable || status == .needsLogin }

    func isFuture(_ deadline: Timestamp?) -> Bool { deadline.map { $0 > clock.now() } ?? false }

    func admissionError(_ operation: ChatOperation) -> SyncError {
        if closing { return .retired }
        if status == .needsLogin { return .api(.unauthorized, operation) }
        if !reachable || isFuture(offlineUntil) { return .api(.transport(.offline), operation) }
        return .busy
    }

    func handle(_ error: SyncError, _ generation: Generation, epoch: UInt64, space: SpaceName? = nil) {
        guard gate.isCurrent(generation) else { return }
        switch error {
        case .retired, .busy, .incompletePage:
            return
        case .store:
            setStatus(.failed("store"), generation)
        case .api(let apiError, let operation):
            switch apiError {
            case .unauthorized, .noCredentials:
                setStatus(.needsLogin, generation)
                return
            default:
                break
            }
            if apiError.isRetryable {
                backOff(after: apiError, generation, epoch: epoch)
                return
            }
            guard let space else { return }
            switch apiError.spaceImpact(of: operation) {
            case .suspectMembershipLoss:
                sidebarRequested = true
                nextSidebar = nil
                wake()
            case .featureUnavailable:
                if operation == .getSpaceReadState { unavailable.insert("readState|\(space)") }
                if operation == .getNotificationSetting { unavailable.insert("notification|\(space)") }
            case .none:
                break
            }
        }
    }

    /// An offline result from before the latest path change is stale: it only asks for a fresh catch-up.
    /// Server retry deadlines always count.
    func backOff(after error: ChatAPIError, _ generation: Generation, epoch: UInt64) {
        if case .transport(.offline) = error {
            guard epoch == connectivityEpoch else { return requestCatchUp() }
            offlineFailures += 1
            let until = clock.now().adding(backoff.delay(attempt: offlineFailures - 1))
            offlineUntil = max(offlineUntil ?? until, until)
            admissionWasClosed = true
            wake()
            return setStatus(.offline, generation)
        }
        consecutiveFailures += 1
        let until = clock.now().adding(backoff.delay(attempt: consecutiveFailures - 1, after: error))
        let deadline = max(retryUntil ?? until, until)
        retryUntil = deadline
        admissionWasClosed = true
        wake()
        if status != .offline { setStatus(.backingOff(until: deadline), generation) }
    }

    /// A success never clears a retry deadline that is still in the future, nor reports online while offline.
    func succeeded(_ generation: Generation) {
        guard reachable, !isFuture(retryUntil), !isFuture(offlineUntil) else { return publish(generation) }
        consecutiveFailures = 0
        offlineFailures = 0
        retryUntil = nil
        offlineUntil = nil
        switch status {
        case .needsLogin, .failed: publish(generation)
        default: setStatus(.ok, generation)
        }
    }

    func setStatus(_ new: AccountStatus, _ generation: Generation) {
        status = new
        if new == .needsLogin { admissionWasClosed = true }
        publish(generation)
    }

    func didCommit(_ space: SpaceName, _ generation: Generation) {
        changedSinceSnapshot.insert(space)
        publish(generation)
    }

    func publish(_ generation: Generation) {
        guard gate.isCurrent(generation) else { return }
        scheduleNotifications(changedSinceSnapshot, generation)
        let spaces =
            (try? engine.snapshotSpaces(changed: digestsPrimed ? changedSinceSnapshot : nil, digests: &digests))
            ?? snapshots.current?.spaces ?? []
        digestsPrimed = true
        revision += 1
        snapshots.send(
            AccountSnapshot(
                account: account, generation: generation, status: status, spaces: spaces, revision: revision,
                changedSpaces: changedSinceSnapshot, discoveringSpaces: discoveringSpace.map { [$0] } ?? []))
        changedSinceSnapshot = []
    }

    // MARK: Logout

    /// Close the old session while preserving the store and outbox for its replacement.
    func retireForReconnect(after saveCredentials: @Sendable () throws -> Void) async throws {
        try gate.retire(after: saveCredentials)
        closing = true
        wake()
        _ = await work.cancelAndDrain(timeout: timing.logoutDrain, clock: clock)
        await mediaLoader?.close()
        gate.close()
        snapshots.finish()
    }

    public struct LogoutReport: Sendable, Equatable {
        /// The tombstone couldn't be written, so nothing was done and the session is still active.
        public var aborted: Bool
        public var drained: Bool
        public var failedSteps: [LogoutStep]
    }

    /// Durable logout: tombstone, retire, bounded drain, local erase, then best-effort revoke.
    /// `refreshToken` is captured by the caller before credentials are deleted.
    public func logout(refreshToken: String?) async -> LogoutReport {
        do {
            try logoutRunner.tombstones.write(.init(account: account, remaining: LogoutStep.allCases))
        } catch {
            return LogoutReport(aborted: true, drained: false, failedSteps: LogoutStep.allCases)
        }
        closing = true
        let retired = gate.retire()
        wake()
        status = .closing
        snapshots.send(
            AccountSnapshot(account: account, generation: retired, status: .closing, revision: revision + 1))
        let drained = await work.cancelAndDrain(timeout: timing.logoutDrain, clock: clock)
        await mediaLoader?.close()
        let failed = await logoutRunner.run(account)
        if let refreshToken, let revoker { await revoker.revoke(refreshToken) }
        gate.close()
        snapshots.finish()
        return LogoutReport(aborted: false, drained: drained, failedSteps: failed)
    }
}
