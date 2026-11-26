import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

/// One account whose session is never started, so only the work a test asks for runs.
private struct DraftRig {
    let server: FakeChatServer
    let alice: FakeAccount
    let store = InMemoryAccountStore()
    let session: AccountSession
    let team: SpaceName

    init(_ world: SimWorld) {
        server = world.server
        alice = server.addAccount(displayName: "Alice")
        team = server.addSpace(.space, displayName: "Team", members: [alice])
        server.advance(.seconds(5))
        session = world.syncSession(alice, store: store)
    }

    var generation: Generation { session.gate.current! }
}

struct DraftSessionTests {
    @Test func aSecondRepostOfTheSameFailedReplyQueuesNothing() async throws {
        try await SimWorld.run { world in
            let rig = DraftRig(world)
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
            await world.settle()
            #expect(try rig.store.outbox().map(\.id) == [try #require(first).id], "one item replaced the failed one")
        }
    }

    @Test func aFailedSendPublishesItsRecoveredDraft() async throws {
        try await SimWorld.run { world in
            let rig = DraftRig(world)
            rig.server.fail(
                FailureRule(route: .createMessage, response: .http(status: 400, googleStatus: "INVALID_ARGUMENT")))

            try await rig.session.send("bounced", in: rig.team, thread: nil)
            await world.settle()
            #expect(rig.session.snapshots.current?.draftRevision == 1)
            #expect(try rig.store.drafts().first?.text == "bounced")
        }
    }
}
