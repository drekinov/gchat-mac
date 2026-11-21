import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

private struct EditRig {
    let server = FakeChatServer()
    let alice: FakeAccount
    let bob: FakeAccount
    let store = InMemoryAccountStore()
    let session: AccountSession
    let team: SpaceName
    let scratch = ScratchDirectory()

    init(timing: SessionTiming = EditRig.timing) async throws {
        alice = server.addAccount(displayName: "Alice")
        bob = server.addAccount(displayName: "Bob")
        team = server.addSpace(.space, displayName: "Team", members: [alice, bob])
        session = AccountSession(
            account: AccountID(), me: alice.user.name,
            api: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token)),
            store: store, clock: SteppingClock(server: server),
            logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: scratch.url)),
            timing: timing)
    }

    /// No follow-up polls, so each test decides when Google's tombstones arrive.
    static var timing: SessionTiming {
        var timing = SessionTiming.fast
        timing.deleteReconcileDelays = []
        return timing
    }

    var generation: Generation { session.gate.current! }

    func post(_ text: String, from account: FakeAccount, thread: ThreadName? = nil) -> Message {
        let message = server.post(text, in: team, from: .account(account), thread: thread)
        server.advance(.seconds(5))
        return message
    }

    func sync() async throws {
        _ = try await session.engine.syncSpaces(generation)
        try await session.engine.syncMessages(team, generation)
    }

    func stored(_ name: MessageName) throws -> Message? { try store.message(name) }

    func requests(_ method: String) -> [RecordedRequest] {
        server.requests.filter { $0.method == method && $0.account == alice }
    }
}

struct MessageEditTests {
    @Test func anEditIsSentWithItsMentionAndStored() async throws {
        let rig = try await EditRig()
        let mine = rig.post("helo", from: rig.alice)
        try await rig.sync()
        let copy = try await rig.session.editableCopy(of: mine.name)
        #expect(!copy.losesFormatting)

        let wire = "hello <\(rig.bob.user.name.rawValue)>"
        let updated = try await rig.session.editMessage(mine.name, text: wire, basedOn: copy.message.version)
        #expect(updated.text == "hello @Bob")
        #expect(updated.lastUpdateTime != nil)
        #expect(updated.annotations.contains { $0.kind == .userMention(rig.bob.user.name) })
        #expect(try rig.stored(mine.name)?.text == "hello @Bob")
        #expect(rig.requests("PATCH").first?.value(for: "updateMask") == "text")
    }

    @Test func anEditMadeElsewhereAfterEditingStartedIsNotOverwritten() async throws {
        let rig = try await EditRig()
        let mine = rig.post("first", from: rig.alice)
        try await rig.sync()
        let copy = try await rig.session.editableCopy(of: mine.name)
        rig.server.edit(mine.name, text: "changed on the web")
        rig.server.advance(.seconds(5))

        await #expect(throws: MessageEditError.self) {
            try await rig.session.editMessage(mine.name, text: "mine", basedOn: copy.message.version)
        }
        #expect(rig.requests("PATCH").isEmpty)
    }

    @Test func anOlderStoredCopyNeverBeatsANewerSyncedEdit() async throws {
        let rig = try await EditRig()
        let mine = rig.post("first", from: rig.alice)
        try await rig.sync()
        var newer = try #require(try rig.stored(mine.name))
        newer.text = "newer"
        newer.lastUpdateTime = rig.server.now.adding(.seconds(60))
        try rig.store.write(gate: rig.session.gate, generation: rig.generation) {
            $0.append(.upsertMessages([newer]))
        }
        do {
            _ = try await rig.session.editMessage(mine.name, text: "stale", basedOn: mine.version)
            Issue.record("expected changedElsewhere")
        } catch .changedElsewhere(let latest) {
            #expect(latest.text == "newer")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func deletingOwnMessageLeavesATombstoneThatGooglesReplaces() async throws {
        let rig = try await EditRig()
        let root = rig.post("root", from: rig.bob)
        let reply = rig.post("my reply", from: rig.alice, thread: root.thread)
        try await rig.sync()

        try await rig.session.deleteMessage(reply.name, force: false)
        let local = try #require(try rig.stored(reply.name))
        #expect(local.isDeleted && local.text.isEmpty)

        rig.server.advance(.seconds(5))
        try await rig.session.engine.syncEvents(rig.team, rig.generation)
        let synced = try #require(try rig.stored(reply.name))
        #expect(synced.isDeleted)
        #expect(synced.thread == root.thread)
        #expect(synced.isThreadReply)
        #expect(synced.version > local.version)
    }

    @Test func aManagerDeletesSomeoneElsesMessageAndAMemberIsRefused() async throws {
        let rig = try await EditRig()
        let theirs = rig.post("bob's", from: rig.bob)
        try await rig.sync()

        do {
            try await rig.session.deleteMessage(theirs.name, force: false)
            Issue.record("a member shouldn't delete others' messages")
        } catch .denied {
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(try rig.stored(theirs.name)?.isDeleted == false)

        rig.server.setRole(.assistantManager, of: rig.alice, in: rig.team)
        try await rig.session.deleteMessage(theirs.name, force: false)
        #expect(try rig.stored(theirs.name)?.isDeleted == true)
    }

    @Test func aManagerRefusedByGoogleKeepsTheMessage() async throws {
        let rig = try await EditRig()
        let theirs = rig.post("bob's", from: rig.bob)
        try await rig.sync()
        rig.server.setRole(.manager, of: rig.alice, in: rig.team)
        rig.server.fail(
            FailureRule(
                route: .deleteMessage, response: .http(status: 403, googleStatus: "PERMISSION_DENIED")))
        await #expect(throws: MessageEditError.denied) {
            try await rig.session.deleteMessage(theirs.name, force: false)
        }
        #expect(try rig.stored(theirs.name)?.isDeleted == false)
    }

    @Test func aThreadStarterWithRepliesNeedsForceAndTakesItsRepliesAlong() async throws {
        let rig = try await EditRig()
        let root = rig.post("my root", from: rig.alice)
        let reply = rig.post("reply", from: rig.bob, thread: root.thread)
        try await rig.sync()

        await #expect(throws: MessageEditError.hasReplies) {
            try await rig.session.deleteMessage(root.name, force: false)
        }
        #expect(try rig.stored(root.name)?.isDeleted == false)

        try await rig.session.deleteMessage(root.name, force: true)
        #expect(try rig.stored(root.name)?.isDeleted == true)
        #expect(try rig.stored(reply.name)?.isDeleted == true)
        #expect(rig.requests("DELETE").last?.value(for: "force") == "true")
    }

    @Test func aLateLiveCopyDoesNotBringADeletedMessageBack() async throws {
        let rig = try await EditRig()
        let mine = rig.post("gone soon", from: rig.alice)
        try await rig.sync()
        let before = try #require(try rig.stored(mine.name))
        try await rig.session.deleteMessage(mine.name, force: false)
        var late = before
        late.text = "late edit"
        late.lastUpdateTime = rig.server.now.adding(.seconds(30))
        try rig.store.write(gate: rig.session.gate, generation: rig.generation) { $0.append(.upsertMessages([late])) }
        #expect(try rig.stored(mine.name)?.isDeleted == true)
    }

    @Test func nothingIsRequestedWhileTheAccountIsPaused() async throws {
        let rig = try await EditRig()
        let mine = rig.post("x", from: rig.alice)
        try await rig.sync()
        await rig.session.setPaused(true)
        let before = rig.server.requests.count
        await #expect(throws: MessageEditError.notAdmitted) {
            try await rig.session.deleteMessage(mine.name, force: false)
        }
        await #expect(throws: MessageEditError.notAdmitted) {
            try await rig.session.editMessage(mine.name, text: "y", basedOn: mine.version)
        }
        #expect(rig.server.requests.count == before)
    }

    @Test func aDeleteThatSucceededIsReportedEvenIfTheFollowUpPollFails() async throws {
        let rig = try await EditRig()
        let mine = rig.post("x", from: rig.alice)
        try await rig.sync()
        rig.server.fail(
            FailureRule(route: .listSpaceEvents, times: nil, response: .http(status: 500, googleStatus: "INTERNAL")))
        try await rig.session.deleteMessage(mine.name, force: false)
        #expect(try rig.stored(mine.name)?.isDeleted == true)
    }

    @Test func formattingOnlyGoogleHoldsIsDetected() {
        let me = User(name: UserName(unchecked: "users/1"))
        let bob = UserName(unchecked: "users/2")
        var message = Message(
            name: MessageName(unchecked: "spaces/A/messages/m"), sender: me, createTime: Timestamp(seconds: 1),
            text: "hi 🙂 @Bob see docs")
        message.annotations = [Annotation(kind: .userMention(bob), startIndex: 6, length: 4)]
        #expect(!AccountSession.losesFormatting(message, formattedText: "hi 🙂 <users/2> see docs"))
        #expect(AccountSession.losesFormatting(message, formattedText: "hi 🙂 <users/2> see <https://x.example|docs>"))
        #expect(!AccountSession.losesFormatting(message, formattedText: nil))
    }

    @Test func aRetriedFollowUpPollBringsGooglesTombstone() async throws {
        var timing = EditRig.timing
        timing.deleteReconcileDelays = [.seconds(3), .seconds(10)]
        let rig = try await EditRig(timing: timing)
        let mine = rig.post("x", from: rig.alice)
        try await rig.sync()
        rig.server.fail(
            FailureRule(route: .listSpaceEvents, times: 1, response: .http(status: 500, googleStatus: "INTERNAL")))
        try await rig.session.deleteMessage(mine.name, force: false)
        let local = try #require(try rig.stored(mine.name))
        for _ in 0..<200 where try rig.stored(mine.name)?.version == local.version {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try rig.stored(mine.name).map { $0.version > local.version } == true)
    }

    @Test func pausingDuringPacingStopsTheWrite() async throws {
        let rig = try await EditRig()
        let mine = rig.post("x", from: rig.alice)
        let other = rig.post("y", from: rig.alice)
        try await rig.sync()
        try await rig.session.deleteMessage(mine.name, force: false)
        let session = rig.session
        let second = Task { () async -> MessageEditError? in
            do {
                try await session.deleteMessage(other.name, force: false)
                return nil
            } catch {
                return error as? MessageEditError
            }
        }
        await rig.session.setPaused(true)
        #expect(await second.value == MessageEditError.notAdmitted)
        #expect(rig.requests("DELETE").count == 1)
    }
}
