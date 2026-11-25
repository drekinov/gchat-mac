import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

private struct DraftRig {
    let server = FakeChatServer()
    let alice: FakeAccount
    let store = InMemoryAccountStore()
    let session: AccountSession
    let team: SpaceName
    let scratch = ScratchDirectory()

    init() {
        alice = server.addAccount(displayName: "Alice")
        team = server.addSpace(.space, displayName: "Team", members: [alice])
        server.advance(.seconds(5))
        session = AccountSession(
            account: AccountID(), me: alice.user.name,
            api: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token)),
            store: store, clock: SteppingClock(server: server),
            logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: scratch.url)),
            timing: .fast)
    }

    var generation: Generation { session.gate.current! }
}

struct DraftSessionTests {
    @Test func aSecondRepostOfTheSameFailedReplyQueuesNothing() async throws {
        let rig = DraftRig()
        var failed = OutboxItem(
            space: rig.team,
            payload: OutboxPayload(
                text: "reply", thread: ThreadName(unchecked: "\(rig.team.rawValue)/threads/gone"),
                attachments: [draftFile("a.pdf")]),
            created: Timestamp(seconds: 1))
        failed.state = .failed(reason: "threadGone")
        let item = failed
        try rig.store.write(gate: rig.session.gate, generation: rig.generation) { $0.append(.putOutbox(item)) }

        let first = try await rig.session.repostAsNewMessage(failed)
        let second = try await rig.session.repostAsNewMessage(failed)

        #expect(first?.payload.attachments.map(\.filename) == ["a.pdf"])
        #expect(second == nil)
    }

    @Test func aFailedSendPublishesItsRecoveredDraft() async throws {
        let rig = DraftRig()
        rig.server.fail(
            FailureRule(route: .createMessage, response: .http(status: 400, googleStatus: "INVALID_ARGUMENT")))

        try await rig.session.send("bounced", in: rig.team, thread: nil)

        var published = false
        for _ in 0..<200 {
            if let snapshot = rig.session.snapshots.current, snapshot.draftRevision > 0 {
                published = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(published)
        #expect(try rig.store.drafts().first?.text == "bounced")
    }
}
