import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatSync

final class RecordingPoster: NotificationPoster {
    let posted = Recorder<ChatNotification>()
    let removedMessages = Recorder<[MessageName]>()
    let removedAccounts = Recorder<AccountID>()

    func post(_ request: ChatNotification) async { posted.append(request) }
    func remove(account: AccountID) async { removedAccounts.append(account) }
    func remove(messages: [MessageName]) async { removedMessages.append(messages) }
}

/// Retires the gate on the first message read, i.e. between the notifier's scan and its commit.
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
        let result = try base.messages(in: space, before: before, limit: limit)
        if armed.withLock({ armed in
            defer { armed = false }
            return armed
        }) {
            gate.retire()
        }
        return result
    }

    func messages(inThread thread: ThreadName, limit: Int) throws(StoreError) -> [Message] {
        try base.messages(inThread: thread, limit: limit)
    }

    func message(_ name: MessageName) throws(StoreError) -> Message? { try base.message(name) }
    func checkpoint(_ space: SpaceName, _ stream: SyncStream) throws(StoreError) -> Timestamp? {
        try base.checkpoint(space, stream)
    }
    func threadReadState(_ thread: ThreadName) throws(StoreError) -> Timestamp? { try base.threadReadState(thread) }
    func members(in space: SpaceName) throws(StoreError) -> [Membership] { try base.members(in: space) }
    func drafts() throws(StoreError) -> [Draft] { try base.drafts() }
    func outbox() throws(StoreError) -> [OutboxItem] { try base.outbox() }
    func isNotified(_ message: MessageName) throws(StoreError) -> Bool { try base.isNotified(message) }
    func meta(_ key: String) throws(StoreError) -> String? { try base.meta(key) }
    func write(_ batch: StoreWrite, gate: SessionGate, generation: Generation) throws(StoreError) {
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

    func makeNotifier(over store: any AccountStore) -> Notifier {
        Notifier(account: account, store: store, gate: gate, me: alice.user.name, poster: poster, clock: clock)
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
        _ text: String, in space: SpaceName? = nil, thread: ThreadName? = nil, annotations: [Annotation] = []
    ) -> Message {
        server.post(text, in: space ?? team, from: .account(bob), thread: thread, annotations: annotations)
    }

    func process(
        _ spaces: Set<SpaceName>? = nil, focus: SpaceName? = nil, active: Bool = true, with notifier: Notifier? = nil
    ) async {
        await (notifier ?? self.notifier).process(
            spaces: spaces ?? Set(self.spaces), generation: generation,
            context: NotifierContext(focusedSpace: focus, appIsActive: active))
    }

    var bodies: [String] { poster.posted.all.map(\.body) }

    var mention: [Annotation] {
        [Annotation(kind: .userMention(alice.user.name), startIndex: 0, length: 5)]
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

        #expect(rig.poster.posted.all.isEmpty)
        #expect(try rig.store.meta(Notifier.markKey(rig.team)) == nil)
    }

    @Test func firstPassSetsMarksWithoutPosting() async throws {
        let rig = NotifyRig()
        rig.bobPosts("history 1")
        rig.bobPosts("history 2", in: rig.dm)
        try await rig.settle()
        try rig.firstSyncDone()

        await rig.process()

        #expect(rig.poster.posted.all.isEmpty)
        #expect(try rig.store.meta(Notifier.markKey(rig.team)) != nil)
        #expect(try rig.store.meta(Notifier.markKey(rig.dm)) != nil)
    }

    @Test func newMessagesPostOnceAndSurviveARestart() async throws {
        let rig = NotifyRig()
        rig.bobPosts("history")
        try await rig.settle()
        try rig.firstSyncDone()
        await rig.process()

        let message = rig.bobPosts("lunch?")
        try await rig.settle()
        await rig.process()
        #expect(rig.bodies == ["Bob: lunch?"])
        let posted = try #require(rig.poster.posted.all.first)
        #expect(posted.title == "Team")
        #expect(posted.message == message.name)
        #expect(posted.account == rig.account)
        #expect(posted.threadIdentifier == rig.team.rawValue)
        #expect(try rig.store.isNotified(message.name))

        await rig.process()
        #expect(rig.bodies.count == 1)

        let restarted = rig.makeNotifier(over: rig.store)
        await rig.process(with: restarted)
        #expect(rig.bodies.count == 1)

        try rig.store.write(gate: rig.gate, generation: rig.generation) {
            $0.append(.setMeta(key: Notifier.markKey(rig.team), value: nil))
        }
        await rig.process(with: restarted)
        #expect(rig.bodies.count == 1, "the notified table alone must stop a repeat")
    }

    @Test func directMessagesUseTheMessageTextAsTheBody() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        await rig.process()

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
        await rig.process()

        rig.bobPosts(String(repeating: "x", count: 500), in: rig.dm)
        try await rig.settle()
        await rig.process()

        #expect(rig.poster.posted.all.first?.body.count == 200)
    }

    @Test func focusSuppressesOnlyWhileTheAppIsActive() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        await rig.process()

        rig.bobPosts("seen")
        try await rig.settle()
        await rig.process(focus: rig.team, active: true)
        #expect(rig.poster.posted.all.isEmpty)

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
        await rig.process()

        rig.bobPosts("hello", annotations: rig.mention)
        try await rig.settle()
        await rig.process()

        #expect(rig.poster.posted.all.isEmpty)
    }

    @Test func offNeverNotifies() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        try rig.configure(rig.team, .off)
        try rig.configure(rig.dm, .off)
        await rig.process()

        rig.bobPosts("hello", annotations: rig.mention)
        rig.bobPosts("hello", in: rig.dm)
        try await rig.settle()
        await rig.process()

        #expect(rig.poster.posted.all.isEmpty)
    }

    @Test func forYouNotifiesForMentionsAndDirectMessages() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        try rig.configure(rig.team, .forYou)
        try rig.configure(rig.dm, .forYou)
        await rig.process()

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
        await rig.process()

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
        await rig.process()

        rig.bobPosts("before I joined", thread: theirs.thread)
        try await rig.settle()
        await rig.process()
        #expect(rig.poster.posted.all.isEmpty)

        rig.server.post("me too", in: rig.team, from: .account(rig.alice), thread: theirs.thread)
        try await rig.settle()
        await rig.process()
        rig.bobPosts("after I joined", thread: theirs.thread)
        try await rig.settle()
        await rig.process()
        #expect(rig.bodies == ["Bob: after I joined"])
    }

    @Test func sixMessagesInOnePassBecomeOneSummaryPerSpace() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        await rig.process()

        for index in 0..<4 { rig.bobPosts("t\(index)") }
        rig.bobPosts("d0", in: rig.dm)
        try await rig.settle()
        await rig.process()
        #expect(rig.bodies.count == 5, "five messages stay individual")

        for index in 0..<5 { rig.bobPosts("u\(index)") }
        rig.bobPosts("d1", in: rig.dm)
        try await rig.settle()
        await rig.process()

        let summaries = Array(rig.poster.posted.all.dropFirst(5))
        #expect(Set(summaries.map(\.body)) == ["5 new messages in Team", "1 new message in Direct message"])
        #expect(summaries.allSatisfy { $0.message == nil })
        #expect(Set(summaries.map(\.identifier)).count == 2)
        let stored = try rig.store.messages(in: rig.team, before: nil, limit: 100)
        for message in stored { #expect(try rig.store.isNotified(message.name)) }
    }

    @Test func summariesAreCappedAtFivePerPass() async throws {
        let rig = NotifyRig()
        var extra: [SpaceName] = []
        for index in 0..<7 {
            extra.append(rig.server.addSpace(.space, displayName: "Room \(index)", members: [rig.alice, rig.bob]))
        }
        try await rig.settle()
        try rig.firstSyncDone()
        for space in extra { try await rig.engine.syncMessages(space, rig.generation) }
        await rig.process(Set(extra))

        for space in extra { rig.bobPosts("hello", in: space) }
        rig.server.advance(.seconds(5))
        for space in extra { try await rig.engine.syncMessages(space, rig.generation) }
        await rig.process(Set(extra))

        #expect(rig.poster.posted.all.count == 5)
        #expect(rig.poster.posted.all.allSatisfy { $0.message == nil })
    }

    @Test func aRetiredGenerationPostsAndCommitsNothing() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        await rig.process()

        let message = rig.bobPosts("too late")
        try await rig.settle()
        let barrier = RetiringStore(base: rig.store, gate: rig.gate)
        let guarded = rig.makeNotifier(over: barrier)
        let old = rig.generation
        await guarded.process(
            spaces: [rig.team], generation: old, context: NotifierContext(focusedSpace: nil, appIsActive: true))

        #expect(rig.gate.isCurrent(old) == false)
        #expect(rig.poster.posted.all.isEmpty)
        #expect(try rig.store.isNotified(message.name) == false)
    }

    @Test func aGenerationRetiredBeforeTheCallDoesNothing() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        let old = rig.generation
        rig.gate.retire()
        await rig.notifier.process(
            spaces: [rig.team], generation: old, context: NotifierContext(focusedSpace: nil, appIsActive: true))

        #expect(rig.poster.posted.all.isEmpty)
        #expect(try rig.store.meta(Notifier.markKey(rig.team)) == nil)
    }

    @Test func deletingANotifiedMessageRequestsItsRemoval() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        await rig.process()

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

    @Test func deletingAMessageThatNeverNotifiedRequestsNothing() async throws {
        let rig = NotifyRig()
        try await rig.settle()
        try rig.firstSyncDone()
        try rig.configure(rig.team, .all, muted: true)
        await rig.process()

        let message = rig.bobPosts("quiet")
        try await rig.settle()
        await rig.process()
        rig.server.delete(message.name)
        try await rig.settle()
        await rig.process()

        #expect(rig.poster.posted.all.isEmpty)
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
        let recorder = SnapshotRecorder(session.snapshots.values)
        await session.start()
        let synced = await recorder.wait { $0.status == .ok && $0.spaces.contains { $0.name == space } }
        #expect(synced != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(poster.posted.all.isEmpty, "history is never announced")

        server.advance(.seconds(1))
        server.post("new one", in: space, from: .account(bob))
        server.advance(.seconds(5))
        #expect(await poll { poster.posted.all.count == 1 })
        #expect(poster.posted.all.first?.body == "Bob: new one")

        await session.setFocus(space)
        server.advance(.seconds(1))
        server.post("while looking", in: space, from: .account(bob))
        server.advance(.seconds(5))
        #expect(await poll { ((try? session.messages(in: space)) ?? []).contains { $0.text == "while looking" } })
        try await Task.sleep(for: .milliseconds(100))
        #expect(poster.posted.all.count == 1)

        await session.setAppActive(false)
        server.advance(.seconds(1))
        server.post("while away", in: space, from: .account(bob))
        server.advance(.seconds(5))
        #expect(await poll { poster.posted.all.count == 2 })
        #expect(poster.posted.all.last?.body == "Bob: while away")

        recorder.cancel()
        _ = await session.logout(refreshToken: nil)
    }
}
