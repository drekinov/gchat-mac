import ChatKeychain
import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatSync

/// One session whose clock is frozen at server time, so a tick happens only when the test advances the server
/// or something resets the schedule.
struct ConnectivityRig: Sendable {
    let server = FakeChatServer()
    let alice: FakeAccount
    let space: SpaceName
    let store = InMemoryAccountStore()
    let barrier = Barrier()
    let calls = CallLog()
    let scratch = ScratchDirectory()
    let session: AccountSession
    let recorder: SnapshotRecorder

    init(timing: SessionTiming = .fast) {
        alice = server.addAccount(displayName: "Alice")
        space = server.addSpace(.space, displayName: "Team", members: [alice])
        server.post("hello", in: space, from: .user(User(name: UserName(unchecked: "users/42"), displayName: "Zed")))
        server.advance(.seconds(5))
        let clock = RealSleepClock(server: server)
        let api = BarrierAPI(
            base: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token)),
            barrier: barrier, log: calls, clock: clock)
        session = AccountSession(
            account: AccountID(), me: alice.user.name, api: api, store: store, clock: clock,
            logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: scratch.url)),
            timing: timing)
        recorder = SnapshotRecorder(session.snapshots.values)
    }

    func startAndSync() async -> Bool {
        await session.start()
        let space = space
        return await recorder.wait { $0.status == .ok && $0.spaces.contains { $0.name == space } } != nil
    }

    /// Lets the loop settle on frozen time, so a request count stops moving unless something reset the schedule.
    func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    func shutdown() async { _ = await session.logout(refreshToken: nil) }

    func rateLimitTheNextTick(retryAfter: Int = 30) async -> Bool {
        server.fail(.rateLimited(route: .listSpaces, retryAfter: retryAfter))
        let seen = recorder.history.count
        server.advance(.seconds(1))
        return await recorder.wait(since: seen) { if case .backingOff = $0.status { true } else { false } } != nil
    }

    /// The loop stores the next deadline only after the tick that published its status returns.
    func nextSidebar() async -> Timestamp? {
        for _ in 0..<500 {
            if let next = await session.nextSidebar { return next }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }
}

final class AdmissionSwitch: Sendable {
    private let open = Mutex(true)

    func close() { open.withLock { $0 = false } }
    var isOpen: Bool { open.withLock { $0 } }
}

struct ConnectivityTests {
    @Test func aWakeWhileOfflineOnlyMarksTheCatchUpAndItRunsOnReconnect() async throws {
        let rig = ConnectivityRig()
        #expect(await rig.startAndSync())
        let restarts = Recorder<Int>()
        await rig.session.setEventChannelRestart { restarts.append(1) }
        await rig.session.setConnectivity(.unreachable)
        let before = rig.server.requests.count

        await rig.session.systemDidWake()
        try await rig.settle()

        #expect(rig.server.requests.count == before, "a wake while offline sent requests")
        #expect(await rig.session.catchUpPending)
        #expect(rig.recorder.latest?.status == .offline)
        #expect(restarts.all.isEmpty)

        let lists = rig.calls.count("listSpaces")
        let seen = rig.recorder.history.count
        await rig.session.setConnectivity(.reachable)
        #expect(await poll { rig.calls.count("listSpaces") > lists })
        #expect(await poll { restarts.all.count == 1 })
        #expect(await rig.session.catchUpPending == false)
        #expect(await rig.recorder.wait(since: seen) { $0.status == .ok } != nil)
        await rig.shutdown()
    }

    @Test func aReconnectDuringAnInFlightTickRunsAFreshTickOnce() async throws {
        let rig = ConnectivityRig()
        #expect(await rig.startAndSync())
        let restarts = Recorder<Int>()
        await rig.session.setEventChannelRestart { restarts.append(1) }
        let lists = rig.calls.count("listSpaces")
        rig.barrier.arm()
        rig.server.advance(.seconds(1))
        #expect(await rig.barrier.waitForArrival())

        await rig.session.setConnectivity(.unreachable)
        await rig.session.setConnectivity(.reachable)
        rig.barrier.release()

        #expect(await poll { rig.calls.count("listSpaces") == lists + 2 }, "the in-flight tick overwrote the reset")
        #expect(await poll { restarts.all.count == 1 })
        try await rig.settle()
        #expect(rig.calls.count("listSpaces") == lists + 2, "the catch-up kept polling on frozen time")
        #expect(await rig.session.catchUpPending == false)
        await rig.shutdown()
    }

    @Test func anOfflineSendIsNotAttemptedAndDrainsOnReconnect() async throws {
        let rig = ConnectivityRig()
        #expect(await rig.startAndSync())
        await rig.session.setConnectivity(.unreachable)

        let item = try await rig.session.send("while away", in: rig.space, thread: nil)
        try await rig.settle()

        #expect(rig.calls.count("createMessage") == 0)
        let held = try #require(try rig.session.outbox(in: rig.space).first)
        #expect(held.id == item.id && held.state == .queued && held.attempts == 0)
        #expect(await rig.session.blockedDrains == [rig.space])

        await rig.session.setConnectivity(.reachable)
        #expect(await poll { rig.server.messages(in: rig.space).contains { $0.text == "while away" } })
        #expect(await poll { ((try? rig.session.outbox(in: rig.space)) ?? []).isEmpty })
        #expect(rig.calls.count("createMessage") == 1)
        await rig.shutdown()
    }

    @Test func aReconnectKeepsARateLimitDeadlineThatOverlapsTheOfflinePeriod() async throws {
        let rig = ConnectivityRig()
        #expect(await rig.startAndSync())
        #expect(await rig.rateLimitTheNextTick())
        let deadline = try #require(await rig.session.retryUntil)

        await rig.session.setConnectivity(.unreachable)
        await rig.session.setConnectivity(.reachable)
        let lists = rig.calls.count("listSpaces")
        try await rig.settle()

        #expect(await rig.session.retryUntil == deadline)
        #expect(await rig.session.offlineUntil == nil)
        #expect(rig.calls.count("listSpaces") == lists, "the reconnect polled through a server retry deadline")
        #expect(rig.recorder.latest?.status == .backingOff(until: deadline))
        #expect(await rig.session.catchUpPending, "the catch-up waits for the deadline")

        let seen = rig.recorder.history.count
        rig.server.advance(.seconds(31))
        #expect(await rig.recorder.wait(since: seen) { $0.status == .ok } != nil)
        #expect(await poll { rig.calls.count("listSpaces") > lists })
        #expect(await rig.session.catchUpPending == false)
        await rig.shutdown()
    }

    @Test func aSendHeldByARateLimitOnAHealthyPathDrainsWhenTheDeadlineExpires() async throws {
        let rig = ConnectivityRig()
        #expect(await rig.startAndSync())
        #expect(await rig.rateLimitTheNextTick())

        try await rig.session.send("patient", in: rig.space, thread: nil)
        try await rig.settle()
        #expect(rig.calls.count("createMessage") == 0)
        #expect(await rig.session.blockedDrains == [rig.space])

        rig.server.advance(.seconds(31))
        #expect(await poll { rig.server.messages(in: rig.space).contains { $0.text == "patient" } })
        #expect(await rig.session.blockedDrains.isEmpty)
        await rig.shutdown()
    }

    @Test func aStaleOfflineResultFromBeforeAReconnectIsIgnored() async throws {
        let rig = ConnectivityRig()
        #expect(await rig.startAndSync())
        rig.server.fail(.networkError(.notConnectedToInternet, route: .listSpaces))
        rig.barrier.arm()
        rig.server.advance(.seconds(1))
        #expect(await rig.barrier.waitForArrival())

        await rig.session.setConnectivity(.unreachable)
        await rig.session.setConnectivity(.reachable)
        let lists = rig.calls.count("listSpaces")
        rig.barrier.release()

        #expect(await poll { rig.calls.count("listSpaces") > lists }, "the stale result blocked the catch-up")
        try await rig.settle()
        #expect(await rig.session.offlineUntil == nil)
        #expect(await rig.session.offlineFailures == 0)
        #expect(await rig.session.status == .ok)
        await rig.shutdown()
    }

    @Test func aSendThatFindsTheNetworkOfflineRetriesWhenTheOfflineBackoffEnds() async throws {
        var timing = SessionTiming.fast
        timing.idleSleep = .seconds(600)
        timing.sidebarInterval = .seconds(600)
        let rig = ConnectivityRig(timing: timing)
        #expect(await rig.startAndSync())
        rig.server.fail(.networkError(.notConnectedToInternet, route: .createMessage))

        try await rig.session.send("bounced", in: rig.space, thread: nil)
        #expect(await poll { rig.recorder.latest?.status == .offline })
        #expect(await rig.session.offlineUntil != nil)
        #expect(!rig.server.messages(in: rig.space).contains { $0.text == "bounced" })

        rig.server.advance(.seconds(5))
        #expect(await poll { rig.server.messages(in: rig.space).contains { $0.text == "bounced" } })
        await rig.shutdown()
    }

    @Test func aCurrentOfflineResultStillBacksOff() async throws {
        let rig = ConnectivityRig()
        #expect(await rig.startAndSync())
        rig.server.fail(.networkError(.notConnectedToInternet, route: .listSpaces))
        rig.server.advance(.seconds(1))

        #expect(await rig.recorder.wait { $0.status == .offline } != nil)
        #expect(await rig.session.offlineUntil != nil)
        #expect(await rig.session.retryUntil == nil)
        await rig.shutdown()
    }

    @Test func aNewSessionStartsWithTheManagersCurrentPathState() async throws {
        let server = FakeChatServer()
        let alice = server.addAccount(displayName: "Alice")
        let scratch = ScratchDirectory()
        let secrets = InMemorySecretStore()
        let tombstones = LogoutTombstones(root: scratch.url)
        let runner = LogoutRunner(eraser: NoopEraser(), tombstones: tombstones)
        let manager = AccountManager(
            registry: AccountRegistry(secrets: secrets), recovery: LogoutRecovery(runner: runner),
            tombstones: tombstones
        ) { record in
            AccountSession(
                account: record.id, me: record.me,
                api: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token)),
                store: InMemoryAccountStore(), clock: RealSleepClock(server: server), logoutRunner: runner,
                timing: .fast)
        }

        await manager.setConnectivity(.unreachable)
        let session = try await manager.add(
            AccountRecord(email: "alice@example.com", displayName: "Alice", me: alice.user.name))

        #expect(await session.reachable == false)
        #expect(await session.admitted == false)
        #expect(server.requests.isEmpty, "a session created offline sent requests")

        await manager.setConnectivity(.reachable)
        #expect(await session.reachable)
        #expect(await poll { !server.requests.isEmpty })
        _ = await session.logout(refreshToken: nil)
    }

    @Test func theBackgroundCadenceIsFasterUnlessTheEventChannelIsLive() {
        let timing = SessionTiming()
        #expect(timing.sidebarInterval(appActive: true, liveChannel: false) == .seconds(60))
        #expect(timing.sidebarInterval(appActive: true, liveChannel: true) == .seconds(60))
        #expect(timing.sidebarInterval(appActive: false, liveChannel: false) == .seconds(30))
        #expect(timing.sidebarInterval(appActive: false, liveChannel: true) == .seconds(120))
    }

    @Test func goingInactivePullsTheNextSidebarTickIn() async throws {
        var timing = SessionTiming.fast
        timing.sidebarInterval = .seconds(600)
        timing.inactiveSidebarInterval = .seconds(30)
        timing.liveSidebarInterval = .seconds(120)
        let rig = ConnectivityRig(timing: timing)
        #expect(await rig.startAndSync())
        let start = rig.server.now
        #expect(try #require(await rig.nextSidebar()).offset(from: start) > .seconds(500))

        await rig.session.setAppActive(false)

        let next = try #require(await rig.session.nextSidebar)
        #expect(next.offset(from: start) <= .seconds(30))
        await rig.session.setLiveChannel(true)
        await rig.session.setAppActive(false)
        #expect(await rig.session.nextSidebar == next, "a slower live cadence never pushes a due tick out")
        await rig.shutdown()
    }
}

struct SendAdmissionTests {
    @Test func closingBetweenTwoSendsOfOneDrainStartsNoSecondSend() async throws {
        let rig = SendRig()
        let first = try rig.enqueue("first")
        let second = try rig.enqueue("second")
        let admission = AdmissionSwitch()
        rig.barrier.arm()
        let sends = rig.sends
        let generation = rig.generation
        let team = rig.team
        let drain = Task { try await sends.drain(team, generation) { admission.isOpen } }
        #expect(await rig.barrier.waitForArrival())

        admission.close()
        rig.barrier.release()
        let outcomes = try #require(try await drain.value)

        #expect(isSent(outcomes[first.id]))
        #expect(outcomes[second.id] == .notAdmitted)
        #expect(rig.calls.count("createMessage") == 1)
        #expect(rig.serverTexts() == ["first"])
        let held = try #require(try rig.outbox().first)
        #expect(held.id == second.id && held.state == .queued && held.attempts == 0)
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

    @Test func logoutClosesAdmission() async throws {
        let rig = try LogoutRig()
        #expect(await rig.startAndSync())
        #expect(await rig.session.admitted)
        _ = await rig.session.logout(refreshToken: nil)
        #expect(await rig.session.closing)
        #expect(await rig.session.admitted == false)
    }
}
