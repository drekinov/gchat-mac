import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatSync

/// The client's clock follows the fake server's, as a real clock follows real time.
struct ServerClock: SyncClock {
    let server: FakeChatServer
    func now() -> Timestamp { server.now }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: .milliseconds(1)) }
}

struct StaticTokens: TokenProvider {
    let token: String
    func accessToken() async throws(ChatAPIError) -> String { token }
    func invalidate(_ token: String) async {}
}

struct Harness {
    let server = FakeChatServer()
    let alice: FakeAccount
    let bob: FakeAccount
    let store = InMemoryAccountStore()
    let gate = SessionGate()
    let engine: SyncEngine
    let sends: SendQueue

    init() {
        alice = server.addAccount(displayName: "Alice")
        bob = server.addAccount(displayName: "Bob")
        let api = GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token))
        let clock = ServerClock(server: server)
        engine = SyncEngine(api: api, store: store, gate: gate, clock: clock, me: alice.user.name)
        sends = SendQueue(api: api, store: store, gate: gate, clock: clock)
    }

    var generation: Generation { gate.current! }

    func syncAll() async throws {
        let result = try await engine.syncSpaces(generation)
        for space in result.changed {
            try await engine.syncMessages(space, generation)
            try await engine.syncReadState(space, generation)
        }
    }
}

struct EndToEndTests {
    @Test func firstSyncSeedsSpacesMessagesAndUnread() async throws {
        let h = Harness()
        let team = h.server.addSpace(.space, displayName: "Team", members: [h.alice, h.bob])
        let dm = h.server.addSpace(.directMessage, members: [h.alice, h.bob])
        h.server.post("hi team", in: team, from: .account(h.bob))
        h.server.post("hey alice", in: dm, from: .account(h.bob))
        h.server.post("mine", in: dm, from: .account(h.alice))
        h.server.advance(.seconds(5))

        try await h.syncAll()
        try await h.engine.syncMemberTitle(dm, h.generation)

        let summaries = try h.engine.snapshotSpaces()
        #expect(Set(summaries.map(\.name)) == [team, dm])
        let dmSummary = try #require(summaries.first { $0.name == dm })
        #expect(dmSummary.title == "Bob")
        #expect(dmSummary.unreadCount == 1)
        #expect(try h.store.messages(in: team, before: nil, limit: 10).map(\.text) == ["hi team"])
    }

    @Test func catchUpEditsAndDeletesArriveThroughEvents() async throws {
        let h = Harness()
        let team = h.server.addSpace(.space, displayName: "Team", members: [h.alice, h.bob])
        let first = h.server.post("v1", in: team, from: .account(h.bob))
        let doomed = h.server.post("bye", in: team, from: .account(h.bob))
        h.server.advance(.seconds(5))
        try await h.syncAll()

        h.server.edit(first.name, text: "v2")
        h.server.delete(doomed.name)
        h.server.post("new", in: team, from: .account(h.bob))
        h.server.advance(.seconds(5))

        try await h.engine.syncMessages(team, h.generation)
        try await h.engine.syncEvents(team, h.generation)

        let stored = try h.store.messages(in: team, before: nil, limit: 10)
        #expect(stored.first { $0.name == first.name }?.text == "v2")
        #expect(stored.first { $0.name == doomed.name }?.isDeleted == true)
        #expect(stored.contains { $0.text == "new" })
    }

    @Test func pageTwoFailureLeavesCheckpointUnchanged() async throws {
        let h = Harness()
        let team = h.server.addSpace(.space, displayName: "Team", members: [h.alice, h.bob])
        h.server.post("seed", in: team, from: .account(h.bob))
        h.server.advance(.seconds(5))
        try await h.syncAll()
        let before = try h.store.checkpoint(team, .messages)

        for index in 0..<(SyncEngine.pageSize + 5) { h.server.post("m\(index)", in: team, from: .account(h.bob)) }
        h.server.advance(.seconds(5))
        h.server.fail(
            FailureRule(
                route: .listMessages, onlyWithPageToken: true, response: .http(status: 503, googleStatus: "UNAVAILABLE")
            ))

        await #expect(throws: SyncError.self) { try await h.engine.syncMessages(team, h.generation) }
        #expect(try h.store.checkpoint(team, .messages) == before)
        #expect(try h.store.messages(in: team, before: nil, limit: 1000).count == 1)

        try await h.engine.syncMessages(team, h.generation)
        #expect(try h.store.messages(in: team, before: nil, limit: 1000).count == SyncEngine.pageSize + 6)
    }

    @Test func lostSendResponseResolvesWithoutDuplicate() async throws {
        let h = Harness()
        let team = h.server.addSpace(.space, displayName: "Team", members: [h.alice, h.bob])
        h.server.fail(FailureRule(route: .createMessage, response: .commitThenNetworkError(.networkConnectionLost)))

        _ = try h.sends.enqueue(text: "hello", space: team, thread: nil, h.generation)
        let first = try #require(try await h.sends.drain(team, h.generation))
        #expect(first.values.allSatisfy { if case .willRetry = $0 { true } else { false } })
        #expect(try h.store.outbox().first?.state == .unknown)

        h.server.advance(.seconds(120))
        let second = try #require(try await h.sends.drain(team, h.generation))
        #expect(second.values.allSatisfy { if case .sent = $0 { true } else { false } })
        #expect(h.server.messages(in: team).filter { $0.text == "hello" }.count == 1)
        #expect(try h.store.outbox().isEmpty)
    }

    @Test func replyToDeletedThreadFailsAndRestoresDraft() async throws {
        let h = Harness()
        let team = h.server.addSpace(.space, displayName: "Team", members: [h.alice, h.bob])
        let ghost = try #require(ThreadName("spaces/\(team.id(at: 0))/threads/gone"))
        _ = try h.sends.enqueue(text: "reply", space: team, thread: ghost, h.generation)
        let outcomes = try #require(try await h.sends.drain(team, h.generation))
        #expect(outcomes.values.first == .failed(reason: "threadGone"))
        #expect(try h.store.drafts().first?.text == "reply")
        #expect(h.server.messages(in: team).isEmpty)
    }

    @Test func retiredGenerationCommitsNothing() async throws {
        let h = Harness()
        let team = h.server.addSpace(.space, displayName: "Team", members: [h.alice, h.bob])
        h.server.post("x", in: team, from: .account(h.bob))
        h.server.advance(.seconds(5))
        let old = h.generation
        h.gate.retire()
        await #expect(throws: SyncError.retired) { _ = try await h.engine.syncSpaces(old) }
        #expect(try h.store.spaces().isEmpty)
    }

    @Test func membershipLossHidesOnlyAfterCompleteListing() async throws {
        let h = Harness()
        let team = h.server.addSpace(.space, displayName: "Team", members: [h.alice, h.bob])
        h.server.advance(.seconds(5))
        try await h.syncAll()

        h.server.fail(
            FailureRule(route: .getSpaceReadState, response: .http(status: 403, googleStatus: "PERMISSION_DENIED")))
        await #expect(throws: SyncError.self) { try await h.engine.syncReadState(team, h.generation) }
        #expect(try h.store.space(team)?.isHidden == false)

        h.server.removeMember(h.alice, from: team)
        let result = try await h.engine.syncSpaces(h.generation)
        #expect(result.removed == [team])
        #expect(try h.store.space(team)?.isHidden == true)
    }
}
