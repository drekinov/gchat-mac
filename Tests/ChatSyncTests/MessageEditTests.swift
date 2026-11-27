import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

/// One account whose session is never started: the only tasks are the ones an edit or a delete starts.
private struct EditRig: Sendable {
    let world: SimWorld
    let server: FakeChatServer
    let alice: FakeAccount
    let bob: FakeAccount
    let store = InMemoryAccountStore()
    let session: AccountSession
    let team: SpaceName

    init(_ world: SimWorld, followUpPolls: [Duration] = []) {
        self.world = world
        server = world.server
        alice = server.addAccount(displayName: "Alice")
        bob = server.addAccount(displayName: "Bob")
        team = server.addSpace(.space, displayName: "Team", members: [alice, bob])
        var timing = SessionTiming.syncParked
        timing.deleteReconcileDelays = followUpPolls
        session = world.syncSession(alice, store: store, timing: timing)
    }

    static func run(
        followUpPolls: [Duration] = [], _ body: @escaping @Sendable (EditRig) async throws -> Void
    ) async throws {
        try await SimWorld.run { world in try await body(EditRig(world, followUpPolls: followUpPolls)) }
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

    /// Runs the delete to its end, letting time pass when it has to wait out the write spacing.
    func delete(_ name: MessageName, force: Bool = false) async throws {
        let session = session
        try await world.syncAttempt { () async throws(MessageEditError) in
            try await session.deleteMessage(name, force: force)
        }.get()
    }

    func edit(_ name: MessageName, text: String, basedOn: Timestamp) async throws -> Message {
        let session = session
        return try await world.syncAttempt { () async throws(MessageEditError) in
            try await session.editMessage(name, text: text, basedOn: basedOn)
        }.get()
    }

    func stored(_ name: MessageName) throws -> Message? { try store.message(name) }

    func requests(_ method: String) -> [RecordedRequest] {
        server.requests.filter { $0.method == method && $0.account == alice }
    }

    var eventPolls: [RecordedRequest] { requests("GET").filter { $0.path.hasSuffix("/spaceEvents") } }
}

struct MessageEditTests {
    @Test func anEditIsSentWithItsMentionAndStored() async throws {
        try await EditRig.run { rig in
            let mine = rig.post("helo", from: rig.alice)
            try await rig.sync()
            let copy = try await rig.session.editableCopy(of: mine.name)
            #expect(copy.message.formattedText == nil)

            let wire = "hello <\(rig.bob.user.name.rawValue)>"
            let updated = try await rig.edit(mine.name, text: wire, basedOn: copy.message.version)
            #expect(updated.text == "hello @Bob")
            #expect(updated.lastUpdateTime != nil)
            #expect(updated.annotations.contains { $0.kind == .userMention(rig.bob.user.name) })
            #expect(try rig.stored(mine.name)?.text == "hello @Bob")
            #expect(try rig.stored(mine.name)?.formattedText == wire)
            #expect(rig.requests("PATCH").first?.value(for: "updateMask") == "text")
        }
    }

    @Test func anEditMadeElsewhereAfterEditingStartedIsNotOverwritten() async throws {
        try await EditRig.run { rig in
            let mine = rig.post("first", from: rig.alice)
            try await rig.sync()
            let copy = try await rig.session.editableCopy(of: mine.name)
            rig.server.edit(mine.name, text: "changed on the web")
            rig.server.advance(.seconds(5))

            await #expect(throws: MessageEditError.self) {
                try await rig.edit(mine.name, text: "mine", basedOn: copy.message.version)
            }
            #expect(rig.requests("PATCH").isEmpty)
        }
    }

    @Test func anOlderStoredCopyNeverBeatsANewerSyncedEdit() async throws {
        try await EditRig.run { rig in
            let mine = rig.post("first", from: rig.alice)
            try await rig.sync()
            var newer = try #require(try rig.stored(mine.name))
            newer.text = "newer"
            newer.lastUpdateTime = rig.server.now.adding(.seconds(60))
            let edited = newer
            try rig.store.write(gate: rig.session.gate, generation: rig.generation) {
                $0.append(.upsertMessages([edited]))
            }
            do {
                _ = try await rig.edit(mine.name, text: "stale", basedOn: mine.version)
                Issue.record("expected changedElsewhere")
            } catch MessageEditError.changedElsewhere(let latest) {
                #expect(latest.text == "newer")
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }

    @Test func deletingOwnMessageLeavesATombstoneThatGooglesReplaces() async throws {
        try await EditRig.run { rig in
            let root = rig.post("root", from: rig.bob)
            let reply = rig.post("my reply", from: rig.alice, thread: root.thread)
            try await rig.sync()

            try await rig.delete(reply.name)
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
    }

    @Test func aManagerDeletesSomeoneElsesMessageAndAMemberIsRefused() async throws {
        try await EditRig.run { rig in
            let theirs = rig.post("bob's", from: rig.bob)
            try await rig.sync()

            await #expect(throws: MessageEditError.denied, "a member can't delete others' messages") {
                try await rig.delete(theirs.name)
            }
            #expect(try rig.stored(theirs.name)?.isDeleted == false)

            rig.server.setRole(.assistantManager, of: rig.alice, in: rig.team)
            try await rig.delete(theirs.name)
            #expect(try rig.stored(theirs.name)?.isDeleted == true)
        }
    }

    @Test func aManagerRefusedByGoogleKeepsTheMessage() async throws {
        try await EditRig.run { rig in
            let theirs = rig.post("bob's", from: rig.bob)
            try await rig.sync()
            rig.server.setRole(.manager, of: rig.alice, in: rig.team)
            rig.server.fail(
                FailureRule(
                    route: .deleteMessage, response: .http(status: 403, googleStatus: "PERMISSION_DENIED")))
            await #expect(throws: MessageEditError.denied) {
                try await rig.delete(theirs.name)
            }
            #expect(try rig.stored(theirs.name)?.isDeleted == false)
        }
    }

    @Test func aThreadStarterWithRepliesNeedsForceAndTakesItsRepliesAlong() async throws {
        try await EditRig.run { rig in
            let root = rig.post("my root", from: rig.alice)
            let reply = rig.post("reply", from: rig.bob, thread: root.thread)
            try await rig.sync()

            await #expect(throws: MessageEditError.hasReplies) {
                try await rig.delete(root.name)
            }
            #expect(try rig.stored(root.name)?.isDeleted == false)

            try await rig.delete(root.name, force: true)
            #expect(try rig.stored(root.name)?.isDeleted == true)
            #expect(try rig.stored(reply.name)?.isDeleted == true)
            #expect(rig.requests("DELETE").last?.value(for: "force") == "true")
        }
    }

    @Test func aLateLiveCopyDoesNotBringADeletedMessageBack() async throws {
        try await EditRig.run { rig in
            let mine = rig.post("gone soon", from: rig.alice)
            try await rig.sync()
            let before = try #require(try rig.stored(mine.name))
            try await rig.delete(mine.name)
            var late = before
            late.text = "late edit"
            late.lastUpdateTime = rig.server.now.adding(.seconds(30))
            let copy = late
            try rig.store.write(gate: rig.session.gate, generation: rig.generation) {
                $0.append(.upsertMessages([copy]))
            }
            #expect(try rig.stored(mine.name)?.isDeleted == true)
        }
    }

    @Test func nothingIsRequestedWhileTheAccountIsPaused() async throws {
        try await EditRig.run { rig in
            let mine = rig.post("x", from: rig.alice)
            try await rig.sync()
            await rig.session.setPaused(true)
            let before = rig.server.requests.count
            await #expect(throws: MessageEditError.notAdmitted) {
                try await rig.delete(mine.name)
            }
            await #expect(throws: MessageEditError.notAdmitted) {
                _ = try await rig.edit(mine.name, text: "y", basedOn: mine.version)
            }
            await rig.world.settle()
            #expect(rig.server.requests.count == before)
            #expect(try rig.stored(mine.name)?.text == "x")
        }
    }

    @Test func aDeleteThatSucceededIsReportedEvenIfTheFollowUpPollFails() async throws {
        try await EditRig.run(followUpPolls: [.seconds(3)]) { rig in
            let mine = rig.post("x", from: rig.alice)
            try await rig.sync()
            rig.server.fail(
                FailureRule(
                    route: .listSpaceEvents, times: nil, response: .http(status: 500, googleStatus: "INTERNAL")))
            try await rig.delete(mine.name)
            #expect(try rig.stored(mine.name)?.isDeleted == true)
            #expect(rig.eventPolls.isEmpty)

            await rig.world.pass(.seconds(3))
            #expect(rig.eventPolls.map(\.status) == [500], "the follow-up poll ran and failed")
            #expect(try rig.stored(mine.name)?.isDeleted == true)
            #expect(await rig.session.retryUntil == nil, "a failed follow-up poll doesn't back the account off")
        }
    }

    @Test func aRetriedFollowUpPollBringsGooglesTombstone() async throws {
        try await EditRig.run(followUpPolls: [.seconds(3), .seconds(10), .seconds(30)]) { rig in
            let mine = rig.post("x", from: rig.alice)
            try await rig.sync()
            rig.server.fail(
                FailureRule(route: .listSpaceEvents, times: 1, response: .http(status: 500, googleStatus: "INTERNAL")))
            try await rig.delete(mine.name)
            let local = try #require(try rig.stored(mine.name))
            #expect(rig.eventPolls.isEmpty, "the first follow-up poll waits")

            await rig.world.pass(.seconds(3))
            #expect(rig.eventPolls.map(\.status) == [500])
            #expect(try rig.stored(mine.name)?.version == local.version, "the failed poll changed nothing")

            await rig.world.pass(.seconds(10))
            #expect(rig.eventPolls.map(\.status) == [500, 200])
            #expect(try #require(try rig.stored(mine.name)).version > local.version)
            #expect(rig.world.sleeperDeadlines.isEmpty, "a poll that ran ends the follow-ups")
        }
    }

    @Test func pausingDuringPacingStopsTheWrite() async throws {
        try await EditRig.run { rig in
            let world = rig.world
            let mine = rig.post("x", from: rig.alice)
            let other = rig.post("y", from: rig.alice)
            try await rig.sync()
            try await rig.delete(mine.name)
            let session = rig.session
            let second = world.syncStart { () async throws(MessageEditError) in
                try await session.deleteMessage(other.name, force: false)
            }
            await world.settle()
            #expect(!second.isFinished)
            // Nothing else sleeps here: the session loop isn't running and no follow-up polls are set.
            let sleepers = world.sleeperDeadlines
            try #require(sleepers.count == 1, "the second delete waits out the spacing")
            let paced = sleepers[0]
            #expect(paced > world.now && paced <= world.now.adding(SendQueue.spacing))

            await rig.session.setPaused(true)
            await world.jump(to: paced)
            try #require(second.isFinished)
            await #expect(throws: MessageEditError.notAdmitted) { try await second.value.get() }
            #expect(rig.requests("DELETE").count == 1)
            #expect(try rig.stored(other.name)?.isDeleted == false)
        }
    }
}
