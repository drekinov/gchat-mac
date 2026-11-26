import ChatKeychain
import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatSync

/// One session in a simulated world: a sidebar tick runs only when the test moves time to its deadline or
/// something resets the schedule.
struct ConnectivityRig: Sendable {
    let world: SimWorld
    let server: FakeChatServer
    let alice: FakeAccount
    let space: SpaceName
    let store = InMemoryAccountStore()
    let barrier: Barrier
    let calls = CallLog()
    let scratch = ScratchDirectory()
    let timing: SessionTiming
    let session: AccountSession
    let recorder: SnapshotRecorder

    static func run(
        timing: SessionTiming = .lifecycle, _ body: @escaping @Sendable (ConnectivityRig) async throws -> Void
    ) async throws {
        try await SimWorld.run { world in try await body(ConnectivityRig(world, timing: timing)) }
    }

    init(_ world: SimWorld, timing: SessionTiming = .lifecycle) {
        self.world = world
        self.timing = timing
        server = world.server
        alice = server.addAccount(displayName: "Alice")
        space = server.addSpace(.space, displayName: "Team", members: [alice])
        server.post("hello", in: space, from: .user(User(name: UserName(unchecked: "users/42"), displayName: "Zed")))
        server.advance(.seconds(5))
        let clock = world.clock()
        barrier = world.barrier()
        let api = BarrierAPI(
            base: GoogleChatClient(transport: world.transport(), tokens: StaticTokens(token: alice.token)),
            barrier: barrier, log: calls, clock: clock)
        session = AccountSession(
            account: AccountID(), me: alice.user.name, api: api, store: store, clock: clock,
            logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: scratch.url)),
            timing: timing, executor: world.executor)
        recorder = SnapshotRecorder(session.snapshots.values, in: world)
        world.lifecycleRetireAtTeardown(session)
    }

    /// Starts the session and runs to the end of its first sidebar sync, with the next tick scheduled.
    func startAndSync() async -> Bool {
        await session.start()
        let space = space
        let synced = await recorder.wait(in: world) { $0.status == .ok && $0.spaces.contains { $0.name == space } }
        await world.settle()
        return synced != nil
    }

    var lists: Int { calls.count("listSpaces") }
    var creates: Int { calls.count("createMessage") }
    var status: AccountStatus? { recorder.latest?.status }

    func posted(_ text: String) -> Bool { server.messages(in: space).contains { $0.text == text } }

    /// Moves time to the scheduled sidebar tick and runs it; false when none is scheduled.
    func runNextTick() async -> Bool {
        await world.settle()
        guard let next = await session.nextSidebar else { return false }
        await world.jump(to: next)
        return true
    }

    /// Answers the next sidebar tick with a rate limit and returns the retry deadline the session took from it.
    func rateLimitTheNextTick(retryAfter: Int = 30) async -> Timestamp? {
        server.fail(.rateLimited(route: .listSpaces, retryAfter: retryAfter))
        guard await runNextTick(), let deadline = await session.retryUntil else { return nil }
        return status == .backingOff(until: deadline) ? deadline : nil
    }

    /// A loop that goes round again with nothing due pauses a millisecond first. The bound stays below the shortest
    /// backoff (1 s), so work that waited for one doesn't count.
    func afterTheLoopsPause(_ condition: () async -> Bool) async -> Bool {
        await world.run(upTo: .milliseconds(100), until: condition)
    }

    /// Lets time pass up to the last instant before `deadline`.
    func runToJustBefore(_ deadline: Timestamp) async {
        await world.pass(deadline.interval(since: world.now) - .nanoseconds(1))
    }

    /// Long enough for a loop with nothing due to come round several times.
    func passSeveralIdleRounds() async { await world.pass(timing.idleSleep * 3) }
}

final class AdmissionSwitch: Sendable {
    private let open = Mutex(true)

    func close() { open.withLock { $0 = false } }
    var isOpen: Bool { open.withLock { $0 } }
}

struct ConnectivityTests {
    @Test func aWakeWhileOfflineOnlyMarksTheCatchUpAndItRunsOnReconnect() async throws {
        try await ConnectivityRig.run { rig in
            #expect(await rig.startAndSync())
            let restarts = Recorder<Int>()
            await rig.session.setEventChannelRestart { restarts.append(1) }
            await rig.session.setConnectivity(.unreachable)
            await rig.world.settle()
            let before = rig.server.requests.count

            await rig.session.systemDidWake()
            await rig.passSeveralIdleRounds()

            #expect(rig.server.requests.count == before, "a wake while offline sent requests")
            #expect(await rig.session.catchUpPending)
            #expect(rig.status == .offline)
            #expect(restarts.all.isEmpty)

            let lists = rig.lists
            await rig.session.setConnectivity(.reachable)
            await rig.world.settle()
            #expect(restarts.all.count == 1, "the catch-up waited for the next interval")
            #expect(rig.lists == lists + 1)
            #expect(await rig.session.catchUpPending == false)
            #expect(rig.status == .ok)
        }
    }

    @Test func aReconnectDuringAnInFlightTickRunsAFreshTickOnce() async throws {
        try await ConnectivityRig.run { rig in
            #expect(await rig.startAndSync())
            let restarts = Recorder<Int>()
            let calls = rig.calls
            await rig.session.setEventChannelRestart { restarts.append(calls.count("listSpaces")) }
            let lists = rig.lists
            rig.barrier.arm()
            #expect(await rig.runNextTick())
            try #require(rig.barrier.arrivals == 1)
            #expect(rig.lists == lists + 1)

            await rig.session.setConnectivity(.unreachable)
            await rig.session.setConnectivity(.reachable)
            rig.barrier.release()

            #expect(await rig.afterTheLoopsPause { !restarts.all.isEmpty }, "the in-flight tick overwrote the reset")
            #expect(restarts.all == [lists + 2], "the catch-up ends on a tick that began after the reconnect")
            #expect(rig.lists == lists + 2)
            #expect(await rig.session.catchUpPending == false)

            let next = try #require(await rig.session.nextSidebar)
            #expect(next == rig.world.now.adding(rig.timing.sidebarInterval))
            await rig.runToJustBefore(next)
            #expect(rig.lists == lists + 2, "the catch-up kept polling before the next interval")
            await rig.world.jump(to: next)
            #expect(rig.lists == lists + 3)
            #expect(restarts.all.count == 1)
        }
    }

    @Test func anOfflineSendIsNotAttemptedAndDrainsOnReconnect() async throws {
        try await ConnectivityRig.run { rig in
            #expect(await rig.startAndSync())
            await rig.session.setConnectivity(.unreachable)

            let item = try await rig.session.send("while away", in: rig.space, thread: nil)
            await rig.passSeveralIdleRounds()

            #expect(await rig.session.blockedDrains == [rig.space])
            #expect(rig.creates == 0)
            let held = try #require(try rig.session.outbox(in: rig.space).first)
            #expect(held.id == item.id && held.state == .queued && held.attempts == 0)

            await rig.session.setConnectivity(.reachable)
            await rig.world.settle()
            #expect(rig.posted("while away"))
            #expect(try rig.session.outbox(in: rig.space).isEmpty)
            #expect(await rig.session.blockedDrains.isEmpty)
            #expect(rig.creates == 1)
        }
    }

    @Test func aReconnectKeepsARateLimitDeadlineThatOverlapsTheOfflinePeriod() async throws {
        try await ConnectivityRig.run { rig in
            #expect(await rig.startAndSync())
            let deadline = try #require(await rig.rateLimitTheNextTick(retryAfter: 30))
            #expect(deadline == rig.world.now.adding(.seconds(30)))
            let lists = rig.lists

            await rig.session.setConnectivity(.unreachable)
            await rig.session.setConnectivity(.reachable)
            await rig.world.settle()
            #expect(rig.world.sleeperDeadlines == [deadline], "the loop waits for the deadline in a single sleep")
            await rig.runToJustBefore(deadline)

            #expect(await rig.session.retryUntil == deadline)
            #expect(await rig.session.offlineUntil == nil)
            #expect(rig.lists == lists, "the reconnect polled through a server retry deadline")
            #expect(rig.status == .backingOff(until: deadline))
            #expect(await rig.session.catchUpPending, "the catch-up waits for the deadline")

            await rig.world.jump(to: deadline)
            #expect(rig.status == .ok)
            #expect(rig.lists == lists + 1)
            #expect(await rig.session.catchUpPending == false)
        }
    }

    @Test func aSendHeldByARateLimitOnAHealthyPathDrainsWhenTheDeadlineExpires() async throws {
        try await ConnectivityRig.run { rig in
            #expect(await rig.startAndSync())
            let deadline = try #require(await rig.rateLimitTheNextTick())

            try await rig.session.send("patient", in: rig.space, thread: nil)
            await rig.runToJustBefore(deadline)
            #expect(await rig.session.blockedDrains == [rig.space])
            #expect(rig.creates == 0)

            await rig.world.jump(to: deadline)
            #expect(rig.posted("patient"))
            #expect(rig.creates == 1)
            #expect(await rig.session.blockedDrains.isEmpty)
        }
    }

    @Test func aStaleOfflineResultFromBeforeAReconnectIsIgnored() async throws {
        try await ConnectivityRig.run { rig in
            #expect(await rig.startAndSync())
            rig.server.fail(.networkError(.notConnectedToInternet, route: .listSpaces))
            rig.barrier.arm()
            #expect(await rig.runNextTick())
            try #require(rig.barrier.arrivals == 1)

            await rig.session.setConnectivity(.unreachable)
            await rig.session.setConnectivity(.reachable)
            let lists = rig.lists
            rig.barrier.release()

            #expect(await rig.afterTheLoopsPause { rig.lists > lists }, "the stale result blocked the catch-up")
            #expect(rig.lists == lists + 1)
            #expect(await rig.session.offlineUntil == nil, "the stale offline result was applied after the reconnect")
            #expect(await rig.session.offlineFailures == 0)
            #expect(await rig.session.status == .ok)
            #expect(await rig.session.catchUpPending == false)
        }
    }

    @Test func aSendThatFindsTheNetworkOfflineRetriesWhenTheOfflineBackoffEnds() async throws {
        var timing = SessionTiming.lifecycle
        timing.sidebarInterval = .seconds(3600)
        timing.idleSleep = .seconds(3600)
        try await ConnectivityRig.run(timing: timing) { rig in
            #expect(await rig.startAndSync())
            rig.server.fail(.networkError(.notConnectedToInternet, route: .createMessage))

            try await rig.session.send("bounced", in: rig.space, thread: nil)
            await rig.world.settle()
            #expect(rig.status == .offline)
            let until = try #require(await rig.session.offlineUntil)
            #expect(until > rig.world.now)
            #expect(rig.creates == 1)

            await rig.runToJustBefore(until)
            #expect(rig.creates == 1)
            #expect(!rig.posted("bounced"))

            await rig.world.jump(to: until)
            #expect(rig.posted("bounced"))
            #expect(rig.creates == 2)
        }
    }

    @Test func aCurrentOfflineResultStillBacksOff() async throws {
        try await ConnectivityRig.run { rig in
            #expect(await rig.startAndSync())
            let lists = rig.lists
            rig.server.fail(.networkError(.notConnectedToInternet, route: .listSpaces))
            #expect(await rig.runNextTick())

            #expect(rig.status == .offline)
            let until = try #require(await rig.session.offlineUntil)
            #expect(until > rig.world.now)
            #expect(await rig.session.retryUntil == nil)
            #expect(rig.lists == lists + 1)

            await rig.runToJustBefore(until)
            #expect(rig.lists == lists + 1, "the session polled inside its offline backoff")
            #expect(rig.status == .offline)

            #expect(await rig.world.run(upTo: rig.timing.sidebarInterval) { rig.status == .ok })
            #expect(rig.lists == lists + 2)
            #expect(await rig.session.offlineUntil == nil)
        }
    }

    @Test func aNewSessionStartsWithTheManagersCurrentPathState() async throws {
        try await SimWorld.run { world in
            let server = world.server
            let alice = server.addAccount(displayName: "Alice")
            let scratch = ScratchDirectory()
            let secrets = InMemorySecretStore()
            let tombstones = LogoutTombstones(root: scratch.url)
            let runner = LogoutRunner(eraser: NoopEraser(), tombstones: tombstones)
            let timing = SessionTiming.lifecycle
            let manager = AccountManager(
                registry: AccountRegistry(secrets: secrets), recovery: LogoutRecovery(runner: runner),
                tombstones: tombstones
            ) { record in
                let session = AccountSession(
                    account: record.id, me: record.me,
                    api: GoogleChatClient(transport: world.transport(), tokens: StaticTokens(token: alice.token)),
                    store: InMemoryAccountStore(), clock: world.clock(), logoutRunner: runner, timing: timing,
                    executor: world.executor)
                world.lifecycleRetireAtTeardown(session)
                return session
            }

            await manager.setConnectivity(.unreachable)
            let session = try await manager.add(
                AccountRecord(email: "alice@example.com", displayName: "Alice", me: alice.user.name))
            await world.pass(timing.idleSleep * 3)

            #expect(await session.reachable == false)
            #expect(await session.admitted == false)
            #expect(server.requests.isEmpty, "a session created offline sent requests")

            await manager.setConnectivity(.reachable)
            #expect(await session.reachable)
            await world.settle()
            #expect(await session.status == .ok)
            #expect(!server.requests.isEmpty)
            try await world.lifecycleLogout(session)
        }
    }

    @Test func aSendFailingDuringTheCatchUpLetsTheCatchUpRerunOnceAdmissionReopens() async throws {
        var timing = SessionTiming.lifecycle
        timing.sidebarInterval = .seconds(3600)
        timing.inactiveSidebarInterval = .seconds(3600)
        timing.idleSleep = .seconds(3600)
        try await ConnectivityRig.run(timing: timing) { rig in
            #expect(await rig.startAndSync())
            let restarts = Recorder<Int>()
            await rig.session.setEventChannelRestart { restarts.append(1) }
            await rig.session.setConnectivity(.unreachable)
            let generation = try #require(rig.session.gate.current)
            _ = try await rig.session.sends.enqueue(text: "queued offline", space: rig.space, thread: nil, generation)
            rig.server.fail(.networkError(.notConnectedToInternet, route: .createMessage))

            let lists = rig.lists
            await rig.session.setConnectivity(.reachable)
            await rig.world.settle()
            #expect(rig.creates == 1)
            #expect(rig.lists == lists + 1)
            let until = try #require(await rig.session.offlineUntil)
            #expect(await rig.session.catchUpPending)
            #expect(restarts.all.isEmpty)

            await rig.runToJustBefore(until)
            #expect(rig.lists == lists + 1)
            #expect(await rig.session.catchUpPending)
            #expect(restarts.all.isEmpty)

            await rig.world.jump(to: until)
            #expect(rig.lists == lists + 2, "the catch-up waited for the next interval")
            #expect(await rig.session.catchUpPending == false)
            #expect(restarts.all.count == 1)
            #expect(rig.posted("queued offline"))
        }
    }

    @Test(arguments: [true, false])
    func aLoginRequirementSurvivesTransportErrorsInEitherOrder(_ authFirst: Bool) async throws {
        try await ConnectivityRig.run { rig in
            #expect(await rig.startAndSync())
            let lists = rig.lists
            let generation = try #require(rig.session.gate.current)
            let epoch = await rig.session.connectivityEpoch
            let offline = SyncError.api(.transport(.offline), .listSpaces)
            let unauthorized = SyncError.api(.unauthorized, .listSpaces)
            let limited = SyncError.api(.rateLimited(retryAfter: .seconds(1)), .listSpaces)
            for error in authFirst ? [unauthorized, offline, limited] : [offline, limited, unauthorized] {
                await rig.session.handle(error, generation, epoch: epoch)
            }
            await rig.session.setConnectivity(.unreachable)
            await rig.session.setConnectivity(.reachable)
            await rig.passSeveralIdleRounds()

            #expect(await rig.session.status == .needsLogin)
            #expect(await rig.session.admitted == false)
            #expect(rig.lists == lists, "a cleared deadline reopened admission while signed out")
            #expect(await rig.session.offlineUntil == nil)
            let retryUntil = await rig.session.retryUntil
            #expect(retryUntil.map { $0 < rig.world.now } == true, "the retry deadline has passed")

            await rig.session.resumeAfterLogin()
            #expect(await rig.session.admitted)
            await rig.world.settle()
            #expect(rig.lists == lists + 1)
            #expect(rig.status == .ok)
        }
    }

    @Test func theBackgroundCadenceIsFasterUnlessTheEventChannelIsLive() {
        let timing = SessionTiming()
        #expect(timing.sidebarInterval(appActive: true, liveChannel: false) == .seconds(60))
        #expect(timing.sidebarInterval(appActive: true, liveChannel: true) == .seconds(60))
        #expect(timing.sidebarInterval(appActive: false, liveChannel: false) == .seconds(30))
        #expect(timing.sidebarInterval(appActive: false, liveChannel: true) == .seconds(120))
    }

    @Test func goingInactivePullsTheNextSidebarTickIn() async throws {
        var timing = SessionTiming.lifecycle
        timing.sidebarInterval = .seconds(600)
        timing.inactiveSidebarInterval = .seconds(30)
        timing.liveSidebarInterval = .seconds(120)
        timing.idleSleep = .seconds(3600)
        try await ConnectivityRig.run(timing: timing) { rig in
            #expect(await rig.startAndSync())
            let start = rig.world.now
            let lists = rig.lists
            #expect(await rig.session.nextSidebar == start.adding(.seconds(600)))

            await rig.session.setAppActive(false)

            let next = try #require(await rig.session.nextSidebar)
            #expect(next == start.adding(.seconds(30)))
            await rig.session.setLiveChannel(true)
            await rig.session.setAppActive(false)
            #expect(await rig.session.nextSidebar == next, "a slower live cadence never pushes a due tick out")

            await rig.runToJustBefore(next)
            #expect(rig.lists == lists)
            await rig.world.jump(to: next)
            #expect(rig.lists == lists + 1, "the loop slept on to the deadline it had before")
            #expect(await rig.session.nextSidebar == next.adding(.seconds(120)))
        }
    }

    @Test func losingTheLiveChannelPullsTheNextSidebarTickIn() async throws {
        var timing = SessionTiming.lifecycle
        timing.sidebarInterval = .seconds(600)
        timing.inactiveSidebarInterval = .seconds(30)
        timing.liveSidebarInterval = .seconds(120)
        timing.idleSleep = .seconds(3600)
        try await ConnectivityRig.run(timing: timing) { rig in
            #expect(await rig.startAndSync())
            let start = rig.world.now
            let lists = rig.lists
            await rig.session.setLiveChannel(true)
            await rig.session.setAppActive(false)
            #expect(await rig.session.nextSidebar == start.adding(.seconds(120)))
            await rig.world.settle()
            #expect(
                rig.world.sleeperDeadlines == [start.adding(.seconds(120))], "the loop is asleep on the live cadence")

            await rig.session.setLiveChannel(false)
            let next = try #require(await rig.session.nextSidebar)
            #expect(next == start.adding(.seconds(30)))

            await rig.runToJustBefore(next)
            #expect(rig.lists == lists)
            await rig.world.jump(to: next)
            #expect(rig.lists == lists + 1, "the loop slept on to the deadline it had before")
            #expect(await rig.session.nextSidebar == next.adding(.seconds(30)))
        }
    }
}

struct SendAdmissionTests {
    @Test func closingBetweenTwoSendsOfOneDrainStartsNoSecondSend() async throws {
        try await SimWorld.run { world in
            let server = world.server
            let alice = server.addAccount(displayName: "Alice")
            let team = server.addSpace(.space, displayName: "Team", members: [alice])
            server.advance(.seconds(5))
            let store = InMemoryAccountStore()
            let gate = SessionGate()
            let clock = world.clock()
            let barrier = world.barrier()
            let calls = CallLog()
            let api = BarrierAPI(
                base: GoogleChatClient(transport: world.transport(), tokens: StaticTokens(token: alice.token)),
                barrier: barrier, log: calls, clock: clock)
            let sends = SendQueue(api: api, store: store, gate: gate, clock: clock)
            let generation = try #require(gate.current)
            let first = try sends.enqueue(text: "first", space: team, thread: nil, generation)
            let second = try sends.enqueue(text: "second", space: team, thread: nil, generation)
            let admission = AdmissionSwitch()
            barrier.arm()
            let drain = world.start { () -> Result<[UUID: SendOutcome]?, SyncError> in
                do throws(SyncError) {
                    return .success(try await sends.drain(team, generation) { admission.isOpen })
                } catch {
                    return .failure(error)
                }
            }
            await world.settle()
            try #require(barrier.arrivals == 1)
            #expect(!drain.isFinished)

            let released = world.now
            admission.close()
            barrier.release()
            try #require(await world.run { drain.isFinished })
            #expect(world.now == released, "the drain claimed the second send and paced it before giving it up")
            let outcomes = try #require(try await drain.value.get())

            #expect(isSent(outcomes[first.id]))
            #expect(outcomes[second.id] == .notAdmitted)
            #expect(calls.count("createMessage") == 1)
            #expect(server.messages(in: team).map(\.text) == ["first"])
            let held = try #require(try store.outbox().first)
            #expect(held.id == second.id && held.state == .queued && held.attempts == 0)
        }
    }

    @Test func admissionClosingAfterTheClaimRestoresTheItemBeforeAnyRequest() async throws {
        let rig = SendRig()
        let item = try rig.enqueue("claimed")
        let checks = Recorder<Int>()

        let outcomes = try #require(
            try await rig.sends.drain(rig.team, rig.generation) {
                checks.append(1)
                return checks.all.count == 1
            })

        #expect(outcomes[item.id] == .notAdmitted)
        #expect(rig.calls.count("createMessage") == 0)
        let held = try #require(try rig.outbox().first)
        #expect(held.state == .queued && held.attempts == 0)
    }

    @Test func anOfflineCreateKeepsTheItemQueuedWithoutSpendingAnAttempt() async throws {
        let rig = SendRig()
        rig.server.fail(.networkError(.notConnectedToInternet, route: .createMessage))
        let item = try rig.enqueue("offline")

        let outcomes = try await rig.drain()

        #expect(outcomes[item.id] == .offline)
        let held = try #require(try rig.outbox().first)
        #expect(held.state == .queued && held.attempts == 0 && held.nextAttempt == nil)
        #expect(try rig.store.drafts().isEmpty)

        _ = try await rig.drain()
        #expect(rig.serverTexts() == ["offline"])
    }

    @Test func admissionClosingAfterACreateLeavesTheItemCommittedForALaterDrain() async throws {
        let rig = SendRig()
        rig.tamper.setDropCreatedMessage(true)
        let item = try rig.enqueue("landed")
        let checks = Recorder<Int>()

        let outcomes = try #require(
            try await rig.sends.drain(rig.team, rig.generation) {
                checks.append(1)
                return checks.all.count <= 2
            })

        let name = try #require(rig.server.messages(in: rig.team).first?.name)
        #expect(outcomes[item.id] == .sent(name))
        #expect(rig.calls.count("getMessage") == 0, "hydration ran with admission closed")
        #expect(try rig.outbox().first?.state == .committed(name))

        _ = try await rig.drain()
        #expect(try rig.outbox().isEmpty)
        #expect(try rig.store.message(name)?.text == "landed")
    }

    @Test func logoutClosesAdmission() async throws {
        try await LogoutRig.run { rig in
            #expect(await rig.startAndSync())
            #expect(await rig.session.admitted)
            _ = try await rig.logout(refreshToken: nil)
            #expect(await rig.session.closing)
            #expect(await rig.session.admitted == false)
        }
    }
}
