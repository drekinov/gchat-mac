import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

struct OwedSessionTests {
    @Test func dueRowsTakeAtMostHalfTheCapOldestFirstAndRotate() async throws {
        try await SimWorld.run { world in
            let server = world.server
            let alice = server.addAccount(displayName: "Alice")
            let store = InMemoryAccountStore()
            var spaces: [SpaceName] = []
            for index in 0..<6 { spaces.append(server.addSpace(.space, displayName: "S\(index)", members: [alice])) }
            var timing = SessionTiming.syncParked
            timing.spacesPerTick = 4
            let session = world.syncSession(alice, store: store, timing: timing)
            let gate = session.gate
            let generation = try #require(gate.current)
            let engine = SyncEngine(
                api: world.syncClient(alice), store: store, gate: gate, clock: world.clock(), me: alice.user.name)
            _ = try await engine.syncSpaces(generation)
            let unknown = SpaceName(unchecked: "spaces/unknown")
            try store.write(gate: gate, generation: generation) { batch in
                for (index, space) in spaces.enumerated() {
                    batch.append(.mergeOwed(space, boundary: Timestamp(seconds: Int64(100 - index)), messages: []))
                }
                batch.append(.mergeOwed(unknown, boundary: .init(seconds: 1), messages: []))
            }

            let first = await session.owedPlan(limit: timing.spacesPerTick / 2)
            #expect(first.due == [spaces[5], spaces[4]])
            #expect(first.unknown == [unknown])

            for space in first.due {
                try engine.deferOwed(space, revision: try #require(try store.owed(space)).revision, generation)
            }
            let second = await session.owedPlan(limit: timing.spacesPerTick / 2)
            #expect(second.due == [spaces[3], spaces[2]], "deferred rows make room for the rest")
        }
    }

    @Test func requestedOwedSyncsFetchWithoutWaitingForTheSidebar() async throws {
        try await SimWorld.run { world in
            let server = world.server
            let alice = server.addAccount(displayName: "Alice")
            let bob = server.addAccount(displayName: "Bob")
            let space = server.addSpace(.space, displayName: "Team", members: [alice, bob])
            server.post("history", in: space, from: .account(bob))
            server.advance(.seconds(5))
            let store = InMemoryAccountStore()
            let session = world.syncSession(alice, store: store)
            let recorder = SnapshotRecorder(session.snapshots.values, in: world)
            await session.start()
            #expect(
                await recorder.wait(in: world) { $0.status == .ok && $0.spaces.contains { $0.name == space } } != nil)
            await world.settle()
            #expect(world.sleeperDeadlines.count == 1, "only the loop is asleep")
            let lists: @Sendable () -> Int = {
                world.syncRequests(of: alice, "GET", suffix: "/\(space.rawValue)/messages")
            }
            let listed = lists()

            let message = server.post("pushed", in: space, from: .account(bob))
            let recorded = try await session.recordEvents([
                .messagesCreated(space: space, messages: [message.name], time: message.createTime)
            ])
            #expect(recorded.rejected.isEmpty)
            // No request runs between here and the settle below, so the clock stands still.
            let requested = world.now
            await session.requestOwedSync()
            await session.requestOwedSync()
            await world.settle()
            let boundary = try #require(try store.owed(space)).boundary
            let due = min(
                boundary.adding(SyncEngine.skew + AccountSession.owedDebounceSlack),
                requested.adding(AccountSession.owedDebounceCap))
            #expect(due > requested)
            #expect(world.sleeperDeadlines.count == 2, "two requests park one owed sync")
            #expect(world.hasSleeper(until: due), "the owed sync parks until the boundary settles")
            #expect(lists() == listed, "no fetch on the request itself")

            await world.jump(to: due.adding(.zero - .milliseconds(1)))
            #expect(world.hasSleeper(until: due), "nothing wakes the owed sync before its deadline")
            #expect(lists() == listed, "no fetch before the settle time")
            #expect(try store.message(message.name) == nil)

            await world.jump(to: due)
            #expect(lists() == listed + 1)
            #expect(try store.owed(space) == nil)
            #expect(try store.message(message.name) != nil)
            #expect(world.sleeperDeadlines.count == 1, "the owed sync ended")
        }
    }

    struct Seeded: Sendable {
        let world: SimWorld
        let server: FakeChatServer
        let alice: FakeAccount
        let bob: FakeAccount
        let space: SpaceName
        let store = InMemoryAccountStore()
        let session: AccountSession
        let engine: SyncEngine

        /// A seeded space, as a session that ran before left it. `engine` stands in for that earlier session.
        init(_ world: SimWorld) async throws {
            self.world = world
            server = world.server
            alice = server.addAccount(displayName: "Alice")
            bob = server.addAccount(displayName: "Bob")
            space = server.addSpace(.space, displayName: "Team", members: [alice, bob])
            server.post("history", in: space, from: .account(bob))
            server.advance(.seconds(5))
            session = world.syncSession(alice, store: store)
            let generation = try #require(session.gate.current)
            engine = SyncEngine(
                api: world.syncClient(alice), store: store, gate: session.gate, clock: world.clock(),
                me: alice.user.name)
            _ = try await engine.syncSpaces(generation)
            try await engine.syncMessages(space, generation)
            server.advance(.seconds(5))
        }
    }

    @Test func theSidebarSyncsOwedRowsTheListingNoLongerReports() async throws {
        try await SimWorld.run { world in
            let rig = try await Seeded(world)
            let message = rig.server.post("owed", in: rig.space, from: .account(rig.bob))
            rig.server.advance(.seconds(5))
            // The listing commit of a session that crashed before fetching the message.
            _ = try await rig.engine.syncSpaces(try #require(rig.session.gate.current))
            #expect(try rig.store.owed(rig.space) != nil)
            #expect(try rig.store.message(message.name) == nil)

            await rig.session.start()
            await world.settle()
            #expect(try rig.store.owed(rig.space) == nil, "the first tick syncs the row")
            #expect(try rig.store.message(message.name) != nil)
        }
    }

    @Test func aFailingSpaceSpendsAttemptsThroughTheTick() async throws {
        try await SimWorld.run { world in
            let rig = try await Seeded(world)
            rig.server.post("blocked", in: rig.space, from: .account(rig.bob))
            rig.server.advance(.seconds(5))
            rig.server.fail(.unavailable(route: .listMessages, space: rig.space, times: nil))

            await rig.session.start()
            await world.settle()
            let record = try #require(try rig.store.owed(rig.space))
            #expect(record.attempts == 1, "one failed tick spends one attempt")
            #expect(try #require(record.nextTry) > world.now)
        }
    }

    @Test func aMembershipEventSurvivesARestartBeforeTheListing() async throws {
        try await SimWorld.run { world in
            let server = world.server
            let alice = server.addAccount(displayName: "Alice")
            let bob = server.addAccount(displayName: "Bob")
            let store = InMemoryAccountStore()
            let first = world.syncSession(alice, store: store)
            let joined = server.addSpace(.space, displayName: "Joined", members: [alice, bob])
            let recorded = try await first.recordEvents([.membershipCreated(space: joined, time: server.now)])
            #expect(recorded.relistRequested)
            #expect(try store.relist().isPending)

            let second = world.syncSession(alice, store: store)
            await second.start()
            await world.settle()
            #expect(try !store.relist().isPending)
            #expect(try store.space(joined) != nil)
        }
    }
}

/// An engine with every answer held at a barrier, so an event can be recorded between a request and its commit.
private struct OwedRaceRig: Sendable {
    let world: SimWorld
    let server: FakeChatServer
    let alice: FakeAccount
    let bob: FakeAccount
    let store = InMemoryAccountStore()
    let gate = SessionGate()
    let barrier: Barrier
    let engine: SyncEngine
    let team: SpaceName

    init(_ world: SimWorld) async throws {
        self.world = world
        server = world.server
        alice = server.addAccount(displayName: "Alice")
        bob = server.addAccount(displayName: "Bob")
        barrier = world.barrier()
        let clock = world.clock()
        let api = BarrierAPI(base: world.syncClient(alice), barrier: barrier, log: CallLog(), clock: clock)
        engine = SyncEngine(api: api, store: store, gate: gate, clock: clock, me: alice.user.name)
        team = server.addSpace(.space, displayName: "Team", members: [alice, bob])
        server.post("hello", in: team, from: .account(bob))
        server.advance(.seconds(5))
        _ = try await engine.syncSpaces(generation)
        try await engine.syncMessages(team, generation)
        server.advance(.seconds(5))
    }

    var generation: Generation { gate.current! }

    func owed() throws -> OwedRecord? { try store.owed(team) }

    func record(_ events: [ChatEvent]) throws -> SyncEngine.RecordedEvents {
        try engine.recordEvents(events, generation)
    }

    /// Starts `operation` and runs it to the barrier, where its first answer waits.
    func held(_ operation: @escaping @Sendable () async throws(SyncError) -> Void) async throws -> SimTask<
        Result<Void, SyncError>
    > {
        barrier.arm()
        let task = world.syncStart(operation)
        await world.settle()
        try #require(barrier.arrivals == 1 && !task.isFinished, "the request is held before its commit")
        return task
    }

    func finish(_ task: SimTask<Result<Void, SyncError>>) async throws {
        barrier.release()
        await world.settle()
        try #require(task.isFinished)
        try await task.value.get()
    }
}

struct OwedRaceTests {
    @Test func anEventRacingTheCheckpointCommitIsKept() async throws {
        try await SimWorld.run { world in
            let rig = try await OwedRaceRig(world)
            let message = rig.server.post("racing", in: rig.team, from: .account(rig.bob))
            rig.server.advance(.seconds(5))
            _ = try await rig.engine.syncSpaces(rig.generation)
            let before = try #require(try rig.owed()).revision

            let sync = try await rig.held { () async throws(SyncError) in
                try await rig.engine.syncMessages(rig.team, rig.generation)
            }
            _ = try rig.record([.messagesCreated(space: rig.team, messages: [], time: message.createTime)])
            try await rig.finish(sync)

            let kept = try #require(try rig.owed(), "the newer write survives the older poll's commit")
            #expect(kept.revision > before)
            try await rig.engine.syncMessages(rig.team, rig.generation)
            #expect(try rig.owed() == nil)
        }
    }

    @Test func anEventRecordedDuringAStaleListingKeepsItsIDs() async throws {
        try await SimWorld.run { world in
            let rig = try await OwedRaceRig(world)
            rig.server.removeMember(rig.alice, from: rig.team)
            let listing = try await rig.held { () async throws(SyncError) in
                _ = try await rig.engine.syncSpaces(rig.generation)
            }
            let late = [MessageName(unchecked: "\(rig.team.rawValue)/messages/event0")]
            _ = try rig.record([.messagesCreated(space: rig.team, messages: late, time: rig.server.now)])
            try await rig.finish(listing)

            #expect(try rig.store.space(rig.team)?.isHidden == true)
            let kept = try #require(try rig.owed(), "the listing predates the event")
            #expect(kept.messages(in: rig.team) == late)
            #expect(kept.omitted == 0, "an omission seen before the event doesn't apply to it")
        }
    }

    @Test func anEventArrivingMidListingKeepsItsRelistRequest() async throws {
        try await SimWorld.run { world in
            let rig = try await OwedRaceRig(world)
            let listing = try await rig.held { () async throws(SyncError) in
                _ = try await rig.engine.syncSpaces(rig.generation)
            }
            _ = try rig.record([.membershipCreated(space: rig.team, time: rig.server.now)])
            try await rig.finish(listing)

            #expect(try rig.store.relist() == RelistRecord(requested: 1, resolved: 0))
            _ = try await rig.engine.syncSpaces(rig.generation)
            #expect(try !rig.store.relist().isPending)
        }
    }
}
