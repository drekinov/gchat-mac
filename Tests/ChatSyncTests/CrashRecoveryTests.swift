import ChatKeychain
import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

/// Two accounts on disk and in the keychain double: `victim` is mid-logout, `healthy` must not be touched.
struct CrashRig: Sendable {
    struct Artifacts: Sendable {
        var record: AccountRecord
        var directory: AccountDirectory
        var eraser: TestEraser
    }

    let scratch = ScratchDirectory()
    let secrets = InMemorySecretStore()
    let tombstones: LogoutTombstones
    let registry: AccountRegistry
    let victim: Artifacts
    let healthy: Artifacts
    let created = Recorder<AccountID>()

    init() throws {
        tombstones = LogoutTombstones(root: scratch.url)
        registry = AccountRegistry(secrets: secrets)
        var made: [Artifacts] = []
        for name in ["victim", "healthy"] {
            let record = AccountRecord(
                email: "\(name)@example.test", displayName: name,
                me: UserName(unchecked: "users/\(made.count + 1)"))
            let directory = AccountDirectory(root: scratch.url, account: record.id)
            let eraser = TestEraser(directory: directory, secrets: secrets, tombstones: tombstones)
            let (key, _) = try eraser.lifecycle.open(for: record.id, storeExists: false)
            let store = try SQLiteAccountStore.open(directory: directory, key: try #require(key))
            let gate = SessionGate()
            try store.write(gate: gate, generation: gate.current!) { $0.append(.setMeta(key: "k", value: "v")) }
            store.close()
            try directory.createExports()
            try Data("export".utf8).write(to: directory.exportsURL.appendingPathComponent("doc.txt"))
            try secrets.write(Data("refresh".utf8), for: eraser.credentialID)
            made.append(Artifacts(record: record, directory: directory, eraser: eraser))
        }
        victim = made[0]
        healthy = made[1]
        try registry.upsert(victim.record)
        try registry.upsert(healthy.record)
    }

    func writeFullTombstone() throws {
        try tombstones.write(.init(account: victim.record.id, remaining: LogoutStep.allCases))
    }

    func recovery(failing: Set<LogoutStep> = []) -> (LogoutRecovery, TestEraser) {
        let eraser = TestEraser(directory: victim.directory, secrets: secrets, tombstones: tombstones)
        eraser.setFailing(failing)
        return (LogoutRecovery(runner: LogoutRunner(eraser: eraser, tombstones: tombstones)), eraser)
    }

    /// A manager whose sessions live in `world`; their token is unknown to the server, so they stop at sign-in.
    func manager(recovery: LogoutRecovery, in world: SimWorld) -> AccountManager {
        let created = created
        let tombstones = tombstones
        return AccountManager(
            registry: registry, recovery: recovery, tombstones: tombstones,
            factory: { record in
                created.append(record.id)
                let session = AccountSession(
                    account: record.id, me: record.me,
                    api: GoogleChatClient(transport: world.transport(), tokens: StaticTokens(token: "none")),
                    store: InMemoryAccountStore(), clock: world.clock(),
                    logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: tombstones), timing: .lifecycle,
                    executor: world.executor)
                world.lifecycleRetireAtTeardown(session, keeping: scratch)
                return session
            })
    }

    /// Lets the restored sessions run until they are idle, then logs each one out.
    func shutdown(_ manager: AccountManager, in world: SimWorld) async throws {
        await world.settle()
        for session in await manager.sessions.values {
            #expect(await session.status == .needsLogin, "a restored session is started and gets as far as sign-in")
            let report = try await world.lifecycleLogout(session)
            #expect(report.drained)
        }
        #expect(world.sleeperDeadlines.isEmpty, "a session outlived its logout")
    }

    func expectVictimErased() {
        #expect(!exists(victim.directory.accountURL), "account directory")
        #expect(!exists(victim.directory.exportsURL), "exports")
        #expect(!secrets.storedIDs.contains(StoreKeyLifecycle.secretID(for: victim.record.id)), "store key")
        #expect(!secrets.storedIDs.contains(victim.eraser.credentialID), "credential")
        #expect(!tombstones.isPending(victim.record.id), "tombstone")
    }

    func expectHealthyUntouched() {
        #expect(exists(healthy.directory.storeURL))
        #expect(exists(healthy.directory.exportsURL))
        #expect(secrets.storedIDs.contains(StoreKeyLifecycle.secretID(for: healthy.record.id)))
        #expect(secrets.storedIDs.contains(healthy.eraser.credentialID))
    }
}

struct CrashRecoveryTests {
    @Test(arguments: 0...LogoutStep.allCases.count)
    func recoveryFinishesALogoutThatCrashedAfterKLocalSteps(completedSteps k: Int) async throws {
        let rig = try CrashRig()
        try rig.writeFullTombstone()
        for step in LogoutStep.allCases.prefix(k) { try await rig.victim.eraser.perform(step) }
        if (3..<5).contains(k) {
            let state = try rig.victim.eraser.lifecycle.open(for: rig.victim.record.id, storeExists: true).1
            #expect(state == .storeShredded, "a shredded key beside a store must be reported, not regenerated")
        }
        #expect(rig.tombstones.isPending(rig.victim.record.id))

        let (recovery, _) = rig.recovery()
        let incomplete = try await recovery.recover()

        #expect(incomplete.isEmpty)
        rig.expectVictimErased()
        rig.expectHealthyUntouched()
        #expect(try rig.registry.load().map(\.id) == [rig.healthy.record.id], "unregister is a logout step")
    }

    @Test(arguments: 0...LogoutStep.allCases.count)
    func startupFinishesTheLogoutDropsTheAccountAndRestoresTheOther(completedSteps k: Int) async throws {
        try await SimWorld.run { world in
            let rig = try CrashRig()
            try rig.writeFullTombstone()
            for step in LogoutStep.allCases.prefix(k) { try await rig.victim.eraser.perform(step) }

            let (recovery, _) = rig.recovery()
            let manager = rig.manager(recovery: recovery, in: world)
            let report = try await manager.startup()
            #expect(await Array(manager.sessions.keys) == [rig.healthy.record.id])
            try await rig.shutdown(manager, in: world)

            #expect(report.incompleteLogouts.isEmpty)
            #expect(report.restored == [rig.healthy.record.id])
            #expect(report.failed.isEmpty)
            #expect(rig.created.all == [rig.healthy.record.id], "the interrupted account must never get a session")
            #expect(try rig.registry.load().map(\.id) == [rig.healthy.record.id])
            rig.expectVictimErased()
            rig.expectHealthyUntouched()
        }
    }

    @Test(arguments: 0...LogoutStep.allCases.count)
    func recoverThenStartupDoesNotResurrectTheAccount(completedSteps k: Int) async throws {
        try await SimWorld.run { world in
            let rig = try CrashRig()
            try rig.writeFullTombstone()
            for step in LogoutStep.allCases.prefix(k) { try await rig.victim.eraser.perform(step) }

            let (recovery, _) = rig.recovery()
            let incomplete = try await recovery.recover()
            #expect(incomplete.isEmpty)
            let manager = rig.manager(recovery: recovery, in: world)
            let report = try await manager.startup()
            try await rig.shutdown(manager, in: world)

            rig.expectVictimErased()
            rig.expectHealthyUntouched()
            #expect(report.incompleteLogouts.isEmpty)
            #expect(report.restored == [rig.healthy.record.id])
            #expect(rig.created.all == [rig.healthy.record.id], "the interrupted account must never get a session")
            #expect(try rig.registry.load().map(\.id) == [rig.healthy.record.id])
        }
    }

    @Test(arguments: [
        [LogoutStep.wipeExports], [.shredStoreKey], [.deleteCredentials], [.deleteAccountFiles],
        [.unregister], [.wipeExports, .deleteCredentials], [.shredStoreKey, .deleteAccountFiles],
        [.deleteAccountFiles, .unregister],
    ])
    func aStepThatKeepsFailingLeavesOnlyItselfInTheTombstone(failing: [LogoutStep]) async throws {
        try await SimWorld.run { world in
            let rig = try CrashRig()
            try rig.writeFullTombstone()

            let (recovery, stubborn) = rig.recovery(failing: Set(failing))
            let manager = rig.manager(recovery: recovery, in: world)
            let report = try await manager.startup()
            try await rig.shutdown(manager, in: world)

            let victim = rig.victim.record.id
            let expectedRemaining = LogoutStep.allCases.filter(failing.contains)
            #expect(report.incompleteLogouts == [victim])
            #expect(report.restored == [rig.healthy.record.id])
            #expect(rig.created.all == [rig.healthy.record.id])
            #expect(try rig.registry.load().map(\.id) == [rig.healthy.record.id])
            #expect(try rig.tombstones.pending() == [.init(account: victim, remaining: expectedRemaining)])
            rig.expectHealthyUntouched()

            stubborn.setFailing([])
            let next = rig.manager(
                recovery: LogoutRecovery(runner: LogoutRunner(eraser: stubborn, tombstones: rig.tombstones)),
                in: world)
            let second = try await next.startup()
            try await rig.shutdown(next, in: world)

            #expect(second.incompleteLogouts.isEmpty)
            #expect(second.restored == [rig.healthy.record.id])
            rig.expectVictimErased()
            rig.expectHealthyUntouched()
        }
    }

    @Test func recoveryIsIdempotentWhenRunTwice() async throws {
        let rig = try CrashRig()
        try rig.writeFullTombstone()
        let (recovery, _) = rig.recovery()
        let first = try await recovery.recover()
        let second = try await recovery.recover()
        #expect(first.isEmpty && second.isEmpty)
        rig.expectVictimErased()
        rig.expectHealthyUntouched()
    }

    @Test func aMissingStoreKeyBesideAStoreIsNeverRegenerated() throws {
        let rig = try CrashRig()
        let id = rig.victim.record.id
        try rig.victim.eraser.shredStoreKey(id)
        let before = rig.secrets.storedIDs
        let (key, state) = try rig.victim.eraser.lifecycle.open(for: id, storeExists: true)
        #expect(key == nil)
        #expect(state == .storeShredded)
        #expect(rig.secrets.storedIDs == before)
    }

    @Test func anUnreadableTombstoneRerunsEveryStep() async throws {
        let rig = try CrashRig()
        let marker = rig.tombstones.url(for: rig.victim.record.id)
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: marker)

        let pending = try rig.tombstones.pending()
        #expect(pending == [.init(account: rig.victim.record.id, remaining: LogoutStep.allCases)])

        let (recovery, _) = rig.recovery()
        let incomplete = try await recovery.recover()
        #expect(incomplete.isEmpty)
        rig.expectVictimErased()
        rig.expectHealthyUntouched()
    }

    @Test func startupFailsClosedWhenTheTombstoneDirectoryCannotBeRead() async throws {
        try await SimWorld.run { world in
            let rig = try CrashRig()
            try rig.writeFullTombstone()
            let directory = rig.tombstones.url(for: rig.victim.record.id).deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

            let (recovery, _) = rig.recovery()
            let manager = rig.manager(recovery: recovery, in: world)
            await #expect(throws: (any Error).self) { _ = try await manager.startup() }

            #expect(rig.created.all.isEmpty, "no session may start while a logout might be pending")
            #expect(await manager.sessions.isEmpty)
            #expect(exists(rig.victim.directory.storeURL), "nothing may be erased or restored on a guess")
        }
    }
}
