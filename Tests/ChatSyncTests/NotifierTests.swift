import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatSync

/// Records every attempt; `posted` holds only the accepted ones. `outcome` decides each attempt.
final class RecordingPoster: NotificationPoster {
    let attempted = Recorder<ChatNotification>()
    let posted = Recorder<ChatNotification>()
    let removedMessages = Recorder<[MessageName]>()
    let removedAccounts = Recorder<AccountID>()
    private let decide = Mutex<@Sendable (ChatNotification) -> PostOutcome>({ _ in .accepted })

    func setOutcome(_ outcome: @escaping @Sendable (ChatNotification) -> PostOutcome) {
        decide.withLock { $0 = outcome }
    }

    func post(_ request: ChatNotification) async -> PostOutcome {
        attempted.append(request)
        let outcome = decide.withLock { $0 }(request)
        if outcome == .accepted { posted.append(request) }
        return outcome
    }

    func remove(account: AccountID) async { removedAccounts.append(account) }
    func remove(messages: [MessageName]) async { removedMessages.append(messages) }
}

/// Retires the gate on the first message read, i.e. between the notifier's scan and its first post.
final class RetiringStore: AccountStore {
    let base: any AccountStore
    let gate: SessionGate
    private let armed = Mutex(true)

    init(base: any AccountStore, gate: SessionGate) {
        self.base = base
        self.gate = gate
    }

    func spaces() throws(StoreError) -> [StoredSpace] { try base.spaces() }
    func space(_ name: SpaceName) throws(StoreError) -> StoredSpace? { try base.space(name) }

    func messages(in space: SpaceName, before: Timestamp?, limit: Int) throws(StoreError) -> [Message] {
        try base.messages(in: space, before: before, limit: limit)
    }

    func messages(inThread thread: ThreadName, limit: Int) throws(StoreError) -> [Message] {
        try base.messages(inThread: thread, limit: limit)
    }

    func message(_ name: MessageName) throws(StoreError) -> Message? {
        let result = try base.message(name)
        if armed.withLock({ armed in
            defer { armed = false }
            return armed
        }) {
            gate.retire()
        }
        return result
    }

    func checkpoint(_ space: SpaceName, _ stream: SyncStream) throws(StoreError) -> Timestamp? {
        try base.checkpoint(space, stream)
    }
    func threadReadState(_ thread: ThreadName) throws(StoreError) -> Timestamp? { try base.threadReadState(thread) }
    func members(in space: SpaceName) throws(StoreError) -> [Membership] { try base.members(in: space) }
    func drafts() throws(StoreError) -> [Draft] { try base.drafts() }
    func outbox() throws(StoreError) -> [OutboxItem] { try base.outbox() }
    func isNotified(_ message: MessageName) throws(StoreError) -> Bool { try base.isNotified(message) }
    func meta(_ key: String) throws(StoreError) -> String? { try base.meta(key) }
    func metas(prefix: String) throws(StoreError) -> [String: String] { try base.metas(prefix: prefix) }
    func write(_ batch: StoreWrite, gate: SessionGate, generation: Generation) throws(StoreError) -> StoreWriteResult {
        try base.write(batch, gate: gate, generation: generation)
    }
}

struct NotifyRig: Sendable {
    let server = FakeChatServer()
    let alice: FakeAccount
    let bob: FakeAccount
    let store = InMemoryAccountStore()
    let gate = SessionGate()
    let clock: ServerClock
    let engine: SyncEngine
    let poster = RecordingPoster()
    let account = AccountID()
    let notifier: Notifier
    let team: SpaceName
    let dm: SpaceName

    init() {
        alice = server.addAccount(displayName: "Alice")
        bob = server.addAccount(displayName: "Bob")
        clock = ServerClock(server: server)
        let api = GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token))
        engine = SyncEngine(api: api, store: store, gate: gate, clock: clock, me: alice.user.name)
        notifier = Notifier(
            account: account, store: store, gate: gate, me: alice.user.name, poster: poster, clock: clock)
        team = server.addSpace(.space, displayName: "Team", members: [alice, bob])
        dm = server.addSpace(.directMessage, members: [alice, bob])
    }

    var generation: Generation { gate.current! }
    var spaces: [SpaceName] { [team, dm] }

    func makeNotifier(over store: any AccountStore, poster: RecordingPoster? = nil) -> Notifier {
        Notifier(
            account: account, store: store, gate: gate, me: alice.user.name, poster: poster ?? self.poster,
            clock: clock)
    }

    func settle() async throws {
        server.advance(.seconds(5))
        _ = try await engine.syncSpaces(generation)
        for space in spaces {
            try await engine.syncMessages(space, generation)
            try await engine.syncEvents(space, generation)
        }
    }

    func firstSyncDone() throws {
        let stamp = clock.now().rfc3339
        try store.write(gate: gate, generation: generation) {
            $0.append(.setMeta(key: "firstSyncCompleted", value: stamp))
        }
        server.advance(.seconds(1))
    }

    func configure(_ space: SpaceName, _ level: NotificationLevel, muted: Bool = false) throws {
        try store.write(gate: gate, generation: generation) {
            $0.append(.setNotificationSetting(space, SpaceNotificationSetting(level: level, isMuted: muted)))
        }
    }

    @discardableResult
    func bobPosts(
        _ text: String, in space: SpaceName? = nil, thread: ThreadName? = nil, annotations: [Annotation] = [],
        at: Timestamp? = nil
    ) -> Message {
        server.post(text, in: space ?? team, from: .account(bob), thread: thread, annotations: annotations, at: at)
    }

    @discardableResult
    func process(
        _ spaces: Set<SpaceName>? = nil, focus: SpaceName? = nil, active: Bool = true, with notifier: Notifier? = nil
    ) async -> NotifyPass {
        await (notifier ?? self.notifier).process(
            spaces: spaces ?? Set(self.spaces), generation: generation,
            context: NotifierContext(focusedSpace: focus, appIsActive: active))
    }

    var bodies: [String] { poster.posted.all.map(\.body) }

    func pending(_ space: SpaceName) throws -> NotifyRecord? { try store.notifyRecords()[space] }

    var mention: [Annotation] {
        [Annotation(kind: .userMention(alice.user.name), startIndex: 0, length: 5)]
    }

    /// Marks the space's cached window stale, so its next sync reseeds the newest messages.
    func forceReseed(_ space: SpaceName) throws {
        try store.write(gate: gate, generation: generation) {
            $0.append(.setMeta(key: SyncEngine.formatKey(space), value: "stale"))
        }
    }
}

struct NotifierTests {
    @Test func startupWithoutAFirstSyncPostsNothing() async throws {
        let rig = NotifyRig()
        rig.bobPosts("old")
        try await rig.settle()
        rig.bobPosts("newer")
        try await rig.settle()

        await rig.process()

        #expect(rig.poster.attempted.all.isEmpty)
        #expect(try rig.store.notifyRecords().isEmpty)
    }

    @Test func historyFromBeforeTheFirstSyncIsNeverQueued() async throws {
        let rig = NotifyRig()
        rig.bobPosts("history 1")
        rig.bobPosts("history 2", in: rig.dm)
        try await rig.settle()
        try rig.firstSyncDone()
        try await rig.settle()

        await rig.process()

        #expect(rig.poster.attempted.all.isEmpty)
        #expect(try rig.store.notifyRecords().isEmpty)
    }

    @Test func newMessagesPostOnceAndSurviveARestart() async throws {
        let rig = NotifyRig()
        rig.bobPosts("history")
        try await rig.settle()
        try rig.firstSyncDone()
        await rig.process()

        let message = rig.bobPosts("lunch?")
        try await rig.settle()
        #expect(try rig.pending(rig.team)?.messages(in: rig.team) == [message.name])
        await rig.process()
        #expect(rig.bodies == ["Bob: lunch?"])
        let posted = try #require(rig.poster.posted.all.first)
        #expect(posted.title == "Team")
        #expect(posted.message == message.name)
        #expect(posted.identifier == message.name.rawValue)
        #expect(posted.account == rig.account)
        #expect(posted.threadIdentifier == rig.team.rawValue)
        #expect(try rig.store.isNotified(message.name))
        #expect(try rig.store.notifyRecords().isEmpty)

        await rig.process()
        #expect(rig.bodies.count == 1)

        let restarted = rig.makeNotifier(over: rig.store)
        await rig.process(with: restarted)
        #expect(rig.bodies.count == 1)

        try await rig.settle()
        await rig.process(with: restarted)
        #expect(rig.bodies.count == 1, "the overlap refetch doesn't queue a stored message again")
    }

    @Test func directMessagesUseTheMessageTextAsTheBody() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        rig.bobPosts("ping", in: rig.dm)
        try await rig.settle()
        await rig.process()

        #expect(rig.bodies == ["ping"])
        #expect(rig.poster.posted.all.first?.threadIdentifier == rig.dm.rawValue)
    }

    @Test func bodyPreviewIsCappedAt200Characters() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        rig.bobPosts(String(repeating: "x", count: 500), in: rig.dm)
        try await rig.settle()
        await rig.process()

        #expect(rig.poster.posted.all.first?.body.count == 200)
    }

    @Test func focusSuppressesOnlyWhileTheAppIsActive() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        rig.bobPosts("seen")
        try await rig.settle()
        await rig.process(focus: rig.team, active: true)
        #expect(rig.poster.attempted.all.isEmpty)
        #expect(try rig.pending(rig.team) == nil)

        rig.bobPosts("elsewhere", in: rig.dm)
        try await rig.settle()
        await rig.process(focus: rig.team, active: true)
        #expect(rig.bodies == ["elsewhere"])

        rig.bobPosts("while away")
        try await rig.settle()
        await rig.process(focus: rig.team, active: false)
        #expect(rig.bodies == ["elsewhere", "Bob: while away"])

        await rig.process(focus: nil, active: true)
        #expect(rig.bodies.count == 2, "a message suppressed by focus is not replayed")
    }

    @Test(arguments: NotificationLevel.allCases)
    func mutedSpacesNeverNotify(_ level: NotificationLevel) async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        try rig.configure(rig.team, level, muted: true)

        rig.bobPosts("hello", annotations: rig.mention)
        try await rig.settle()
        await rig.process()

        #expect(rig.poster.attempted.all.isEmpty)
        #expect(try rig.store.notifyRecords().isEmpty, "ineligible messages never reach the queue")
    }

    @Test(arguments: [(NotificationLevel.all, true), (.off, false)])
    func aSettingChangedAfterQueueingIsHonouredAtPostTime(_ level: NotificationLevel, _ muted: Bool) async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        try rig.configure(rig.team, .all)
        for index in 0..<7 { rig.bobPosts("queued \(index)") }
        try await rig.settle()
        rig.bobPosts("single", in: rig.dm)
        try await rig.settle()
        try rig.configure(rig.team, level, muted: muted)
        try rig.configure(rig.dm, level, muted: muted)
        #expect(try rig.pending(rig.team) != nil)

        await rig.process()
        #expect(rig.poster.posted.all.isEmpty, "a preview reached a silenced space")
        #expect(try rig.store.notifyRecords().isEmpty)
    }

    @Test func offNeverNotifies() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        try rig.configure(rig.team, .off)
        try rig.configure(rig.dm, .off)

        rig.bobPosts("hello", annotations: rig.mention)
        rig.bobPosts("hello", in: rig.dm)
        try await rig.settle()
        await rig.process()

        #expect(rig.poster.attempted.all.isEmpty)
    }

    @Test func forYouNotifiesForMentionsAndDirectMessages() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        try rig.configure(rig.team, .forYou)
        try rig.configure(rig.dm, .forYou)

        rig.bobPosts("chatter")
        rig.bobPosts("@Alice look", annotations: rig.mention)
        rig.bobPosts("@all heads up", annotations: [Annotation(kind: .userMention(.all), startIndex: 0, length: 4)])
        rig.bobPosts("hi in dm", in: rig.dm)
        try await rig.settle()
        await rig.process()

        #expect(Set(rig.bodies) == ["Bob: @Alice look", "Bob: @all heads up", "hi in dm"])
    }

    @Test func mainConversationsNotifiesForRepliesInParticipatingThreads() async throws {
        let rig = NotifyRig()
        let mine = rig.server.post("my post", in: rig.team, from: .account(rig.alice))
        let theirs = rig.bobPosts("their post")
        let mentioned = rig.bobPosts("@Alice are you in?", annotations: rig.mention)
        try await rig.settle()
        try rig.firstSyncDone()
        try rig.configure(rig.team, .mainConversations)

        rig.bobPosts("reply to mine", thread: mine.thread)
        rig.bobPosts("reply to theirs", thread: theirs.thread)
        rig.bobPosts("reply to mention", thread: mentioned.thread)
        rig.bobPosts("top-level")
        try await rig.settle()
        await rig.process()

        #expect(Set(rig.bodies) == ["Bob: reply to mine", "Bob: reply to mention", "Bob: top-level"])
    }

    @Test func participationIsRefreshedWhenTheUserPostsInAThread() async throws {
        let rig = NotifyRig()
        let theirs = rig.bobPosts("their post")
        try await rig.settle()
        try rig.firstSyncDone()

        rig.bobPosts("before I joined", thread: theirs.thread)
        try await rig.settle()
        await rig.process()
        #expect(rig.poster.attempted.all.isEmpty)

        rig.server.post("me too", in: rig.team, from: .account(rig.alice), thread: theirs.thread)
        rig.bobPosts("after I joined", thread: theirs.thread)
        try await rig.settle()
        await rig.process()
        #expect(rig.bodies == ["Bob: after I joined"], "participation counts the batch being committed")
    }

    @Test func moreThanFiveInASpaceBecomeOneSummaryForThatSpaceOnly() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        for index in 0..<5 { rig.bobPosts("t\(index)") }
        rig.bobPosts("d0", in: rig.dm)
        try await rig.settle()
        await rig.process()
        #expect(rig.bodies.count == 6, "five messages in a space stay individual")

        for index in 0..<6 { rig.bobPosts("u\(index)") }
        rig.bobPosts("d1", in: rig.dm)
        try await rig.settle()
        await rig.process()

        let later = Array(rig.poster.posted.all.dropFirst(6))
        #expect(Set(later.map(\.body)) == ["6 new messages in Team", "d1"])
        #expect(later.first { $0.space == rig.team }?.message == nil)
        #expect(try rig.store.notifyRecords().isEmpty)
    }

    @Test func moreThanTwentyPendingCollapseIntoAnOverflowSummary() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        for index in 0..<25 { rig.bobPosts("m\(index)") }
        try await rig.settle()
        #expect(try rig.pending(rig.team) == NotifyRecord(ids: [], overflow: 25))
        await rig.process()

        #expect(rig.bodies == ["25 new messages in Team"])
        #expect(try rig.store.notifyRecords().isEmpty)
    }

    @Test func candidatesArrivingDuringAPostAreCountedOnce() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        for index in 0..<5 { rig.bobPosts("m\(index)") }
        try await rig.settle()
        let late = (0..<18).map { MessageName(unchecked: "\(rig.team.rawValue)/messages/late\($0)") }
        let first = Mutex(true)
        let (store, gate, generation, team) = (rig.store, rig.gate, rig.generation, rig.team)
        rig.poster.setOutcome { _ in
            if first.withLock({ $0 }) {
                first.withLock { $0 = false }
                _ = try? store.write(gate: gate, generation: generation) { $0.append(.addNotifyCandidates(team, late)) }
            }
            return .accepted
        }
        await rig.process()
        #expect(rig.bodies.count == 5)

        await rig.process()
        #expect(rig.bodies.last == "18 new messages in Team")
        #expect(try rig.store.notifyRecords().isEmpty)
    }

    @Test func aPassPostsAtMostTenAndTheRestFollow() async throws {
        let rig = NotifyRig()
        var extra: [SpaceName] = []
        for index in 0..<12 {
            extra.append(rig.server.addSpace(.space, displayName: "Room \(index)", members: [rig.alice, rig.bob]))
        }
        try await rig.settle()
        try rig.firstSyncDone()
        for space in extra { try await rig.engine.syncMessages(space, rig.generation) }

        for space in extra { rig.bobPosts("hello", in: space) }
        rig.server.advance(.seconds(5))
        for space in extra { try await rig.engine.syncMessages(space, rig.generation) }
        let first = await rig.process(Set(extra))
        #expect(rig.poster.posted.all.count == 10)
        #expect(first.more)

        let second = await rig.process(Set(extra))
        #expect(rig.poster.posted.all.count == 12)
        #expect(!second.more)
        #expect(Set(rig.poster.posted.all.map(\.space)) == Set(extra))
    }

    @Test func partialSuccessKeepsOnlyTheFailedPostPending() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        let failing = rig.bobPosts("flaky")
        rig.bobPosts("fine")
        try await rig.settle()
        rig.poster.setOutcome { $0.message == failing.name ? .retryable("notifications.1") : .accepted }
        let pass = await rig.process()

        #expect(pass.retry)
        #expect(rig.bodies == ["Bob: fine"])
        #expect(try rig.pending(rig.team)?.messages(in: rig.team) == [failing.name])
        #expect(try !rig.store.isNotified(failing.name))

        rig.poster.setOutcome { _ in .accepted }
        let retried = await rig.process([])
        #expect(!retried.retry)
        #expect(rig.bodies == ["Bob: fine", "Bob: flaky"])
        #expect(try rig.store.notifyRecords().isEmpty)
    }

    @Test func suppressedPostsAreNotRetried() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        let message = rig.bobPosts("quiet please")
        try await rig.settle()
        rig.poster.setOutcome { _ in .suppressed }
        let pass = await rig.process()

        #expect(!pass.retry)
        #expect(try rig.store.notifyRecords().isEmpty)
        #expect(try !rig.store.isNotified(message.name))
    }

    @Test func aRestartBeforeTheRetryStillPosts() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        rig.bobPosts("during an outage")
        try await rig.settle()
        rig.poster.setOutcome { _ in .retryable("notifications.1") }
        await rig.process()
        #expect(rig.bodies.isEmpty)

        let fresh = RecordingPoster()
        await rig.process([], with: rig.makeNotifier(over: rig.store, poster: fresh))
        #expect(fresh.posted.all.map(\.body) == ["Bob: during an outage"])
    }

    @Test func aFailedSummaryStaysNextToASuccessfulOne() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        for index in 0..<25 {
            rig.bobPosts("t\(index)")
            rig.bobPosts("d\(index)", in: rig.dm)
        }
        try await rig.settle()
        let team = rig.team
        rig.poster.setOutcome { $0.space == team ? .retryable("notifications.1") : .accepted }
        let pass = await rig.process()

        #expect(pass.retry)
        #expect(rig.bodies == ["25 new messages in Direct message"])
        #expect(try rig.pending(rig.dm) == nil)
        #expect(try rig.pending(rig.team)?.overflow == 25)

        rig.poster.setOutcome { _ in .accepted }
        await rig.process([])
        #expect(rig.bodies.last == "25 new messages in Team")
        #expect(try rig.store.notifyRecords().isEmpty)
    }

    @Test func aLargeCatchUpCountsEligibleMessagesOnly() async throws {
        let rig = NotifyRig()
        let root = rig.bobPosts("their thread")
        try await rig.settle()
        try rig.firstSyncDone()
        try rig.configure(rig.team, .mainConversations)

        for index in 0..<300 {
            rig.bobPosts("top \(index)")
            rig.bobPosts("reply \(index)", thread: root.thread)
        }
        try await rig.settle()
        await rig.process()

        #expect(rig.bodies == ["300 new messages in Team"], "pruned rows are still counted, suppressed ones never")
    }

    @Test func aLateMessageFoundByReconcileBehindTheCatchUpIsNotified() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        let early = rig.clock.now()
        rig.bobPosts("before", at: early)
        rig.bobPosts("after", at: early.adding(.seconds(5)))
        rig.server.advance(.seconds(10))
        try await rig.engine.syncMessages(rig.team, rig.generation)
        await rig.process()

        let late = rig.bobPosts("late", at: early.adding(.seconds(1)))
        try await rig.engine.syncEvents(rig.team, rig.generation)
        #expect(try rig.store.message(late.name) != nil)
        await rig.process()
        #expect(rig.bodies == ["Bob: before", "Bob: after", "Bob: late"])

        try await rig.settle()
        await rig.process()
        #expect(rig.bodies.count == 3)
    }

    @Test func aReconcileAfterALargeCatchUpPostsNoSecondSummary() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        for index in 0..<600 { rig.bobPosts("m\(index)") }
        rig.server.advance(.seconds(5))
        try await rig.engine.syncMessages(rig.team, rig.generation)
        await rig.process()
        #expect(rig.bodies == ["600 new messages in Team"])

        try await rig.engine.syncEvents(rig.team, rig.generation)
        await rig.process()
        #expect(rig.bodies == ["600 new messages in Team"], "pruned rows were decided once already")
        #expect(try rig.store.notifyRecords().isEmpty)
    }

    @Test func aRecoveredOlderMessageIsStillNotified() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        let early = rig.clock.now()
        rig.server.advance(.seconds(10))
        rig.bobPosts("newer")
        try await rig.settle()
        await rig.process()
        #expect(rig.bodies == ["Bob: newer"])

        let late = rig.bobPosts("late", at: early.adding(.seconds(1)))
        _ = try rig.engine.recordEvents(
            [.messagesCreated(space: rig.team, messages: [late.name], time: late.createTime)], rig.generation)
        try await rig.settle()
        #expect(try rig.store.message(late.name) != nil)
        #expect(try rig.store.owed(rig.team) == nil)
        await rig.process()

        #expect(rig.bodies == ["Bob: newer", "Bob: late"])
    }

    @Test func aReseedGapIsSummarized() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        for index in 0..<60 { rig.server.post("mine \(index)", in: rig.team, from: .account(rig.alice)) }
        try rig.forceReseed(rig.team)
        try await rig.settle()
        #expect(try rig.pending(rig.team) == NotifyRecord(gap: true))
        await rig.process()

        #expect(rig.bodies == ["New messages in Team"])
        #expect(rig.poster.posted.all.first?.message == nil)
        #expect(try rig.store.notifyRecords().isEmpty)
    }

    @Test func aReseedGapCountsTheSeededCandidates() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        for index in 0..<60 { rig.bobPosts("b\(index)") }
        try rig.forceReseed(rig.team)
        try await rig.settle()
        await rig.process()

        #expect(rig.bodies == ["50 new messages in Team"])
    }

    @Test func aPageCapFallbackFlagsTheGapAndClearsTheListingRow() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        let count = SyncEngine.maxCatchUpPages * SyncEngine.pageSize + 1
        for index in 0..<count { rig.bobPosts("flood \(index)") }
        rig.server.advance(.seconds(5))
        _ = try await rig.engine.syncSpaces(rig.generation)
        #expect(try rig.store.owed(rig.team) != nil)
        try await rig.engine.syncMessages(rig.team, rig.generation)

        #expect(try rig.store.owed(rig.team) == nil, "the newest seeded message reaches the listing boundary")
        #expect(try rig.pending(rig.team) == NotifyRecord(ids: [], overflow: SyncEngine.initialMessages, gap: true))
        await rig.process()
        #expect(rig.bodies == ["50 new messages in Team"])
    }

    @Test func aReseedGapIsSuppressedDuringTheFirstSyncWhenMutedAndInFocus() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        for index in 0..<60 { rig.bobPosts("before \(index)") }
        try rig.forceReseed(rig.team)
        try await rig.settle()
        #expect(try rig.pending(rig.team) == nil, "no gap before the first sync completes")

        try rig.firstSyncDone()
        try rig.configure(rig.team, .all, muted: true)
        for index in 0..<60 { rig.bobPosts("muted \(index)") }
        try rig.forceReseed(rig.team)
        try await rig.settle()
        #expect(try rig.pending(rig.team) == nil, "no gap while muted")

        try rig.configure(rig.team, .all, muted: false)
        for index in 0..<60 { rig.server.post("mine \(index)", in: rig.team, from: .account(rig.alice)) }
        try rig.forceReseed(rig.team)
        try await rig.settle()
        #expect(try rig.pending(rig.team)?.gap == true)
        await rig.process(focus: rig.team, active: true)

        #expect(rig.poster.attempted.all.isEmpty)
        #expect(try rig.store.notifyRecords().isEmpty)
    }

    @Test func aRetiredGenerationPostsAndCommitsNothing() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        let message = rig.bobPosts("too late")
        try await rig.settle()
        let barrier = RetiringStore(base: rig.store, gate: rig.gate)
        let guarded = rig.makeNotifier(over: barrier)
        let old = rig.generation
        await guarded.process(
            spaces: [rig.team], generation: old, context: NotifierContext(focusedSpace: nil, appIsActive: true))

        #expect(rig.gate.isCurrent(old) == false)
        #expect(rig.poster.attempted.all.isEmpty)
        #expect(try rig.store.isNotified(message.name) == false)
        #expect(try rig.store.notifyRecords()[rig.team]?.messages(in: rig.team) == [message.name])
    }

    @Test func aCrashAfterPostingRepostsUnderTheSameIdentifier() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        let message = rig.bobPosts("posted, then crashed")
        try await rig.settle()
        let gate = rig.gate
        rig.poster.setOutcome { _ in
            gate.retire()
            return .accepted
        }
        await rig.process()
        #expect(try rig.pending(rig.team)?.messages(in: rig.team) == [message.name])

        _ = rig.gate.activate()
        rig.poster.setOutcome { _ in .accepted }
        await rig.process([], with: rig.makeNotifier(over: rig.store))
        #expect(Set(rig.poster.posted.all.map(\.identifier)) == [message.name.rawValue])
        #expect(try rig.store.notifyRecords().isEmpty)
    }

    @Test func aGenerationRetiredBeforeTheCallDoesNothing() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        rig.bobPosts("pending")
        try await rig.settle()
        let old = rig.generation
        rig.gate.retire()
        await rig.notifier.process(
            spaces: [rig.team], generation: old, context: NotifierContext(focusedSpace: nil, appIsActive: true))

        #expect(rig.poster.attempted.all.isEmpty)
        #expect(try rig.store.notifyRecords()[rig.team] != nil)
    }

    @Test func deletingANotifiedMessageRequestsItsRemoval() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        let message = rig.bobPosts("oops")
        try await rig.settle()
        await rig.process()
        #expect(rig.bodies == ["Bob: oops"])
        #expect(rig.poster.removedMessages.all.isEmpty)

        rig.server.delete(message.name)
        try await rig.settle()
        await rig.process()
        #expect(rig.poster.removedMessages.all == [[message.name]])

        await rig.process()
        #expect(rig.poster.removedMessages.all.count == 1)
    }

    @Test func aMessageDeletedBeforeItsPostIsDropped() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()

        let message = rig.bobPosts("gone soon")
        try await rig.settle()
        rig.server.delete(message.name)
        try await rig.settle()
        await rig.process()

        #expect(rig.poster.attempted.all.isEmpty)
        #expect(try rig.store.notifyRecords().isEmpty)
    }

    @Test func deletingAMessageThatNeverNotifiedRequestsNothing() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        try rig.configure(rig.team, .all, muted: true)

        let message = rig.bobPosts("quiet")
        try await rig.settle()
        await rig.process()
        rig.server.delete(message.name)
        try await rig.settle()
        await rig.process()

        #expect(rig.poster.attempted.all.isEmpty)
        #expect(rig.poster.removedMessages.all.isEmpty)
    }

    @Test func removeAllAsksThePosterToDropTheAccount() async {
        let rig = NotifyRig()
        await rig.notifier.removeAll()
        #expect(rig.poster.removedAccounts.all == [rig.account])
    }

    @Test func notificationsDoNotDescribeTheirContent() {
        let request = ChatNotification(
            account: AccountID(), space: SpaceName(unchecked: "spaces/A"), thread: nil, message: nil,
            title: "Secret title", body: "Secret body", threadIdentifier: "spaces/A", identifier: "id")
        #expect(!"\(request)".contains("Secret"))
        #expect(!String(reflecting: request).contains("Secret"))
    }
}

struct SessionNotificationTests {
    @Test func sessionNotifiesAfterTheFirstSyncAndHonoursFocus() async throws {
        let server = FakeChatServer()
        let alice = server.addAccount(displayName: "Alice")
        let bob = server.addAccount(displayName: "Bob")
        let space = server.addSpace(.space, displayName: "Team", members: [alice, bob])
        server.post("history", in: space, from: .account(bob))
        server.advance(.seconds(5))

        let scratch = ScratchDirectory()
        let poster = RecordingPoster()
        let session = AccountSession(
            account: AccountID(), me: alice.user.name,
            api: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token)),
            store: InMemoryAccountStore(), clock: RealSleepClock(server: server),
            logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: scratch.url)),
            timing: .fast, notifications: poster)
        let notifier = try #require(await session.notifier)
        notifier.tracePasses()
        let recorder = SnapshotRecorder(session.snapshots.values)
        await session.start()
        let synced = await recorder.wait { $0.status == .ok && $0.spaces.contains { $0.name == space } }
        #expect(synced != nil)
        try #require(await notifierCaughtUp(session, after: 0))

        server.advance(.seconds(1))
        server.post("new one", in: space, from: .account(bob))
        server.advance(.seconds(5))
        #expect(await poll { poster.posted.all.count == 1 })
        #expect(poster.attempted.all.map(\.body) == ["Bob: new one"], "history is never announced")

        await session.setFocus(space)
        server.advance(.seconds(1))
        let looking = server.post("while looking", in: space, from: .account(bob))
        server.advance(.seconds(5))
        #expect(
            await poll { Self.settledWithoutPost(looking.name, in: space, notifier.tracedPasses) },
            "the focused message leaves its record without a post")
        #expect(!notifier.tracedPasses.contains { $0.attempted.contains(looking.name.rawValue) })
        #expect(poster.attempted.all.count == 1)

        await session.setAppActive(false)
        server.advance(.seconds(1))
        server.post("while away", in: space, from: .account(bob))
        server.advance(.seconds(5))
        #expect(await poll { poster.posted.all.count == 2 })
        #expect(poster.posted.all.last?.body == "Bob: while away")

        recorder.cancel()
        _ = await session.logout(refreshToken: nil)
    }

    static func settledWithoutPost(_ message: MessageName, in space: SpaceName, _ passes: [NotifyPassTrace]) -> Bool {
        passes.contains { $0.settled[space]?.contains(message) == true && !$0.attempted.contains(message.rawValue) }
    }

    /// True once a notifier pass newer than `passes` has finished and nothing is queued behind it.
    func notifierCaughtUp(_ session: AccountSession, after passes: UInt64) async -> Bool {
        await pollAsync {
            let state = await session.notifierState()
            return state.passes > passes && state.idle
        }
    }
}

extension AccountSession {
    /// The loop's and the notifier's state in one read.
    func loopAndNotifier() -> (parked: Bool, nextSidebar: Timestamp?, catchUpPending: Bool, notifier: NotifierState) {
        (sleepTask != nil, nextSidebar, catchUpPending, notifierState())
    }
}

/// Server time moves only when a test advances it, so the sidebar stays parked and a retry timer fires only when
/// the test moves time to its deadline.
struct SessionNotificationRetryTests {
    struct World {
        let server = FakeChatServer()
        let alice: FakeAccount
        let bob: FakeAccount
        let spaces: [SpaceName]
        let scratch = ScratchDirectory()
        let poster = RecordingPoster()
        let store = InMemoryAccountStore()
        let clock: ServerTimeClock
        let session: AccountSession

        init(spaces count: Int) {
            alice = server.addAccount(displayName: "Alice")
            bob = server.addAccount(displayName: "Bob")
            var spaces: [SpaceName] = []
            for index in 0..<count {
                spaces.append(server.addSpace(.space, displayName: "Room \(index)", members: [alice, bob]))
            }
            self.spaces = spaces
            server.advance(.seconds(5))
            clock = ServerTimeClock(server: server)
            var timing = SessionTiming.fast
            timing.sidebarInterval = .seconds(3600)
            timing.inactiveSidebarInterval = .seconds(3600)
            timing.liveSidebarInterval = .seconds(3600)
            timing.idleSleep = .seconds(3600)
            session = AccountSession(
                account: AccountID(), me: alice.user.name,
                api: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token)),
                store: store, clock: clock,
                logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: scratch.url)),
                timing: timing, notifications: poster)
        }

        /// Starts the session with every notifier pass traced, waits for the first sync, then posts one message per
        /// space and asks for a catch-up.
        func startAndPost() async -> (notifier: Notifier, messages: [MessageName])? {
            guard let notifier = await session.notifier else { return nil }
            notifier.tracePasses()
            let recorder = SnapshotRecorder(session.snapshots.values)
            defer { recorder.cancel() }
            await session.start()
            guard await recorder.wait(where: { $0.status == .ok && $0.spaces.count == spaces.count }) != nil else {
                return nil
            }
            server.advance(.seconds(1))
            let messages = spaces.map { server.post("hello", in: $0, from: .account(bob)).name }
            server.advance(.seconds(5))
            await session.systemDidWake()
            return (notifier, messages)
        }

        /// Waits until the loop is parked far ahead, the notifier has finished a pass after `passes` with nothing
        /// queued, and its retry timer, if `armed`, is parked on the clock.
        func settled(after passes: UInt64, armed: Bool) async -> NotifierState? {
            let end = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < end {
                let (parked, nextSidebar, catchingUp, state) = await session.loopAndNotifier()
                let farSidebar = nextSidebar.map { $0 > server.now.adding(.seconds(1800)) } ?? false
                let timer = !armed || state.retryDue.map(clock.hasSleeper(until:)) == true
                if parked, farSidebar, !catchingUp, state.passes > passes, state.idle, state.retryArmed == armed, timer
                {
                    return state
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return nil
        }

        /// Moves server time to the armed retry's deadline and wakes that timer alone.
        func fireRetry(_ state: NotifierState) throws {
            let due = try #require(state.retryDue)
            server.advance(due.interval(since: server.now))
            #expect(clock.tick() == 1, "only the retry timer is due")
        }

        func attempts(of message: MessageName, in passes: ArraySlice<NotifyPassTrace>) -> Int {
            passes.reduce(0) { $0 + $1.attempted.filter { $0 == message.rawValue }.count }
        }

        func close() async {
            _ = await session.logout(refreshToken: nil)
            clock.stop()
        }
    }

    @Test func failingPostsAtTheCapDoNotSpin() async throws {
        let world = World(spaces: Notifier.maxPerPass + 2)
        world.poster.setOutcome { _ in .retryable("notifications.1") }
        let (notifier, messages) = try #require(await world.startAndPost())
        let first = try #require(await world.settled(after: 0, armed: true))
        #expect(try world.store.notifyRecords().count == messages.count)
        let traced = notifier.tracedPasses.count
        #expect(UInt64(traced) == first.passes)

        // Each retry runs exactly one pass, which tries every pending message once and arms the next retry.
        var state = first
        for delay in Notifier.retryDelays.dropFirst() {
            let due = try #require(state.retryDue)
            try world.fireRetry(state)
            state = try #require(await world.settled(after: state.passes, armed: true))
            #expect(state.retryDue == due.adding(delay))
        }
        let window = notifier.tracedPasses[traced...]
        #expect(window.count == 2)
        #expect(state.passes == first.passes + 2)
        for message in messages { #expect(world.attempts(of: message, in: window) == 2) }
        #expect(window.allSatisfy { $0.attempted.count == messages.count && $0.settled.isEmpty })
        #expect(world.poster.posted.all.isEmpty)
        await world.close()
    }

    @Test func tenFailingSpacesDoNotStarveAHealthyOne() async throws {
        let world = World(spaces: Notifier.maxPerPass + 1)
        let healthy = try #require(world.spaces.max())
        world.poster.setOutcome { $0.space == healthy ? .accepted : .retryable("notifications.1") }
        let (notifier, messages) = try #require(await world.startAndPost())
        let first = try #require(await world.settled(after: 0, armed: true))
        #expect(world.poster.posted.all.map(\.space) == [healthy])
        let traced = notifier.tracedPasses.count

        try world.fireRetry(first)
        let second = try #require(await world.settled(after: first.passes, armed: true))
        #expect(second.passes == first.passes + 1)
        let window = notifier.tracedPasses[traced...]
        #expect(window.count == 1)
        for (space, message) in zip(world.spaces, messages) {
            #expect(world.attempts(of: message, in: window) == (space == healthy ? 0 : 1))
        }
        #expect(world.poster.posted.all.map(\.space) == [healthy])
        await world.close()
    }

    @Test func theRetryTimerPostsWithoutANewCommit() async throws {
        let world = World(spaces: 1)
        let failing = Mutex(true)
        world.poster.setOutcome { _ in failing.withLock { $0 } ? .retryable("notifications.1") : .accepted }
        let (_, messages) = try #require(await world.startAndPost())
        let armed = try #require(await world.settled(after: 0, armed: true))
        #expect(world.poster.posted.all.isEmpty)
        failing.withLock { $0 = false }
        let revision = await world.session.revision
        let requests = world.server.requests.count

        try world.fireRetry(armed)
        let done = try #require(await world.settled(after: armed.passes, armed: false))
        #expect(done.passes == armed.passes + 1)
        #expect(world.poster.posted.all.map(\.identifier) == messages.map(\.rawValue))
        #expect(world.poster.posted.all.first?.body == "Bob: hello")
        #expect(await world.session.revision == revision, "no sync commit led to the post")
        #expect(world.server.requests.count == requests)
        await world.close()
    }
}
