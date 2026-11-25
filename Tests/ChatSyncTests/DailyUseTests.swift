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
        let rig = try CrashRig()
        let attachments = rig.scratch.url.appending(path: "uploads")
        let eraser = LocalAccountEraser(
            root: rig.scratch.url, secrets: rig.secrets, registry: rig.registry, credentialID: TestEraser.credentialID,
            stagedFilesRoots: [attachments], notificationRemover: { _ in })
        let runner = LogoutRunner(eraser: eraser, tombstones: rig.tombstones)
        let manager = AccountManager(
            registry: rig.registry, recovery: LogoutRecovery(runner: runner), tombstones: rig.tombstones
        ) { record in
            let directory = AccountDirectory(root: rig.scratch.url, account: record.id)
            let lifecycle = StoreKeyLifecycle(secrets: rig.secrets)
            let key = try #require(try lifecycle.open(for: record.id, storeExists: true).0)
            let session = AccountSession(
                account: record.id, me: record.me,
                api: GoogleChatClient(transport: rig.server.makeTransport(), tokens: StaticTokens(token: "offline")),
                store: try SQLiteAccountStore.open(directory: directory, key: key), clock: SystemClock(),
                logoutRunner: runner)
            await session.setPaused(true)
            return session
        }
        _ = try await manager.startup()
        let id = rig.victim.record.id
        let other = rig.healthy.record.id
        let previous = try #require(await manager.session(id))
        let healthy = try #require(await manager.session(other))
        let space = SpaceName(unchecked: "spaces/A")
        let draft = Draft(space: space, thread: nil, text: "unsent draft", updated: rig.server.now)
        let send = try await previous.send("queued", in: space, thread: nil)
        try await previous.saveDraft(draft)
        let originalKey = try rig.secrets.read(StoreKeyLifecycle.secretID(for: id))

        await #expect(throws: StepFailureError.self) {
            try await manager.reconnect(id) { throw StepFailureError() }
        }
        #expect(previous.gate.current != nil)
        let session = try await manager.reconnect(id) {
            try rig.secrets.write(Data("new grant".utf8), for: rig.victim.eraser.credentialID)
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
        let report = try await manager.logout(id, refreshToken: nil)
        #expect(report.failedSteps.isEmpty)
        #expect(!exists(attachments.appending(path: id.description)))
        #expect(exists(attachments.appending(path: other.description)))
        rig.expectVictimErased()
        rig.expectHealthyUntouched()
        #expect(try rig.registry.load().map(\.id) == [other])
        _ = try await manager.logout(other, refreshToken: nil)
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

    @Test func onlyAnOpenThreadAdvancesAndNewerRemoteReadStateWins() async throws {
        let rig = try SyncRig()
        try await rig.syncSpaces()
        let time = rig.first.createTime
        let position = ThreadReadPosition(thread: rig.thread, upTo: time)
        try await rig.engine.markThreadRead(position, rig.generation) { false }
        #expect(rig.server.requests.allSatisfy { $0.method != "PATCH" })
        try await rig.engine.markThreadRead(position, rig.generation) { true }
        #expect(try rig.store.threadReadState(rig.thread) == time)
        #expect(try await rig.engine.api.getThreadReadState(rig.thread) == time)
        let newer = rig.server.now
        rig.server.setThreadReadState(rig.alice, thread: rig.thread, lastReadTime: newer)
        try await rig.engine.markThreadRead(position, rig.generation) { true }
        #expect(try rig.store.threadReadState(rig.thread) == newer)
        #expect(rig.server.requests.filter { $0.method == "PATCH" }.count == 1)
    }

    @Test func searchPagesStayBoundToAccountAndQuery() async throws {
        let rig = try SyncRig()
        let server = rig.server
        let other = server.addSpace(.space, members: [rig.bob])
        server.post("needle hidden", in: other, from: .account(rig.bob))
        let old = server.post("needle first", in: rig.team, from: .account(rig.bob))
        let new = server.post("needle last", in: rig.team, from: .account(rig.alice))
        let api = rig.engine.api
        let page = try await api.searchMessages("needle", pageSize: 1, pageToken: nil)
        #expect(page.items.map(\.name) == [new.name])
        let token = try #require(page.nextPageToken)
        let next = try await api.searchMessages("needle", pageSize: 1, pageToken: token)
        #expect(next.items.map(\.name) == [old.name])
        #expect(next.nextPageToken == nil)
        await #expect(throws: ChatAPIError.self) {
            try await api.searchMessages("different", pageSize: 1, pageToken: token)
        }
        let bob = GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: rig.bob.token))
        await #expect(throws: ChatAPIError.self) {
            try await bob.searchMessages("needle", pageSize: 1, pageToken: token)
        }
    }

    @Test func historicalSearchHitOpensInThreadContextWithoutChangingReadState() async throws {
        let rig = try LogoutRig()
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

    @Test func olderMessagesPageBackFromAFixedBoundaryWithoutStoringAnything() async throws {
        let rig = try LogoutRig()
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
