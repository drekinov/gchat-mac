import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

/// A team space with `threads` threads, each holding one reply from Bob that Alice hasn't read yet.
struct UnreadThreadsRig {
    let server = FakeChatServer()
    let alice: FakeAccount
    let bob: FakeAccount
    let team: SpaceName
    let threads: [ThreadName]
    let replies: [Message]
    let barrier = Barrier()
    let log = CallLog()
    let scratch = ScratchDirectory()
    let session: AccountSession
    let generation: Generation
    let snapshots: SnapshotRecorder

    init(threads count: Int, readUpToReply: Bool = false, muted: Bool = false) async throws {
        alice = server.addAccount(displayName: "Alice")
        bob = server.addAccount(displayName: "Bob")
        team = server.addSpace(.space, displayName: "Team", members: [alice, bob])
        var threads: [ThreadName] = []
        var replies: [Message] = []
        for index in 0..<count {
            let root = server.post("root \(index)", in: team, from: .account(bob))
            let thread = try #require(root.thread)
            server.advance(.seconds(5))
            let reply = server.post("reply \(index)", in: team, from: .account(bob), thread: thread)
            server.advance(.seconds(5))
            server.setThreadReadState(
                alice, thread: thread, lastReadTime: readUpToReply ? reply.createTime : root.createTime)
            threads.append(thread)
            replies.append(reply)
        }
        self.threads = threads
        self.replies = replies
        // Every top-level message is read, so only replies count.
        server.setReadState(alice, space: team, lastReadTime: server.now)
        if muted {
            server.setNotificationSetting(alice, space: team, SpaceNotificationSetting(level: .off, isMuted: true))
        }

        let clock = ServerClock(server: server)
        let client = GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token))
        var timing = SessionTiming.fast
        timing.focusInterval = 600...600
        session = AccountSession(
            account: AccountID(), me: alice.user.name,
            api: BarrierAPI(base: client, barrier: barrier, log: log, clock: clock),
            store: InMemoryAccountStore(), clock: clock,
            logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: scratch.url)),
            timing: timing)
        snapshots = SnapshotRecorder(session.snapshots.values)
        generation = try #require(session.gate.current)
        _ = try await session.engine.syncSpaces(generation)
        try await session.engine.syncMessages(team, generation)
        if muted { try await session.engine.syncNotificationSetting(team, generation) }
    }

    /// Focuses the space and waits for the first focus tick to end.
    func focus() async {
        await session.setFocus(team)
        let work = await session.work
        _ = await poll { work.count == 0 }
    }

    func tick() async { await session.focusTick(team, generation) }

    /// The newest snapshot, once the recorder has caught up with everything the session published.
    func latestSnapshot() async -> AccountSnapshot? {
        let revision = await session.revision
        return await snapshots.wait { $0.revision == revision }
    }

    var lookups: Int { log.count("getThreadReadState") }

    func unreadCount() throws -> Int { try session.unread(in: team).messages.count }
}

struct UnreadThreadsTests {
    @Test func theFirstTickChecksThreadsThatWereNeverShown() async throws {
        let rig = try await UnreadThreadsRig(threads: 3)
        await rig.focus()
        #expect(rig.lookups == 3)
        #expect(try rig.unreadCount() == 3)

        await rig.tick()
        #expect(rig.lookups == 3, "a checked thread waits out its recheck interval")
    }

    @Test func aThreadWithNoReadTimeIsCheckedAgainOnlyAfterTheInterval() async throws {
        let rig = try await UnreadThreadsRig(threads: 1)
        rig.server.setThreadReadState(rig.alice, thread: rig.threads[0], lastReadTime: nil)
        await rig.focus()
        #expect(rig.lookups == 1)
        await rig.tick()
        #expect(rig.lookups == 1)

        rig.server.advance(AccountSession.threadReadRecheck + .seconds(1))
        await rig.tick()
        #expect(rig.lookups == 2)
    }

    @Test func manyThreadsAreCheckedAFewPerTickAndTheSpaceStaysPendingUntilDone() async throws {
        let rig = try await UnreadThreadsRig(threads: 8)
        await rig.focus()
        #expect(rig.lookups == AccountSession.threadReadDiscoveryBudget)
        #expect(await rig.latestSnapshot()?.discoveringSpaces == [rig.team])
        #expect(try rig.unreadCount() == 5)

        await rig.tick()
        #expect(rig.lookups == 8)
        #expect(try rig.unreadCount() == 8)
        #expect(await rig.latestSnapshot()?.discoveringSpaces == [])
    }

    @Test func aRateLimitKeepsTheChecksThatAlreadyFinished() async throws {
        let rig = try await UnreadThreadsRig(threads: 1)
        await rig.focus()
        // Two threads due again; the first answers, the second is rate limited.
        let extra = rig.server.post("root extra", in: rig.team, from: .account(rig.bob))
        let thread = try #require(extra.thread)
        rig.server.advance(.seconds(5))
        _ = rig.server.post("reply extra", in: rig.team, from: .account(rig.bob), thread: thread)
        rig.server.advance(AccountSession.threadReadRecheck + .seconds(1))
        try await rig.session.engine.syncMessages(rig.team, rig.generation)

        rig.barrier.arm()
        let discovery = Task { await rig.session.discoverThreadReads(rig.team, rig.generation) }
        #expect(await rig.barrier.waitForArrival())
        rig.server.fail(
            FailureRule(
                account: rig.alice, route: .getThreadReadState, times: 1,
                response: .http(status: 429, googleStatus: "RESOURCE_EXHAUSTED", retryAfterSeconds: 30)))
        rig.barrier.release()
        guard case .failure(.api(.rateLimited, _)) = await discovery.value else {
            Issue.record("the rate limit didn't reach the session")
            return
        }
        #expect(await rig.session.threadReadsChecked.count == 2, "the answered thread stays checked")
    }

    @Test func overlappingTicksRunOneBatch() async throws {
        let rig = try await UnreadThreadsRig(threads: 1)
        await rig.focus()
        rig.server.advance(AccountSession.threadReadRecheck + .seconds(1))
        let before = rig.lookups

        rig.barrier.arm()
        let first = Task { await rig.session.discoverThreadReads(rig.team, rig.generation) }
        #expect(await rig.barrier.waitForArrival())
        _ = await rig.session.discoverThreadReads(rig.team, rig.generation)
        rig.barrier.release()
        _ = await first.value
        #expect(rig.lookups == before + 1)
    }

    @Test func readsAndMarkUnreadOnAnotherClientShowUpAfterTheInterval() async throws {
        let rig = try await UnreadThreadsRig(threads: 1, readUpToReply: true)
        await rig.focus()
        #expect(try rig.unreadCount() == 0)

        rig.server.setThreadReadState(rig.alice, thread: rig.threads[0], lastReadTime: Timestamp(seconds: 1))
        rig.server.advance(AccountSession.threadReadRecheck + .seconds(1))
        await rig.tick()
        #expect(try rig.unreadCount() == 1, "marked unread elsewhere")

        rig.server.setThreadReadState(rig.alice, thread: rig.threads[0], lastReadTime: rig.replies[0].createTime)
        rig.server.advance(AccountSession.threadReadRecheck + .seconds(1))
        await rig.tick()
        #expect(try rig.unreadCount() == 0, "read elsewhere")
    }

    @Test func aThreadOpenedDuringItsCheckIsSavedBeforeTheNextCheck() async throws {
        let rig = try await UnreadThreadsRig(threads: 2)
        await rig.focus()
        rig.server.advance(AccountSession.threadReadRecheck + .seconds(1))
        let opened = rig.threads[1]
        let reply = rig.replies[1]

        rig.barrier.arm()
        let discovery = Task { await rig.session.discoverThreadReads(rig.team, rig.generation) }
        #expect(await rig.barrier.waitForArrival())
        // The newest reply's thread comes first, so it's the one being checked now.
        await rig.session.setFocus(rig.team, threadRead: ThreadReadPosition(thread: opened, upTo: reply.createTime))
        rig.barrier.release()
        _ = await discovery.value
        #expect(rig.server.threadReadState(rig.alice, thread: opened) == reply.createTime)
    }

    @Test func messagesThisAccountCantReadDontStopTheTick() async throws {
        let rig = try await UnreadThreadsRig(threads: 1)
        await rig.focus()
        _ = rig.server.react(rig.replies[0].name, emoji: .unicode("👍"), by: .account(rig.bob))
        rig.server.fail(
            FailureRule(
                account: rig.alice, route: .getMessage, times: nil,
                response: .http(status: 403, googleStatus: "PERMISSION_DENIED")))
        rig.server.fail(
            FailureRule(
                account: rig.alice, route: .listReactions, times: nil,
                response: .http(status: 403, googleStatus: "PERMISSION_DENIED")))
        rig.server.advance(AccountSession.threadReadRecheck + .seconds(1))
        let before = rig.lookups

        await rig.tick()
        #expect(rig.lookups == before + 1, "thread read times are still checked")
        #expect(await rig.latestSnapshot()?.status == .ok)
    }

    @Test func aMutedSpaceMakesNoExtraCalls() async throws {
        let rig = try await UnreadThreadsRig(threads: 3, muted: true)
        await rig.focus()
        #expect(rig.lookups == 0)
    }

    @Test func thePendingSpaceIsPublishedBeforeTheCheckAndClearedAfter() async throws {
        let rig = try await UnreadThreadsRig(threads: 1)
        await rig.focus()
        #expect(await rig.latestSnapshot()?.discoveringSpaces == [])
        rig.server.advance(AccountSession.threadReadRecheck + .seconds(1))
        let mark = rig.snapshots.history.count

        rig.barrier.arm()
        let discovery = Task { await rig.session.discoverThreadReads(rig.team, rig.generation) }
        #expect(await rig.barrier.waitForArrival())
        #expect(await rig.snapshots.wait(since: mark) { $0.discoveringSpaces == [rig.team] } != nil)
        rig.barrier.release()
        _ = await discovery.value
        #expect(await rig.session.discoveringSpace == nil)
    }
}

struct UnreadReactionsTests {
    @Test func reactionsOnAMessageThisAccountCantReadAreSkipped() async throws {
        let rig = try await UnreadThreadsRig(threads: 1)
        rig.server.fail(
            FailureRule(
                account: rig.alice, route: .listReactions, times: nil,
                response: .http(status: 403, googleStatus: "PERMISSION_DENIED")))
        try await rig.session.reactions.refreshMine([rig.replies[0].name], rig.generation)
        #expect(rig.log.count("listReactions") == 1)
    }
}
