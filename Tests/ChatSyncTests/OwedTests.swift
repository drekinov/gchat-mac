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

    @Test func removedSpacesLoseTheirRowsInTheListingCommit() async throws {
        let rig = try SyncRig()
        try await rig.seed()
        _ = try rig.record([.messagesCreated(space: rig.team, messages: [rig.first.name], time: rig.server.now)])
        rig.server.removeMember(rig.alice, from: rig.team)
        try await rig.syncSpaces()
        #expect(try rig.store.space(rig.team)?.isHidden == true)
        #expect(try rig.owed(rig.team) == nil)
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
