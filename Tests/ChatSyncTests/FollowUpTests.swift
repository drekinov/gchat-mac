import ChatKeychain
import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

/// Regression tests for sync, reactions and notifications.
struct FollowUpTests {
    // R1: the production eraser removes the registry entry, and a restart doesn't bring the account back.
    @Test func logoutThroughTheManagerRemovesThePersistedRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gchat-followup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemorySecretStore()
        let registry = AccountRegistry(secrets: secrets)
        let tombstones = LogoutTombstones(root: root)
        let credential: @Sendable (AccountID) -> SecretID = {
            SecretID(service: "test.credentials", account: $0.description)
        }
        let eraser = LocalAccountEraser(
            root: root, secrets: secrets, registry: registry, credentialID: credential, notificationRemover: { _ in })
        let runner = LogoutRunner(eraser: eraser, tombstones: tombstones)
        let server = FakeChatServer()
        let fake = server.addAccount(displayName: "Alice")
        let factory: AccountManager.SessionFactory = { record in
            AccountSession(
                account: record.id, me: record.me,
                api: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: fake.token)),
                store: InMemoryAccountStore(), clock: ServerClock(server: server), logoutRunner: runner)
        }
        let record = AccountRecord(email: "a@example.com", displayName: "Alice", me: fake.user.name)
        try secrets.write(Data("refresh".utf8), for: credential(record.id))

        let manager = AccountManager(
            registry: registry, recovery: LogoutRecovery(runner: runner), tombstones: tombstones, factory: factory)
        _ = try await manager.add(record)
        #expect(try registry.load().map(\.id) == [record.id])

        let report = try await manager.logout(record.id, refreshToken: nil)
        #expect(report.failedSteps.isEmpty)
        #expect(try registry.load().isEmpty)
        #expect(try secrets.read(credential(record.id)) == nil)
        #expect(try tombstones.pending().isEmpty)

        let restarted = AccountManager(
            registry: registry, recovery: LogoutRecovery(runner: runner), tombstones: tombstones, factory: factory)
        #expect(try await restarted.startup().restored.isEmpty)
    }

    // R2: an unreadable ancestor fails closed instead of looking like "no pending logouts".
    @Test func inaccessibleAncestorFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gchat-ancestor-\(UUID().uuidString)")
        let tombstones = LogoutTombstones(root: root)
        try tombstones.write(.init(account: AccountID(), remaining: LogoutStep.allCases))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(throws: (any Error).self) { try tombstones.pending() }
    }

    @Test func missingTombstoneDirectoryIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gchat-none-\(UUID().uuidString)")
        #expect(try LogoutTombstones(root: root).pending().isEmpty)
    }

    // R3: a committed send whose metadata fetch failed is resolved by the next message poll.
    @Test func pollingResolvesCommittedSends() async throws {
        let h = Harness()
        let team = h.server.addSpace(.space, displayName: "Team", members: [h.alice, h.bob])
        h.server.advance(.seconds(5))
        try await h.syncAll()

        let sent = h.server.post("hello", in: team, from: .account(h.alice))
        let item = OutboxItem(
            space: team, payload: OutboxPayload(text: "hello", thread: nil), state: .committed(sent.name),
            created: h.server.now)
        try h.store.write(gate: h.gate, generation: h.generation) { $0.append(.putOutbox(item)) }

        h.server.advance(.seconds(5))
        try await h.engine.syncMessages(team, h.generation)
        #expect(try h.store.outbox().isEmpty)
        #expect(try h.store.messages(in: team, before: nil, limit: 10).filter { $0.text == "hello" }.count == 1)
    }

    // N1: re-seeding doesn't delete a message committed after the seed's frozen end.
    @Test func reseedKeepsNewerRows() async throws {
        let h = Harness()
        let team = h.server.addSpace(.space, displayName: "Team", members: [h.alice, h.bob])
        h.server.post("old", in: team, from: .account(h.bob))
        h.server.advance(.seconds(5))
        let end = h.server.now.adding(.seconds(-2))
        h.server.advance(.seconds(5))
        let newer = h.server.post("newer", in: team, from: .account(h.bob))
        try h.store.write(gate: h.gate, generation: h.generation) { $0.append(.upsertMessages([newer])) }

        try await h.engine.seedWindow(team, end: end, h.generation)
        let texts = try h.store.messages(in: team, before: nil, limit: 10).map(\.text)
        #expect(texts == ["old", "newer"])
    }

    // N2: a chat hidden for having only deleted members comes back when a live member appears.
    @Test func anonymousHiddenChatRecoversWhenAMemberIsLive() async throws {
        let h = Harness()
        let ghost = User(name: UserName(unchecked: "users/9001"), isAnonymous: true)
        let chat = h.server.addSpace(.directMessage, members: [h.alice], users: [ghost])
        h.server.advance(.seconds(5))
        try await h.syncAll()
        try await h.engine.syncMemberTitle(chat, h.generation)
        #expect(try h.store.space(chat)?.isHidden == true)

        h.server.addMember(h.bob, to: chat)
        try await h.engine.syncMemberTitle(chat, h.generation)
        #expect(try h.store.space(chat)?.isHidden == false)
        #expect(try h.engine.isHiddenAnonymous(chat) == false)
        _ = try await h.engine.syncSpaces(h.generation)
        #expect(try h.store.space(chat)?.isHidden == false)
    }
}
