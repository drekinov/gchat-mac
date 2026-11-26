import ChatKeychain
import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

struct DailyUseTests {
    @Test func reconnectKeepsDraftAndRequestIDAndRemovalErasesOnlyThatAccount() async throws {
        try await SimWorld.run { world in
            let rig = try CrashRig()
            let attachments = rig.scratch.url.appending(path: "uploads")
            let eraser = LocalAccountEraser(
                root: rig.scratch.url, secrets: rig.secrets, registry: rig.registry,
                credentialID: TestEraser.credentialID, stagedFilesRoots: [attachments], notificationRemover: { _ in })
            let runner = LogoutRunner(eraser: eraser, tombstones: rig.tombstones)
            let manager = AccountManager(
                registry: rig.registry, recovery: LogoutRecovery(runner: runner), tombstones: rig.tombstones
            ) { record in
                let directory = AccountDirectory(root: rig.scratch.url, account: record.id)
                let lifecycle = StoreKeyLifecycle(secrets: rig.secrets)
                let key = try #require(try lifecycle.open(for: record.id, storeExists: true).0)
                let session = AccountSession(
                    account: record.id, me: record.me,
                    api: GoogleChatClient(transport: world.transport(), tokens: StaticTokens(token: "offline")),
                    store: try SQLiteAccountStore.open(directory: directory, key: key), clock: world.clock(),
                    logoutRunner: runner, timing: .lifecycle, executor: world.executor)
                await session.setPaused(true)
                world.lifecycleRetireAtTeardown(session)
                return session
            }
            _ = try await manager.startup()
            let start = world.now
            let id = rig.victim.record.id
            let other = rig.healthy.record.id
            let previous = try #require(await manager.session(id))
            let healthy = try #require(await manager.session(other))
            let space = SpaceName(unchecked: "spaces/A")
            let draft = Draft(space: space, thread: nil, text: "unsent draft", updated: world.now)
            let send = try await previous.send("queued", in: space, thread: nil)
            try await previous.saveDraft(draft)
            let originalKey = try rig.secrets.read(StoreKeyLifecycle.secretID(for: id))
            await world.settle()

            await #expect(throws: StepFailureError.self) {
                try await world.lifecyclePerform { try await manager.reconnect(id) { throw StepFailureError() } }
            }
            #expect(previous.gate.current != nil)
            #expect(await manager.session(id) === previous)
            let session = try await world.lifecyclePerform {
                try await manager.reconnect(id) {
                    try rig.secrets.write(Data("new grant".utf8), for: rig.victim.eraser.credentialID)
                }
            }
            #expect(previous.gate.current == nil)
            #expect(session !== previous)
            #expect(session.account == id)
            #expect(try session.draft(space: space, thread: nil) == draft)
            #expect(try session.outbox(in: space).map(\.requestID) == [send.requestID])
            #expect(try rig.secrets.read(StoreKeyLifecycle.secretID(for: id)) == originalKey)
            #expect(await manager.session(other) === healthy)

            for account in [id, other] {
                try FileManager.default.createDirectory(
                    at: attachments.appending(path: account.description), withIntermediateDirectories: true)
            }
            let report = try await world.lifecyclePerform { try await manager.logout(id, refreshToken: nil) }
            #expect(report.failedSteps.isEmpty)
            #expect(report.drained)
            #expect(!exists(attachments.appending(path: id.description)))
            #expect(exists(attachments.appending(path: other.description)))
            rig.expectVictimErased()
            rig.expectHealthyUntouched()
            #expect(try rig.registry.load().map(\.id) == [other])
            _ = try await world.lifecyclePerform { try await manager.logout(other, refreshToken: nil) }
            #expect(world.now == start, "a reconnect or logout waited out its drain")
            #expect(world.sleeperDeadlines.isEmpty, "a retired session is still waiting on the clock")
        }
    }

    @Test func failedRestoreCanBeRemovedWithoutCreatingASession() async throws {
        let rig = try CrashRig()
        let manager = AccountManager(
            registry: rig.registry, recovery: rig.recovery().0, tombstones: rig.tombstones
        ) { _ in throw StepFailureError() }
        let startup = try await manager.startup()
        #expect(startup.failed.contains(rig.victim.record.id))
        let report = try await manager.logout(rig.victim.record.id, refreshToken: nil)
        #expect(report.failedSteps.isEmpty)
        rig.expectVictimErased()
        rig.expectHealthyUntouched()
    }

    @Test func historicalSearchHitOpensInThreadContextWithoutChangingReadState() async throws {
        try await LogoutRig.run { rig in
            let root = rig.server.post("root", in: rig.space, from: .account(rig.user))
            let thread = try #require(root.thread)
            let hit = rig.server.post("needle", in: rig.space, from: .account(rig.user), thread: thread)
            let reply = rig.server.post("later reply", in: rig.space, from: .account(rig.user), thread: thread)
            for _ in 0..<210 { rig.server.post("other conversation", in: rig.space, from: .account(rig.user)) }
            let page = try await rig.session.searchMessages("needle", pageToken: nil)
            #expect(page.items.map(\.name) == [hit.name])
            let messages = try await rig.session.searchContext(around: hit)
            #expect(messages.map(\.name) == [root.name, hit.name, reply.name])
            #expect(rig.server.requests.allSatisfy { $0.method != "PATCH" })
            #expect(try rig.session.messages(in: rig.space).isEmpty)
        }
    }

    @Test func olderMessagesPageBackFromAFixedBoundaryWithoutStoringAnything() async throws {
        try await LogoutRig.run { rig in
            let posted = (0..<120).map { rig.server.post("message \($0)", in: rig.space, from: .account(rig.user)) }
            let boundary = posted[100].createTime.adding(.microseconds(1))
            let first = try await rig.session.olderMessages(in: rig.space, before: boundary, pageToken: nil)
            #expect(first.items.map(\.name) == posted[51...100].map(\.name))
            let token = try #require(first.nextPageToken)
            let second = try await rig.session.olderMessages(in: rig.space, before: boundary, pageToken: token)
            #expect(second.items.map(\.name) == posted[1...50].map(\.name))
            let last = try await rig.session.olderMessages(
                in: rig.space, before: boundary, pageToken: try #require(second.nextPageToken))
            #expect(last.items.last?.name == posted[0].name)
            #expect(last.nextPageToken == nil)
            #expect(try rig.session.messages(in: rig.space).isEmpty)
        }
    }
}
