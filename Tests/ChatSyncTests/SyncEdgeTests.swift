import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

extension SyncRig {
    func texts(_ space: SpaceName) throws -> [String] {
        try store.messages(in: space, before: nil, limit: 100_000).map(\.text)
    }

    func listMessageRequests() -> [RecordedRequest] {
        server.requests.filter { $0.method == "GET" && $0.path.hasSuffix("/messages") }
    }

    func eventRequests() -> [RecordedRequest] {
        server.requests.filter { $0.path.hasSuffix("/spaceEvents") }
    }

    var frozenEnd: Timestamp { server.now.adding(.zero - SyncEngine.skew) }
}

struct SyncEdgeTests {
    @Test func spacesStoredInAnOlderMessageFormatReseedOnce() async throws {
        let rig = try SyncRig()
        let space = rig.server.addSpace(.space, displayName: "Format", members: [rig.alice, rig.bob])
        rig.server.post("hello", in: space, from: .account(rig.bob))
        rig.server.advance(.seconds(5))
        try await rig.syncSpaces()
        try await rig.engine.syncMessages(space, rig.generation)
        #expect(try rig.store.meta(SyncEngine.formatKey(space)) == SyncEngine.messageFormat)

        try rig.store.write(gate: rig.gate, generation: rig.generation) {
            $0.append(.setMeta(key: SyncEngine.formatKey(space), value: nil))
        }
        rig.server.advance(.seconds(5))
        let before = rig.listMessageRequests().count
        try await rig.engine.syncMessages(space, rig.generation)
        let reseed = rig.listMessageRequests().dropFirst(before)
        #expect(reseed.count == 1)
        #expect(reseed.first?.query.contains { $0.name == "orderBy" && $0.value == "createTime DESC" } == true)
        #expect(try rig.store.meta(SyncEngine.formatKey(space)) == SyncEngine.messageFormat)
        #expect(try rig.texts(space) == ["hello"])

        rig.server.advance(.seconds(5))
        try await rig.engine.syncMessages(space, rig.generation)
        #expect(
            rig.listMessageRequests().last?.query.contains { $0.name == "orderBy" && $0.value == "createTime ASC" }
                == true)
    }

    @Test func equalCreateTimesAcrossCheckpointBoundariesLoseNothingAndDuplicateNothing() async throws {
        let rig = try SyncRig()
        let space = rig.server.addSpace(.space, displayName: "Equal", members: [rig.alice, rig.bob])
        rig.server.post("seed", in: space, from: .account(rig.bob))
        rig.server.advance(.seconds(5))
        try await rig.syncSpaces()
        try await rig.engine.syncMessages(space, rig.generation)
        let checkpoint = try #require(try rig.store.checkpoint(space, .messages))

        for text in ["tie-1", "tie-2", "tie-3"] {
            rig.server.post(text, in: space, from: .account(rig.bob), at: checkpoint)
        }
        rig.server.advance(.seconds(5))
        let boundary = rig.frozenEnd
        for text in ["end-1", "end-2"] { rig.server.post(text, in: space, from: .account(rig.bob), at: boundary) }

        try await rig.engine.syncMessages(space, rig.generation)
        try await rig.engine.syncEvents(space, rig.generation)
        rig.server.advance(.seconds(5))
        try await rig.engine.syncMessages(space, rig.generation)
        try await rig.engine.syncMessages(space, rig.generation)

        let stored = try rig.store.messages(in: space, before: nil, limit: 100)
        #expect(Set(stored.map(\.text)) == ["seed", "tie-1", "tie-2", "tie-3", "end-1", "end-2"])
        #expect(stored.count == 6)
        #expect(Set(stored.map(\.name)).count == 6)
        #expect(stored.map(\.createTime) == stored.map(\.createTime).sorted())
    }

    @Test func aCheckpointAheadOfTheClockSendsNoRequest() async throws {
        let rig = try SyncRig()
        try await rig.syncSpaces()
        try await rig.engine.syncMessages(rig.team, rig.generation)
        let ahead = rig.server.now.adding(.seconds(60))
        try rig.store.write(gate: rig.gate, generation: rig.generation) { batch in
            batch.append(.setCheckpoint(rig.team, .messages, ahead))
            batch.append(.setCheckpoint(rig.team, .events, ahead))
        }
        let before = try rig.dump()
        let requests = rig.server.requests.count

        try await rig.engine.syncMessages(rig.team, rig.generation)
        try await rig.engine.syncEvents(rig.team, rig.generation)

        #expect(rig.server.requests.count == requests)
        #expect(try rig.dump() == before)
    }

    @Test func eventsBeforeTheFirstSeedDoNothing() async throws {
        let rig = try SyncRig()
        try await rig.syncSpaces()
        let requests = rig.server.requests.count
        try await rig.engine.syncEvents(rig.team, rig.generation)
        #expect(rig.server.requests.count == requests)
        #expect(try rig.store.checkpoint(rig.team, .events) == nil)
    }

    @Test func pollingAgainWithNothingNewIsHarmless() async throws {
        let rig = try SyncRig()
        try await rig.syncSpaces()
        try await rig.engine.syncMessages(rig.team, rig.generation)
        try await rig.engine.syncEvents(rig.team, rig.generation)
        let first = try rig.dump()

        rig.server.advance(.seconds(30))
        try await rig.engine.syncMessages(rig.team, rig.generation)
        try await rig.engine.syncEvents(rig.team, rig.generation)
        let second = try rig.dump()

        #expect(second.messages == first.messages)
        #expect(
            try #require(second.checkpoints["\(rig.team)|messages"]) > #require(
                first.checkpoints["\(rig.team)|messages"]))
    }

    @Test func twoOverlappingPollsOfOneSpaceYieldBusyForTheSecond() async throws {
        let rig = try SyncRig()
        try await rig.syncSpaces()
        rig.barrier.arm()
        let running = rig.start(.messagesSeed, rig.generation)
        #expect(await rig.barrier.waitForArrival())

        await #expect(throws: SyncError.busy) { try await rig.engine.syncMessages(rig.team, rig.generation) }
        rig.barrier.release()
        #expect(await running.value == nil)

        rig.barrier.arm()
        let listing = rig.start(.spaces, rig.generation)
        #expect(await rig.barrier.waitForArrival())
        await #expect(throws: SyncError.busy) { _ = try await rig.engine.syncSpaces(rig.generation) }
        rig.barrier.release()
        #expect(await listing.value == nil)

        let again = try await rig.engine.syncSpaces(rig.generation)
        #expect(again.removed.isEmpty)
        try await rig.engine.syncMessages(rig.team, rig.generation)
        #expect(try rig.texts(rig.team) == ["hello"])
    }

    @Test func messagesAndEventsOfOneSpaceShareOneSlot() async throws {
        let rig = try SyncRig()
        try await rig.syncSpaces()
        try await rig.engine.syncMessages(rig.team, rig.generation)
        rig.server.edit(rig.first.name, text: "edited")
        rig.server.advance(.seconds(5))

        rig.barrier.arm()
        let events = rig.start(.events, rig.generation)
        #expect(await rig.barrier.waitForArrival())
        await #expect(throws: SyncError.busy) { try await rig.engine.syncMessages(rig.team, rig.generation) }
        rig.barrier.release()
        #expect(await events.value == nil)

        rig.server.advance(.seconds(5))
        rig.barrier.arm()
        let messages = rig.start(.messagesCatchUp, rig.generation)
        #expect(await rig.barrier.waitForArrival())
        await #expect(throws: SyncError.busy) { try await rig.engine.syncEvents(rig.team, rig.generation) }
        rig.barrier.release()
        #expect(await messages.value == nil)
    }

    @Test func aFailedPollReleasesItsSlot() async throws {
        let rig = try SyncRig()
        try await rig.syncSpaces()
        rig.server.fail(.unavailable(route: .listMessages))
        await #expect(throws: SyncError.self) { try await rig.engine.syncMessages(rig.team, rig.generation) }
        try await rig.engine.syncMessages(rig.team, rig.generation)
        #expect(try rig.texts(rig.team) == ["hello"])
    }

    @Test func anEditWithUnchangedLastActiveTimeIsCaughtByEvents() async throws {
        let rig = try SyncRig()
        rig.server.editsBumpLastActiveTime = false
        try await rig.syncSpaces()
        try await rig.engine.syncMessages(rig.team, rig.generation)
        let doomed = rig.server.post("bye", in: rig.team, from: .account(rig.bob))
        rig.server.advance(.seconds(5))
        try await rig.syncSpaces()
        try await rig.engine.syncMessages(rig.team, rig.generation)
        let activeBefore = try #require(try rig.store.space(rig.team)?.space.lastActiveTime)

        rig.server.edit(rig.first.name, text: "hello, edited")
        rig.server.delete(doomed.name)
        rig.server.advance(.seconds(5))

        let listing = try await rig.engine.syncSpaces(rig.generation)
        #expect(listing.changed.isEmpty, "the space looks unchanged to the sidebar")
        try await rig.engine.syncMessages(rig.team, rig.generation)
        let stale = try #require(try rig.store.message(rig.first.name))
        #expect(stale.text == "hello", "catch-up cannot see the edit, so only events can")

        try await rig.engine.syncEvents(rig.team, rig.generation)
        let edited = try #require(try rig.store.message(rig.first.name))
        let deleted = try #require(try rig.store.message(doomed.name))
        #expect(edited.text == "hello, edited")
        #expect(deleted.isDeleted)
        #expect(try rig.store.space(rig.team)?.space.lastActiveTime == activeBefore)
    }

    @Test func anEventCheckpointOlderThan28DaysTriggersTheWindowRefetch() async throws {
        let rig = try SyncRig()
        try await rig.syncSpaces()
        try await rig.engine.syncMessages(rig.team, rig.generation)
        let old = try #require(try rig.store.checkpoint(rig.team, .events))
        #expect(try rig.store.checkpoint(rig.team, .messages) == old)

        rig.server.advance(.seconds(29 * 86_400))
        rig.server.edit(rig.first.name, text: "edited long ago")
        rig.server.post("recent", in: rig.team, from: .account(rig.bob))
        rig.server.advance(.seconds(5))
        let eventCalls = rig.eventRequests().count

        try await rig.engine.syncEvents(rig.team, rig.generation)

        #expect(rig.eventRequests().count == eventCalls, "a 28+ day window must not be requested")
        let end = rig.frozenEnd
        #expect(try rig.store.checkpoint(rig.team, .events) == end)
        #expect(try rig.store.checkpoint(rig.team, .messages) == end)
        let stored = try rig.store.messages(in: rig.team, before: nil, limit: 100)
        #expect(Set(stored.map(\.text)) == ["edited long ago", "recent"])
    }

    @Test func catchUpLongerThanMaxCatchUpPagesFallsBackToTheSeedWindow() async throws {
        let rig = try SyncRig()
        try await rig.syncSpaces()
        try await rig.engine.syncMessages(rig.team, rig.generation)
        let total = SyncEngine.maxCatchUpPages * SyncEngine.pageSize + 50
        for index in 0..<total { rig.server.post("m\(index)", in: rig.team, from: .account(rig.bob)) }
        rig.server.advance(.seconds(5))
        let calls = rig.listMessageRequests().count

        try await rig.engine.syncMessages(rig.team, rig.generation)

        let made = Array(rig.listMessageRequests().dropFirst(calls))
        #expect(made.count == SyncEngine.maxCatchUpPages + 1)
        #expect(made.last?.value(for: "pageSize") == String(SyncEngine.initialMessages))
        #expect(made.last?.value(for: "orderBy") == MessageOrder.descending.rawValue)
        let end = rig.frozenEnd
        #expect(try rig.store.checkpoint(rig.team, .messages) == end)
        #expect(try rig.store.checkpoint(rig.team, .events) == end)
        let stored = try rig.texts(rig.team)
        #expect(stored.count == SyncEngine.initialMessages, "the window replaces what was cached")
        #expect(stored.suffix(3) == ["m\(total - 3)", "m\(total - 2)", "m\(total - 1)"])
    }

    @Test func anUnnamedGroupChatWhoseOtherMembersAreAllAnonymousIsHidden() async throws {
        let rig = try SyncRig()
        let ghost = rig.server.addSpace(
            .groupChat, members: [rig.alice],
            users: [rig.anonymous, User(name: UserName(unchecked: "users/9002"), isAnonymous: true)])
        rig.server.advance(.seconds(5))
        try await rig.syncSpaces()

        try await rig.engine.syncMemberTitle(ghost, rig.generation)

        let hidden = try #require(try rig.store.space(ghost))
        #expect(hidden.isHidden)
        #expect(try rig.engine.snapshotSpaces().contains { $0.name == ghost } == false)
        #expect(try rig.engine.snapshotSpaces().contains { $0.name == rig.team })
    }

    @Test func aGroupChatWithOneRealMemberIsTitledNotHidden() async throws {
        let rig = try SyncRig()
        let mixed = rig.server.addSpace(.groupChat, members: [rig.alice, rig.bob], users: [rig.anonymous])
        rig.server.advance(.seconds(5))
        try await rig.syncSpaces()

        try await rig.engine.syncMemberTitle(mixed, rig.generation)

        let stored = try #require(try rig.store.space(mixed))
        #expect(!stored.isHidden)
        #expect(stored.memberTitle == "Bob")
    }

    @Test func aHiddenAnonymousChatStaysHiddenOnTheNextSidebarListing() async throws {
        let rig = try SyncRig()
        let ghost = rig.server.addSpace(.directMessage, members: [rig.alice], users: [rig.anonymous])
        rig.server.advance(.seconds(5))
        try await rig.syncSpaces()
        try await rig.engine.syncMemberTitle(ghost, rig.generation)
        #expect(try rig.store.space(ghost)?.isHidden == true)

        try await rig.syncSpaces()

        #expect(try rig.store.space(ghost)?.isHidden == true)
    }

    @Test func aPageTwoFailureOfTheSpaceListingHidesNothing() async throws {
        let rig = try SyncRig()
        for index in 0..<1005 { rig.server.addSpace(.space, displayName: "S\(index)", members: [rig.alice]) }
        rig.server.advance(.seconds(5))
        let first = try await rig.engine.syncSpaces(rig.generation)
        #expect(first.removed.isEmpty)
        let known = try rig.store.spaces().count
        #expect(known == 1007)

        rig.server.removeMember(rig.alice, from: rig.team)
        rig.server.fail(.unavailable(route: .listSpaces, onlyWithPageToken: true))
        await #expect(throws: SyncError.self) { _ = try await rig.engine.syncSpaces(rig.generation) }

        let stored = try rig.store.spaces()
        #expect(stored.count == known)
        #expect(stored.allSatisfy { !$0.isHidden })

        let healed = try await rig.engine.syncSpaces(rig.generation)
        #expect(healed.removed == [rig.team])
        #expect(try rig.store.space(rig.team)?.isHidden == true)
    }

    @Test func anIncompleteListingBeyondTheMaxPagesHidesNothingUntilItIsComplete() async throws {
        let rig = try SyncRig()
        let limit = 10 * 1000
        let others = (0..<(limit + 2)).map { rig.server.addSpace(.space, displayName: "S\($0)", members: [rig.alice]) }
        rig.server.advance(.seconds(5))
        _ = try await rig.engine.syncSpaces(rig.generation)
        let stored = try rig.store.spaces().count
        #expect(stored == limit, "the listing is capped at 10 pages")

        rig.server.removeMember(rig.alice, from: rig.team)
        let partial = try await rig.engine.syncSpaces(rig.generation)
        #expect(partial.removed.isEmpty, "a capped listing cannot confirm a membership loss")
        let stillVisible = try rig.store.space(rig.team)
        #expect(stillVisible?.isHidden == false)

        for name in others.prefix(3) { rig.server.removeMember(rig.alice, from: name) }
        let complete = try await rig.engine.syncSpaces(rig.generation)
        #expect(Set(complete.removed) == Set([rig.team] + others.prefix(3)))
        let hidden = try rig.store.space(rig.team)
        #expect(hidden?.isHidden == true)
    }

    @Test(arguments: [SyncStream.messages, .events])
    func aPageThatSkippedARecordDoesNotAdvanceTheCheckpoint(stream: SyncStream) async throws {
        let rig = try SyncRig()
        try await rig.syncSpaces()
        try await rig.engine.syncMessages(rig.team, rig.generation)
        let checkpoint = try #require(try rig.store.checkpoint(rig.team, stream))
        rig.server.post("new", in: rig.team, from: .account(rig.bob))
        rig.server.edit(rig.first.name, text: "edited")
        rig.server.advance(.seconds(5))

        rig.tamper.setSkipped(1)
        if stream == .messages {
            try? await rig.engine.syncMessages(rig.team, rig.generation)
        } else {
            try? await rig.engine.syncEvents(rig.team, rig.generation)
        }
        #expect(try rig.store.checkpoint(rig.team, stream) == checkpoint, "an incomplete page moved the checkpoint")

        rig.tamper.setSkipped(0)
        try await rig.engine.syncMessages(rig.team, rig.generation)
        try await rig.engine.syncEvents(rig.team, rig.generation)
        let advanced = try #require(try rig.store.checkpoint(rig.team, stream))
        #expect(advanced > checkpoint)
        #expect(Set(try rig.texts(rig.team)) == ["edited", "new"])
    }

    @Test func aSeedWindowThatSkippedARecordSetsNoCheckpoint() async throws {
        let rig = try SyncRig()
        try await rig.syncSpaces()
        rig.tamper.setSkipped(1)
        try? await rig.engine.syncMessages(rig.team, rig.generation)
        let messages = try rig.store.checkpoint(rig.team, .messages)
        let events = try rig.store.checkpoint(rig.team, .events)
        #expect(messages == nil)
        #expect(events == nil)

        rig.tamper.setSkipped(0)
        try await rig.engine.syncMessages(rig.team, rig.generation)
        #expect(try rig.store.checkpoint(rig.team, .messages) != nil)
        #expect(try rig.store.checkpoint(rig.team, .events) != nil)
    }

    @Test func aSpaceListingThatSkippedARecordConfirmsNoMembershipLoss() async throws {
        let rig = try SyncRig()
        try await rig.syncSpaces()
        rig.server.removeMember(rig.alice, from: rig.team)

        rig.tamper.setSkipped(1)
        let partial = try await rig.engine.syncSpaces(rig.generation)
        #expect(partial.removed.isEmpty, "a listing with a skipped record cannot prove the space is gone")
        let kept = try rig.store.space(rig.team)
        #expect(kept?.isHidden == false)

        rig.tamper.setSkipped(0)
        let complete = try await rig.engine.syncSpaces(rig.generation)
        #expect(complete.removed == [rig.team])
        let hidden = try rig.store.space(rig.team)
        #expect(hidden?.isHidden == true)
    }
}
