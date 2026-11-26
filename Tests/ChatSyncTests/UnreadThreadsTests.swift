import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

/// A team space with `threads` threads, each holding one reply from Bob that Alice hasn't read yet. The session is
/// never started, so its only tasks are the ones a test asks for.
struct UnreadThreadsRig: Sendable {
    let world: SimWorld
    let server: FakeChatServer
    let alice: FakeAccount
    let bob: FakeAccount
    let team: SpaceName
    let threads: [ThreadName]
    let roots: [Message]
    let replies: [Message]
    let barrier: Barrier
    let log = CallLog()
    let session: AccountSession
    let work: WorkRegistry
    let generation: Generation
    let snapshots: SnapshotRecorder

    init(_ world: SimWorld, threads count: Int, readUpToReply: Bool = false, muted: Bool = false) async throws {
        self.world = world
        server = world.server
        alice = server.addAccount(displayName: "Alice")
        bob = server.addAccount(displayName: "Bob")
        team = server.addSpace(.space, displayName: "Team", members: [alice, bob])
        var threads: [ThreadName] = []
        var roots: [Message] = []
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
            roots.append(root)
            replies.append(reply)
        }
        self.threads = threads
        self.roots = roots
        self.replies = replies
        // Every top-level message is read, so only replies count.
        server.setReadState(alice, space: team, lastReadTime: server.now)
        if muted {
            server.setNotificationSetting(alice, space: team, SpaceNotificationSetting(level: .off, isMuted: true))
        }

        barrier = world.barrier()
        let clock = world.clock()
        session = world.syncSession(
            alice, api: BarrierAPI(base: world.syncClient(alice), barrier: barrier, log: log, clock: clock),
            clock: clock)
        work = await session.work
        snapshots = SnapshotRecorder(session.snapshots.values, in: world)
        generation = try #require(session.gate.current)
        _ = try await session.engine.syncSpaces(generation)
        try await session.engine.syncMessages(team, generation)
        if muted { try await session.engine.syncNotificationSetting(team, generation) }
    }

    static func run(
        threads: Int, readUpToReply: Bool = false, muted: Bool = false,
        _ body: @escaping @Sendable (UnreadThreadsRig) async throws -> Void
    ) async throws {
        try await SimWorld.run { world in
            try await body(UnreadThreadsRig(world, threads: threads, readUpToReply: readUpToReply, muted: muted))
        }
    }

    /// Focuses the space and runs the first focus tick to its end.
    func focus() async throws {
        await session.setFocus(team)
        await world.settle()
        try #require(work.count == 0, "the first focus tick ended")
    }

    func tick() async { await session.focusTick(team, generation) }

    /// Starts a check of the due threads and runs it to the barrier, where its first answer waits.
    func heldDiscovery() async throws -> SimTask<Result<Void, SyncError>> {
        barrier.arm()
        let (session, team, generation) = (session, team, generation)
        let discovery = world.start { await session.discoverThreadReads(team, generation) }
        await world.settle()
        try #require(barrier.arrivals == 1 && !discovery.isFinished, "the first lookup is held")
        return discovery
    }

    func finish(_ discovery: SimTask<Result<Void, SyncError>>) async throws -> Result<Void, SyncError> {
        barrier.release()
        await world.settle()
        try #require(discovery.isFinished)
        return await discovery.value
    }

    /// The newest snapshot, which at a settled point is the last one the session published.
    func latestSnapshot() async throws -> AccountSnapshot {
        await world.settle()
        let latest = try #require(snapshots.latest)
        try #require(await latest.revision == session.revision)
        return latest
    }

    var lookups: Int { log.count("getThreadReadState") }

    func unreadCount() throws -> Int { try session.unread(in: team).messages.count }
}

struct UnreadThreadsTests {
    @Test func theFirstTickChecksThreadsThatWereNeverShown() async throws {
        try await UnreadThreadsRig.run(threads: 3) { rig in
            try await rig.focus()
            #expect(rig.lookups == 3)
            #expect(try rig.unreadCount() == 3)

            await rig.tick()
            #expect(rig.lookups == 3, "a checked thread waits out its recheck interval")
        }
    }

    @Test func aThreadWithNoReadTimeIsCheckedAgainOnlyAfterTheInterval() async throws {
        try await UnreadThreadsRig.run(threads: 1) { rig in
            rig.server.setThreadReadState(rig.alice, thread: rig.threads[0], lastReadTime: nil)
            try await rig.focus()
            #expect(rig.lookups == 1)
            await rig.tick()
            #expect(rig.lookups == 1)

            rig.server.advance(AccountSession.threadReadRecheck + .seconds(1))
            await rig.tick()
            #expect(rig.lookups == 2)
        }
    }

    @Test func manyThreadsAreCheckedAFewPerTickAndTheSpaceStaysPendingUntilDone() async throws {
        try await UnreadThreadsRig.run(threads: 8) { rig in
            try await rig.focus()
            #expect(rig.lookups == AccountSession.threadReadDiscoveryBudget)
            #expect(try await rig.latestSnapshot().discoveringSpaces == [rig.team])
            #expect(try rig.unreadCount() == 5)

            await rig.tick()
            #expect(rig.lookups == 8)
            #expect(try rig.unreadCount() == 8)
            #expect(try await rig.latestSnapshot().discoveringSpaces == [])
        }
    }

    @Test func aRateLimitKeepsTheChecksThatAlreadyFinished() async throws {
        try await UnreadThreadsRig.run(threads: 1) { rig in
            try await rig.focus()
            // Two threads due again; the first answers, the second is rate limited.
            let extra = rig.server.post("root extra", in: rig.team, from: .account(rig.bob))
            let thread = try #require(extra.thread)
            rig.server.advance(.seconds(5))
            _ = rig.server.post("reply extra", in: rig.team, from: .account(rig.bob), thread: thread)
            rig.server.advance(AccountSession.threadReadRecheck + .seconds(1))
            try await rig.session.engine.syncMessages(rig.team, rig.generation)

            let discovery = try await rig.heldDiscovery()
            rig.server.fail(
                FailureRule(
                    account: rig.alice, route: .getThreadReadState, times: 1,
                    response: .http(status: 429, googleStatus: "RESOURCE_EXHAUSTED", retryAfterSeconds: 30)))
            guard case .failure(.api(.rateLimited, _)) = try await rig.finish(discovery) else {
                Issue.record("the rate limit didn't reach the session")
                return
            }
            #expect(await rig.session.threadReadsChecked.count == 2, "the answered thread stays checked")
        }
    }

    @Test func overlappingTicksRunOneBatch() async throws {
        try await UnreadThreadsRig.run(threads: 2) { rig in
            try await rig.focus()
            rig.server.advance(AccountSession.threadReadRecheck + .seconds(1))
            let before = rig.lookups

            let first = try await rig.heldDiscovery()
            // A second batch of its own would skip the held thread and look the other one up.
            let (session, team, generation) = (rig.session, rig.team, rig.generation)
            let second = rig.world.start { await session.discoverThreadReads(team, generation) }
            await rig.world.settle()
            #expect(second.isFinished, "the overlapping tick returns at once")
            #expect(rig.barrier.arrivals == 1)
            #expect(rig.lookups == before + 1)

            _ = try await rig.finish(first)
            #expect(rig.lookups == before + 2, "each thread was looked up once")
        }
    }

    @Test func readsAndMarkUnreadOnAnotherClientShowUpAfterTheInterval() async throws {
        try await UnreadThreadsRig.run(threads: 1, readUpToReply: true) { rig in
            try await rig.focus()
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
    }

    @Test func aThreadOpenedDuringItsCheckIsSavedBeforeTheNextCheck() async throws {
        try await UnreadThreadsRig.run(threads: 2) { rig in
            try await rig.focus()
            rig.server.advance(AccountSession.threadReadRecheck + .seconds(1))
            let opened = rig.threads[1]
            let reply = rig.replies[1]

            // The newest reply's thread comes first, so it's the one being checked now.
            let discovery = try await rig.heldDiscovery()
            await rig.session.setFocus(rig.team, threadRead: ThreadReadPosition(thread: opened, upTo: reply.createTime))
            await rig.world.settle()
            // The save found the thread held by the check and gave up without a call.
            #expect(rig.work.count == 0)
            #expect(rig.barrier.arrivals == 1)
            #expect(rig.server.threadReadState(rig.alice, thread: opened) == rig.roots[1].createTime)

            _ = try await rig.finish(discovery)
            #expect(rig.server.threadReadState(rig.alice, thread: opened) == reply.createTime)
        }
    }

    @Test func messagesThisAccountCantReadDontStopTheTick() async throws {
        try await UnreadThreadsRig.run(threads: 1) { rig in
            try await rig.focus()
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
            #expect(try await rig.latestSnapshot().status == .ok)
        }
    }

    @Test func aMutedSpaceMakesNoExtraCalls() async throws {
        try await UnreadThreadsRig.run(threads: 3, muted: true) { rig in
            try await rig.focus()
            #expect(rig.log.count("getSpaceReadState") >= 1, "the focus tick ran")
            #expect(rig.lookups == 0)
        }
    }

    @Test func thePendingSpaceIsPublishedBeforeTheCheckAndClearedAfter() async throws {
        try await UnreadThreadsRig.run(threads: 1) { rig in
            try await rig.focus()
            #expect(try await rig.latestSnapshot().discoveringSpaces == [])
            rig.server.advance(AccountSession.threadReadRecheck + .seconds(1))

            let discovery = try await rig.heldDiscovery()
            #expect(try await rig.latestSnapshot().discoveringSpaces == [rig.team])
            _ = try await rig.finish(discovery)
            #expect(await rig.session.discoveringSpace == nil)
        }
    }
}

struct UnreadReactionsTests {
    @Test func reactionsOnAMessageThisAccountCantReadAreSkipped() async throws {
        try await UnreadThreadsRig.run(threads: 1) { rig in
            rig.server.fail(
                FailureRule(
                    account: rig.alice, route: .listReactions, times: nil,
                    response: .http(status: 403, googleStatus: "PERMISSION_DENIED")))
            try await rig.session.reactions.refreshMine([rig.replies[0].name], rig.generation)
            #expect(rig.log.count("listReactions") == 1)
        }
    }
}
