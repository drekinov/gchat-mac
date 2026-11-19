import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

extension SyncRig {
    func owed(_ space: SpaceName) throws -> OwedRecord? { try store.owed(space) }

    func record(_ events: [ChatEvent]) throws -> SyncEngine.RecordedEvents {
        try engine.recordEvents(events, generation)
    }

    func seed() async throws {
        try await syncSpaces()
        try await engine.syncMessages(team, generation)
        server.advance(.seconds(5))
    }

    /// Moves server time so the next frozen end is exactly `end`.
    func setFrozenEnd(_ end: Timestamp) {
        server.advance(end.adding(SyncEngine.skew).offset(from: server.now))
    }

    func fabricated(_ count: Int, in space: SpaceName) -> [MessageName] {
        (0..<count).map { MessageName(unchecked: "\(space.rawValue)/messages/event\($0)") }
    }
}

struct OwedTests {
    @Test(arguments: StoreKind.allCases)
    func theListingCommitsTheOwedRowWithTheSpace(_ kind: StoreKind) async throws {
        let rig = try SyncRig(store: kind)
        defer { rig.close() }
        try await rig.seed()
        #expect(try rig.store.owedRecords().isEmpty, "first sight of a space is a seed, not an owed row")

        let message = rig.server.post("missed?", in: rig.team, from: .account(rig.bob))
        rig.server.advance(.seconds(5))
        try await rig.syncSpaces()
        let stored = try #require(try rig.store.space(rig.team))
        #expect(try rig.owed(rig.team)?.boundary == stored.space.lastActiveTime)
        #expect(stored.space.lastActiveTime == message.createTime)

        let restarted = SyncEngine(
            api: rig.engine.api, store: rig.store, gate: rig.gate, clock: rig.clock, me: rig.alice.user.name)
        let again = try await restarted.syncSpaces(rig.generation)
        #expect(again.changed.isEmpty, "after a crash the listing no longer reports the move")
        #expect(try restarted.owedRecords()[rig.team] != nil)
        try await restarted.syncMessages(rig.team, rig.generation)
        #expect(try rig.store.message(message.name) != nil)
        #expect(try rig.owed(rig.team) == nil)
    }

    @Test func aMessageExactlyAtTheBoundaryIsFetchedBeforeTheRowClears() async throws {
        let rig = try SyncRig()
        try await rig.seed()
        let message = rig.server.post("on the line", in: rig.team, from: .account(rig.bob))
        try await rig.syncSpaces()
        #expect(try rig.owed(rig.team)?.boundary == message.createTime)

        rig.setFrozenEnd(message.createTime)
        try await rig.engine.syncMessages(rig.team, rig.generation)
        #expect(try rig.store.message(message.name) == nil)
        #expect(try rig.owed(rig.team) != nil, "an end equal to the boundary doesn't cover it")

        rig.server.advance(.milliseconds(1))
        try await rig.engine.syncMessages(rig.team, rig.generation)
        #expect(try rig.store.message(message.name) != nil)
        #expect(try rig.owed(rig.team) == nil)
    }

    @Test func aSkewLimitedEmptyFetchKeepsTheRow() async throws {
        let rig = try SyncRig()
        try await rig.seed()
        _ = try rig.record([.messagesCreated(space: rig.team, messages: [], time: rig.server.now)])

        try await rig.engine.syncMessages(rig.team, rig.generation)
        #expect(try rig.owed(rig.team) != nil)

        rig.server.advance(.seconds(3))
        try await rig.engine.syncMessages(rig.team, rig.generation)
        #expect(try rig.owed(rig.team) == nil)
    }

    @Test func aReseedClearsOnlyUpToTheNewestSeededMessage() async throws {
        let rig = try SyncRig()
        try await rig.seed()
        rig.server.editsBumpLastActiveTime = true
        let message = rig.server.post("seeded", in: rig.team, from: .account(rig.bob))
        rig.server.advance(.seconds(1))
        rig.server.edit(message.name, text: "edited")
        rig.server.advance(.seconds(5))
        try await rig.syncSpaces()
        let boundary = try #require(try rig.owed(rig.team)?.boundary)
        #expect(boundary > message.createTime)

        try rig.store.write(gate: rig.gate, generation: rig.generation) {
            $0.append(.setMeta(key: SyncEngine.formatKey(rig.team), value: "stale"))
        }
        try await rig.engine.syncMessages(rig.team, rig.generation)
        #expect(try rig.store.message(message.name)?.text == "edited")
        #expect(try rig.owed(rig.team) != nil, "the newest seeded message is older than the boundary")

        try await rig.engine.syncMessages(rig.team, rig.generation)
        #expect(try rig.owed(rig.team) == nil, "a completed catch-up past the boundary clears it")

        let newest = rig.server.post("newest", in: rig.team, from: .account(rig.bob))
        rig.server.advance(.seconds(5))
        try await rig.syncSpaces()
        #expect(try rig.owed(rig.team)?.boundary == newest.createTime)
        try rig.store.write(gate: rig.gate, generation: rig.generation) {
            $0.append(.setMeta(key: SyncEngine.formatKey(rig.team), value: "stale"))
        }
        try await rig.engine.syncMessages(rig.team, rig.generation)
        #expect(try rig.owed(rig.team) == nil, "a seed reaching the boundary covers it")
    }

    @Test func aDelayedEventOutsideTheNewestFiftyIsFetchedDirectly() async throws {
        let rig = try SyncRig()
        for index in 0..<60 { rig.server.post("m\(index)", in: rig.team, from: .account(rig.bob)) }
        rig.server.advance(.seconds(5))
        _ = try rig.record([.messagesCreated(space: rig.team, messages: [rig.first.name], time: rig.first.createTime)])

        try await rig.syncSpaces()
        try await rig.engine.syncMessages(rig.team, rig.generation)

        #expect(rig.calls.count("getMessage") == 1)
        #expect(try rig.store.message(rig.first.name) != nil)
        #expect(try rig.owed(rig.team) == nil)
    }

    @Test func aDeletedOwedMessageResolvesOnNotFound() async throws {
        let rig = try SyncRig()
        try await rig.seed()
        let ghost = MessageName(unchecked: "\(rig.team.rawValue)/messages/never")
        _ = try rig.record([.messagesCreated(space: rig.team, messages: [ghost], time: rig.first.createTime)])
        try await rig.engine.syncMessages(rig.team, rig.generation)
        #expect(try rig.owed(rig.team) == nil)
    }

    @Test func anEventRacingTheCheckpointCommitIsKept() async throws {
        let rig = try SyncRig()
        try await rig.seed()
        let message = rig.server.post("racing", in: rig.team, from: .account(rig.bob))
        rig.server.advance(.seconds(5))
        try await rig.syncSpaces()
        let before = try #require(try rig.owed(rig.team)).revision

        rig.barrier.arm()
        let sync = Task { try await rig.engine.syncMessages(rig.team, rig.generation) }
        #expect(await rig.barrier.waitForArrival())
        _ = try rig.record([.messagesCreated(space: rig.team, messages: [], time: message.createTime)])
        rig.barrier.release()
        try await sync.value

        let kept = try #require(try rig.owed(rig.team), "the newer write survives the older poll's commit")
        #expect(kept.revision > before)
        try await rig.engine.syncMessages(rig.team, rig.generation)
        #expect(try rig.owed(rig.team) == nil)
    }

    @Test func removedSpacesLoseTheirRowsInTheListingCommit() async throws {
        let rig = try SyncRig()
        try await rig.seed()
        _ = try rig.record([.messagesCreated(space: rig.team, messages: [rig.first.name], time: rig.server.now)])
        rig.server.removeMember(rig.alice, from: rig.team)
        try await rig.syncSpaces()
        #expect(try rig.store.space(rig.team)?.isHidden == true)
        #expect(try rig.owed(rig.team) == nil)
    }

    @Test func anEventRecordedDuringAStaleListingKeepsItsIDs() async throws {
        let rig = try SyncRig()
        try await rig.seed()
        rig.server.removeMember(rig.alice, from: rig.team)
        rig.barrier.arm()
        let listing = Task { try await rig.syncSpaces() }
        #expect(await rig.barrier.waitForArrival())
        let late = rig.fabricated(1, in: rig.team)
        _ = try rig.record([.messagesCreated(space: rig.team, messages: late, time: rig.server.now)])
        rig.barrier.release()
        try await listing.value

        #expect(try rig.store.space(rig.team)?.isHidden == true)
        let kept = try #require(try rig.owed(rig.team), "the listing predates the event")
        #expect(kept.messages(in: rig.team) == late)
        #expect(kept.omitted == 0, "an omission seen before the event doesn't apply to it")
    }

    @Test func anUnknownSpaceOmittedFromListingsIsDroppedOnlyWithoutIDs() async throws {
        let rig = try SyncRig()
        try await rig.seed()
        let ghost = SpaceName(unchecked: "spaces/ghost")
        let haunted = SpaceName(unchecked: "spaces/haunted")
        let recorded = try rig.record([
            .messagesCreated(space: ghost, messages: [], time: rig.server.now),
            .messagesCreated(space: haunted, messages: rig.fabricated(2, in: haunted), time: rig.server.now),
        ])
        #expect(recorded.relistRequested)
        #expect(try rig.store.relist().isPending)

        for _ in 0..<OwedRecord.maxOmissions { try await rig.syncSpaces() }
        #expect(try !rig.store.relist().isPending)
        #expect(try rig.owed(ghost) == nil)
        #expect(try rig.store.droppedOwedCount() == 1)
        let kept = try #require(try rig.owed(haunted))
        #expect(kept.omitted == OwedRecord.maxOmissions)

        try await rig.engine.probeOwed(haunted, revision: kept.revision, rig.generation)
        #expect(try rig.owed(haunted)?.ids.isEmpty == true, "the server no longer has those messages")
        #expect(try rig.store.message(rig.fabricated(1, in: haunted)[0]) == nil)
    }

    @Test func anEventArrivingMidListingKeepsItsRelistRequest() async throws {
        let rig = try SyncRig()
        try await rig.seed()
        rig.barrier.arm()
        let listing = Task { try await rig.syncSpaces() }
        #expect(await rig.barrier.waitForArrival())
        _ = try rig.record([.membershipCreated(space: rig.team, time: rig.server.now)])
        rig.barrier.release()
        try await listing.value

        #expect(try rig.store.relist() == RelistRecord(requested: 1, resolved: 0))
        try await rig.syncSpaces()
        #expect(try !rig.store.relist().isPending)
    }

    @Test func aSixtyIDBatchKeepsEveryID() async throws {
        let rig = try SyncRig()
        try await rig.seed()
        let ids = rig.fabricated(60, in: rig.team)
        let recorded = try rig.record([.messagesCreated(space: rig.team, messages: ids, time: rig.server.now)])
        #expect(recorded.rejected.isEmpty)
        #expect(!recorded.relistRequested)
        #expect(try rig.owed(rig.team)?.messages(in: rig.team) == ids)
    }

    @Test func moreThanAThousandIDsReportTheExcess() async throws {
        let rig = try SyncRig()
        try await rig.seed()
        let ids = rig.fabricated(1005, in: rig.team)
        let recorded = try rig.record([.messagesCreated(space: rig.team, messages: ids, time: rig.server.now)])
        #expect(recorded.rejected == Array(ids.suffix(5)))
        #expect(try rig.owed(rig.team)?.ids.count == OwedRecord.maxMessages)
    }

    @Test func anOwedIDFailingTransientlyIsKeptAndResolvedAfterTheOutage() async throws {
        let rig = try SyncRig()
        try await rig.seed()
        let message = rig.server.post("during the outage", in: rig.team, from: .account(rig.bob))
        _ = try rig.record([.messagesCreated(space: rig.team, messages: [message.name], time: message.createTime)])
        rig.server.fail(.unavailable(route: .listMessages, space: rig.team, times: nil))
        rig.server.fail(.unavailable(route: .getMessage, space: rig.team, times: nil))

        for _ in 0..<7 {
            rig.server.advance(.seconds(5))
            let revision = try #require(try rig.owed(rig.team)).revision
            await #expect(throws: SyncError.self) { try await rig.engine.syncMessages(rig.team, rig.generation) }
            try rig.engine.deferOwed(rig.team, revision: revision, rig.generation)
        }
        let kept = try #require(try rig.owed(rig.team))
        #expect(kept.attempts == 7)
        #expect(try rig.store.droppedOwedCount() == 0)

        rig.server.clearFailures()
        try await rig.engine.syncMessages(rig.team, rig.generation)
        #expect(try rig.store.message(message.name) != nil)
        #expect(try rig.owed(rig.team) == nil)
    }

    @Test func onlyRealFailuresSpendAnAttempt() {
        #expect(!SyncError.busy.countsAsOwedAttempt)
        #expect(!SyncError.retired.countsAsOwedAttempt)
        #expect(SyncError.api(.rateLimited(retryAfter: nil), .listMessages).countsAsOwedAttempt)
    }
}

struct OwedSessionTests {
    static func makeSession(
        _ server: FakeChatServer, _ alice: FakeAccount, store: any AccountStore, timing: SessionTiming,
        scratch: ScratchDirectory
    ) -> AccountSession {
        AccountSession(
            account: AccountID(), me: alice.user.name,
            api: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token)),
            store: store, clock: RealSleepClock(server: server),
            logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: scratch.url)),
            timing: timing)
    }

    @Test func dueRowsTakeAtMostHalfTheCapOldestFirstAndRotate() async throws {
        let server = FakeChatServer()
        let alice = server.addAccount(displayName: "Alice")
        let store = InMemoryAccountStore()
        let scratch = ScratchDirectory()
        var spaces: [SpaceName] = []
        for index in 0..<6 { spaces.append(server.addSpace(.space, displayName: "S\(index)", members: [alice])) }
        var timing = SessionTiming()
        timing.spacesPerTick = 4
        let session = Self.makeSession(server, alice, store: store, timing: timing, scratch: scratch)
        let gate = session.gate
        let generation = try #require(gate.current)
        let engine = SyncEngine(
            api: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token)),
            store: store, gate: gate, clock: ServerClock(server: server), me: alice.user.name)
        _ = try await engine.syncSpaces(generation)
        try store.write(gate: gate, generation: generation) { batch in
            for (index, space) in spaces.enumerated() {
                batch.append(.mergeOwed(space, boundary: Timestamp(seconds: Int64(100 - index)), messages: []))
            }
            batch.append(.mergeOwed(SpaceName(unchecked: "spaces/unknown"), boundary: .init(seconds: 1), messages: []))
        }

        let first = await session.owedPlan(limit: timing.spacesPerTick / 2)
        #expect(first.due == [spaces[5], spaces[4]])
        #expect(first.unknown == [SpaceName(unchecked: "spaces/unknown")])

        for space in first.due {
            try engine.deferOwed(space, revision: try #require(try store.owed(space)).revision, generation)
        }
        let second = await session.owedPlan(limit: timing.spacesPerTick / 2)
        #expect(second.due == [spaces[3], spaces[2]], "deferred rows make room for the rest")
    }

    @Test func requestedOwedSyncsFetchWithoutWaitingForTheSidebar() async throws {
        let server = FakeChatServer()
        let alice = server.addAccount(displayName: "Alice")
        let bob = server.addAccount(displayName: "Bob")
        let space = server.addSpace(.space, displayName: "Team", members: [alice, bob])
        server.post("history", in: space, from: .account(bob))
        server.advance(.seconds(5))
        let scratch = ScratchDirectory()
        var timing = SessionTiming.fast
        timing.sidebarInterval = .seconds(3600)
        let store = InMemoryAccountStore()
        let session = Self.makeSession(server, alice, store: store, timing: timing, scratch: scratch)
        let recorder = SnapshotRecorder(session.snapshots.values)
        await session.start()
        #expect(await recorder.wait { $0.status == .ok && $0.spaces.contains { $0.name == space } } != nil)

        let message = server.post("pushed", in: space, from: .account(bob))
        let recorded = try await session.recordEvents([
            .messagesCreated(space: space, messages: [message.name], time: message.createTime)
        ])
        #expect(recorded.rejected.isEmpty)
        await session.requestOwedSync()
        await session.requestOwedSync()
        try await Task.sleep(for: .milliseconds(100))
        #expect(try store.message(message.name) == nil, "the sync waits for the boundary to settle")
        server.advance(.seconds(6))
        #expect(await poll { (try? session.messages(in: space))?.contains { $0.name == message.name } == true })
        #expect(await poll { (try? store.owed(space)) == nil })

        recorder.cancel()
        _ = await session.logout(refreshToken: nil)
    }

    struct Seeded {
        let server = FakeChatServer()
        let alice: FakeAccount
        let bob: FakeAccount
        let space: SpaceName
        let store = InMemoryAccountStore()
        let scratch = ScratchDirectory()
        let session: AccountSession

        /// A seeded space whose newest message is owed, as after a crash right after the listing commit.
        init() async throws {
            alice = server.addAccount(displayName: "Alice")
            bob = server.addAccount(displayName: "Bob")
            space = server.addSpace(.space, displayName: "Team", members: [alice, bob])
            server.post("history", in: space, from: .account(bob))
            server.advance(.seconds(5))
            session = OwedSessionTests.makeSession(server, alice, store: store, timing: .fast, scratch: scratch)
            let generation = try #require(session.gate.current)
            let engine = SyncEngine(
                api: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token)),
                store: store, gate: session.gate, clock: ServerClock(server: server), me: alice.user.name)
            _ = try await engine.syncSpaces(generation)
            try await engine.syncMessages(space, generation)
            server.advance(.seconds(5))
        }
    }

    @Test func theSidebarSyncsOwedRowsTheListingNoLongerReports() async throws {
        let world = try await Seeded()
        let message = world.server.post("owed", in: world.space, from: .account(world.bob))
        world.server.advance(.seconds(5))
        let generation = try #require(world.session.gate.current)
        let engine = SyncEngine(
            api: GoogleChatClient(
                transport: world.server.makeTransport(), tokens: StaticTokens(token: world.alice.token)),
            store: world.store, gate: world.session.gate, clock: ServerClock(server: world.server),
            me: world.alice.user.name)
        _ = try await engine.syncSpaces(generation)
        #expect(try world.store.owed(world.space) != nil)

        await world.session.start()
        let store = world.store
        let space = world.space
        #expect(await poll { (try? store.owed(space)) == nil })
        #expect(try store.message(message.name) != nil)
        _ = await world.session.logout(refreshToken: nil)
    }

    @Test func aFailingSpaceSpendsAttemptsThroughTheTick() async throws {
        let world = try await Seeded()
        world.server.post("blocked", in: world.space, from: .account(world.bob))
        world.server.advance(.seconds(5))
        world.server.fail(.unavailable(route: .listMessages, space: world.space, times: nil))

        await world.session.start()
        let store = world.store
        let space = world.space
        #expect(await poll { ((try? store.owed(space))?.attempts ?? 0) >= 1 })
        let record = try #require(try store.owed(space))
        #expect(record.nextTry != nil)
        _ = await world.session.logout(refreshToken: nil)
    }

    @Test func aMembershipEventSurvivesARestartBeforeTheListing() async throws {
        let server = FakeChatServer()
        let alice = server.addAccount(displayName: "Alice")
        let bob = server.addAccount(displayName: "Bob")
        let store = InMemoryAccountStore()
        let scratch = ScratchDirectory()
        let first = Self.makeSession(server, alice, store: store, timing: .fast, scratch: scratch)
        let joined = server.addSpace(.space, displayName: "Joined", members: [alice, bob])
        let recorded = try await first.recordEvents([.membershipCreated(space: joined, time: server.now)])
        #expect(recorded.relistRequested)
        #expect(try store.relist().isPending)

        let second = Self.makeSession(server, alice, store: store, timing: .fast, scratch: scratch)
        await second.start()
        #expect(await poll { (try? store.relist().isPending) == false })
        #expect(try store.space(joined) != nil)
        _ = await second.logout(refreshToken: nil)
    }
}
