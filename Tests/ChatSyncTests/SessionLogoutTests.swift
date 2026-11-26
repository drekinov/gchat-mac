import ChatKeychain
import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatSync

struct LogoutRig: Sendable {
    let scratch = ScratchDirectory()
    let account = AccountID()
    let directory: AccountDirectory
    let secrets = InMemorySecretStore()
    let tombstones: LogoutTombstones
    let gate = SessionGate()
    let eraser: TestEraser
    let revoker: RecordingRevoker
    let server = FakeChatServer()
    let user: FakeAccount
    let space: SpaceName
    let store: SQLiteAccountStore
    let session: AccountSession
    let recorder: SnapshotRecorder

    init(timing: SessionTiming = .fast) throws {
        directory = AccountDirectory(root: scratch.url, account: account)
        tombstones = LogoutTombstones(root: scratch.url)
        eraser = TestEraser(directory: directory, secrets: secrets, tombstones: tombstones, gate: gate)
        revoker = RecordingRevoker(eraser: eraser)

        try directory.createExports()
        try Data("export".utf8).write(to: directory.exportsURL.appendingPathComponent("doc.txt"))
        let (key, _) = try eraser.lifecycle.open(for: account, storeExists: false)
        store = try SQLiteAccountStore.open(directory: directory, key: try #require(key))
        try secrets.write(Data("refresh-token".utf8), for: eraser.credentialID)

        user = server.addAccount(displayName: "Alice")
        space = server.addSpace(.space, displayName: "Team", members: [user])
        server.post("hello", in: space, from: .user(User(name: UserName(unchecked: "users/42"), displayName: "Zed")))
        server.advance(.seconds(5))

        session = AccountSession(
            account: account, me: user.user.name,
            api: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: user.token)),
            store: store, clock: RealSleepClock(server: server),
            logoutRunner: LogoutRunner(eraser: eraser, tombstones: tombstones), revoker: revoker, gate: gate,
            timing: timing)
        recorder = SnapshotRecorder(session.snapshots.values)
    }

    var storeKeyID: SecretID { StoreKeyLifecycle.secretID(for: account) }

    func startAndSync() async -> Bool {
        await session.start()
        let space = space
        return await recorder.wait { $0.status == .ok && $0.spaces.contains { $0.name == space } } != nil
    }

    func assertNothingLeft() {
        #expect(!exists(directory.accountURL), "account directory")
        #expect(!exists(directory.exportsURL), "exports")
        #expect(!exists(directory.storeURL), "store file")
        #expect(secrets.storedIDs.isEmpty, "keychain items: \(secrets.storedIDs)")
        #expect(!tombstones.isPending(account))
        #expect((try? tombstones.pending())?.isEmpty == true)
    }
}

struct SessionLogoutTests {
    @Test func logoutRunsEveryStepInOrderAndLeavesNothingBehind() async throws {
        let rig = try LogoutRig()
        #expect(await rig.startAndSync())
        #expect(exists(rig.directory.storeURL))
        #expect(!rig.secrets.storedIDs.isEmpty)
        let old = try #require(rig.gate.current)

        let report = await rig.session.logout(refreshToken: "rt-captured")

        #expect(report.failedSteps.isEmpty)
        #expect(report.aborted == false)
        let events = rig.eraser.observations.all
        #expect(
            events.map(\.name) == [
                "wipeExports", "removeNotifications", "shredStoreKey", "deleteCredentials", "deleteAccountFiles",
                "unregister", "revoke",
            ])
        let steps = events.dropLast()
        #expect(steps.allSatisfy { $0.tombstonePending }, "the tombstone must exist for the whole local run")
        #expect(steps.allSatisfy { $0.gate == .closing })
        let revoke = try #require(events.last)
        #expect(!revoke.accountFilesExist, "revoke ran before local cleanup finished")
        #expect(!revoke.tombstonePending)
        #expect(rig.revoker.tokens.all == ["rt-captured"])

        rig.assertNothingLeft()
        #expect(rig.gate.snapshot.1 == .closed)
        #expect(rig.gate.current == nil)
        #expect(rig.gate.isCurrent(old) == false)

        #expect(await rig.recorder.waitForFinish(), "snapshots.values must finish after logout")
        let history = rig.recorder.history
        let closing = try #require(history.firstIndex { $0.status == .closing })
        #expect(closing == history.count - 1, "snapshots after the closing one: \(history.count - closing - 1)")
        #expect(history[closing...].allSatisfy { $0.generation > old })
        #expect(history[..<closing].allSatisfy { $0.generation == old })
        #expect(history[closing].spaces.isEmpty)
    }

    @Test func logoutWithoutAnyTokenSkipsRevoke() async throws {
        let rig = try LogoutRig()
        #expect(await rig.startAndSync())
        let report = await rig.session.logout(refreshToken: nil)
        #expect(report.failedSteps.isEmpty)
        #expect(rig.revoker.tokens.all.isEmpty)
        rig.assertNothingLeft()
    }

    @Test func failedStepStaysInTheTombstoneAndRevokeStillRuns() async throws {
        let rig = try LogoutRig()
        #expect(await rig.startAndSync())
        rig.eraser.setFailing([.deleteCredentials])

        let report = await rig.session.logout(refreshToken: "rt")

        #expect(report.failedSteps == [.deleteCredentials])
        #expect(
            try rig.tombstones.pending() == [
                LogoutTombstones.Tombstone(account: rig.account, remaining: [.deleteCredentials])
            ])
        #expect(rig.secrets.storedIDs == [rig.eraser.credentialID])
        #expect(!exists(rig.directory.accountURL))
        #expect(rig.revoker.tokens.all == ["rt"])
        #expect(rig.gate.snapshot.1 == .closed)
    }

    @Test func boundedDrainReturnsEvenWhenATaskIgnoresCancellation() async throws {
        let rig = try LogoutRig()
        #expect(await rig.startAndSync())
        let old = try #require(rig.gate.current)
        let stuck = UncancellableWait()
        defer { stuck.release() }
        let arrived = Recorder<Int>()
        let attempt = Recorder<String>()
        let store = rig.store
        let gate = rig.gate
        let spawned = await rig.session.spawnRegistered { [stuck] in
            arrived.append(1)
            await stuck.wait()
            do throws(StoreError) {
                try store.write(gate: gate, generation: old) { $0.append(.setMeta(key: "straggler", value: "x")) }
                attempt.append("committed")
            } catch {
                attempt.append("rejected:\(error)")
            }
        }
        #expect(spawned)
        #expect(await poll { arrived.all.count == 1 })

        // Returns while the task is still held; the wait's own 60 s release is only a hang guard.
        let report = await rig.session.logout(refreshToken: "rt")
        #expect(report.drained == false)
        #expect(report.failedSteps.isEmpty)
        #expect(rig.gate.snapshot.1 == .closed)
        #expect(attempt.all.isEmpty, "the stuck task hasn't tried its write yet")

        stuck.release()
        #expect(await poll { attempt.all.count == 1 })
        #expect(attempt.all == ["rejected:gateClosed"])
        rig.assertNothingLeft()
    }

    @Test func nothingCanBeStartedAfterLogout() async throws {
        let rig = try LogoutRig()
        #expect(await rig.startAndSync())
        _ = await rig.session.logout(refreshToken: nil)

        await #expect(throws: SyncError.retired) { _ = try await rig.session.send("late", in: rig.space, thread: nil) }
        await #expect(throws: SyncError.retired) {
            try await rig.session.saveDraft(Draft(space: rig.space, thread: nil, text: "x", updated: .init(seconds: 1)))
        }
        let spawned = await rig.session.spawnRegistered {}
        #expect(spawned == false)
        rig.assertNothingLeft()
    }

    @Test func aLogoutThatCannotWriteItsTombstoneAbortsAndLeavesTheSessionActive() async throws {
        let rig = try LogoutRig()
        #expect(await rig.startAndSync())
        let marker = rig.scratch.url.appendingPathComponent("logout-pending")
        try Data("in the way".utf8).write(to: marker)
        let old = try #require(rig.gate.current)
        let seen = rig.recorder.history.count

        let report = await rig.session.logout(refreshToken: "rt")

        #expect(report.aborted)
        #expect(rig.eraser.observations.all.isEmpty, "no local step may run without a tombstone")
        #expect(rig.revoker.tokens.all.isEmpty)
        #expect(rig.gate.current == old, "the generation must not be retired")
        #expect(rig.gate.snapshot.1 == .active)
        #expect(exists(rig.directory.storeURL))
        #expect(!rig.secrets.storedIDs.isEmpty)
        #expect(rig.recorder.history.dropFirst(seen).allSatisfy { $0.status != .closing && $0.generation == old })
        #expect(!rig.recorder.isFinished)

        try FileManager.default.removeItem(at: marker)
        let retry = await rig.session.logout(refreshToken: "rt")
        #expect(retry.aborted == false)
        #expect(retry.failedSteps.isEmpty)
        rig.assertNothingLeft()
    }
}
