import ChatModel
import Foundation
import SQLite3
import Testing

@testable import ChatStore

private let canary = "CANARY-7f3a"

private func fileModes(of directory: AccountDirectory) throws -> [String: Int] {
    let manager = FileManager.default
    var urls = [
        directory.root, directory.root.appendingPathComponent("accounts"), directory.accountURL, directory.mediaURL,
        directory.storeURL,
    ]
    for suffix in ["-wal", "-shm"] {
        let url = URL(fileURLWithPath: directory.storeURL.path + suffix)
        if manager.fileExists(atPath: url.path) { urls.append(url) }
    }
    var modes: [String: Int] = [:]
    for url in urls {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        modes[url.lastPathComponent] = (attributes[.posixPermissions] as! NSNumber).intValue
    }
    return modes
}

func storeBytes(_ directory: AccountDirectory) -> Data {
    var all = Data()
    for suffix in ["", "-wal", "-shm"] {
        all.append((try? Data(contentsOf: URL(fileURLWithPath: directory.storeURL.path + suffix))) ?? Data())
    }
    return all
}

func withRawConnection<T>(_ f: Fixture, _ body: (Connection) throws -> T) throws -> T {
    f.closeSQLite()
    let raw = try Connection(path: f.directory.storeURL.path)
    defer { raw.close() }
    return try body(raw)
}

private func populateEveryTable(_ f: Fixture) throws {
    let a = spaceName("A")
    let member = Membership(
        name: MembershipName(unchecked: "spaces/A/members/1"),
        member: User(name: UserName(unchecked: "users/1"), displayName: "Ann \(canary)"))
    var space = makeSpace("A", name: "General \(canary)")
    space.createTime = stamp(1)
    try f.commit(
        .mergeSpace(space),
        .upsertMessages([richMessage(canary: canary), makeMessage(id: "plain", at: 5, text: canary)]),
        .setMembers(a, [member], title: "Ann \(canary)", fetched: stamp(3)),
        .setNotificationSetting(a, SpaceNotificationSetting(level: .all, isMuted: false)),
        .putDraft(Draft(space: a, thread: nil, text: "draft \(canary)", updated: stamp(4))),
        .putDraft(Draft(space: a, thread: threadName("A", "t1"), text: "reply draft \(canary)", updated: stamp(4))),
        .putOutbox(
            OutboxItem(
                space: a,
                payload: OutboxPayload(text: "send \(canary)", thread: nil, attachmentUploadTokens: [canary]),
                state: .failed(reason: "failed \(canary)"), created: stamp(6))),
        .setMeta(key: "profile", value: "meta \(canary)"), .setReadState(a, stamp(7)),
        .setThreadReadState(threadName("A", "t1"), stamp(8)), .setCheckpoint(a, .messages, stamp(9)),
        .markNotified([messageName("A", "plain")], at: stamp(10)))
}

@Suite struct SQLiteStoreTests {
    @Test func nothingHumanReadableIsStoredInPlaintext() throws {
        let f = try Fixture(.sqlite)
        try populateEveryTable(f)
        let canaryBytes = Data(canary.utf8)

        let whileOpen = storeBytes(f.directory)
        #expect(whileOpen.count > 4096)
        #expect(whileOpen.range(of: canaryBytes) == nil)
        #expect(whileOpen.range(of: Data("spaces/A/messages/plain".utf8)) != nil)

        f.closeSQLite()
        let afterClose = storeBytes(f.directory)
        #expect(afterClose.range(of: canaryBytes) == nil)
        #expect(afterClose.range(of: Data("spaces/A/messages/plain".utf8)) != nil)

        try f.reopenSQLite()
        #expect(try f.store.message(messageName("A", "plain"))?.text == canary)
        #expect(try f.store.meta("profile") == "meta \(canary)")
    }

    @Test func deletedRowsLeaveNoPlaintextResidue() throws {
        let f = try Fixture(.sqlite)
        try populateEveryTable(f)
        try f.commit(.deleteSpace(spaceName("A")), .setMeta(key: "profile", value: nil))
        f.closeSQLite()
        #expect(storeBytes(f.directory).range(of: Data(canary.utf8)) == nil)
    }

    @Test func swappingSealedPayloadsBetweenRowsFails() throws {
        let f = try Fixture(.sqlite)
        try f.commit(
            .upsertMessages([makeMessage(id: "m1", at: 1, text: "one"), makeMessage(id: "m2", at: 2, text: "two")]),
            .mergeSpace(makeSpace("A")), .mergeSpace(makeSpace("B")), .setMeta(key: "k", value: "v"),
            .putDraft(Draft(space: spaceName("A"), thread: nil, text: "d", updated: stamp(1))))
        try withRawConnection(f) { raw in
            try raw.execute(
                "UPDATE messages SET payload = (SELECT payload FROM messages WHERE name = 'spaces/A/messages/m1') "
                    + "WHERE name = 'spaces/A/messages/m2'")
            try raw.execute(
                "UPDATE spaces SET payload = (SELECT payload FROM spaces WHERE name = 'spaces/A') "
                    + "WHERE name = 'spaces/B'")
            try raw.execute("UPDATE meta SET payload = (SELECT payload FROM drafts LIMIT 1) WHERE key = 'k'")
        }
        try f.reopenSQLite()
        #expect(try f.store.message(messageName("A", "m1"))?.text == "one")
        #expect(throws: StoreError.crypto(.authenticationFailed)) { try f.store.message(messageName("A", "m2")) }
        #expect(throws: StoreError.crypto(.authenticationFailed)) { try f.store.spaces() }
        #expect(throws: StoreError.crypto(.authenticationFailed)) { try f.store.meta("k") }
    }

    @Test func corruptRowFailsTheReadInsteadOfBeingSkipped() throws {
        let f = try Fixture(.sqlite)
        try f.commit(.upsertMessages((1...3).map { makeMessage(id: "m\($0)", at: Int64($0)) }))
        try withRawConnection(f) { raw in
            let blob = try #require(
                try raw.prepare("SELECT payload FROM messages WHERE name = 'spaces/A/messages/m2'").first { $0.blob(0) }
            )
            var tampered = blob
            tampered[tampered.count - 1] ^= 0x01
            try raw.prepare("UPDATE messages SET payload = ?1 WHERE name = 'spaces/A/messages/m2'").run([
                .blob(tampered)
            ])
        }
        try f.reopenSQLite()
        #expect(throws: StoreError.crypto(.authenticationFailed)) {
            try f.store.messages(in: spaceName("A"), before: nil, limit: 10)
        }
        #expect(try f.store.message(messageName("A", "m1")) != nil)
    }

    @Test func wrongKeyIsRejected() throws {
        let f = try Fixture(.sqlite)
        try f.commit(.setMeta(key: "k", value: "secret"))
        f.closeSQLite()
        let wrong = StoreKey.random(for: f.account)
        #expect(throws: StoreError.crypto(.authenticationFailed)) {
            try SQLiteAccountStore.open(directory: f.directory, key: wrong)
        }
        #expect(throws: StoreError.crypto(.authenticationFailed)) {
            try SQLiteAccountStore.open(directory: f.directory, key: StoreKey.random(for: AccountID()))
        }
        try f.reopenSQLite()
        #expect(try f.store.meta("k") == "secret")
    }

    @Test func rowsStayUnreadableWithAWrongKeyEvenWithoutTheKeyCheck() throws {
        let f = try Fixture(.sqlite)
        try f.commit(.setMeta(key: "k", value: "secret"), .upsertMessages([makeMessage(id: "m", at: 1)]))
        try withRawConnection(f) { try $0.execute("DELETE FROM key_check") }
        let other = try SQLiteAccountStore.open(directory: f.directory, key: StoreKey.random(for: f.account))
        #expect(throws: StoreError.crypto(.authenticationFailed)) { try other.meta("k") }
        #expect(throws: StoreError.crypto(.authenticationFailed)) { try other.message(messageName("A", "m")) }
        other.close()
    }

    @Test func failedBatchRollsBackEveryOperation() throws {
        let f = try Fixture(.sqlite)
        try f.commit(.mergeSpace(makeSpace("A")), .setMeta(key: "keep", value: "1"))
        try withRawConnection(f) { try $0.execute("UPDATE spaces SET payload = zeroblob(64)") }
        try f.reopenSQLite()

        #expect(throws: StoreError.crypto(.malformed)) {
            try f.commit(
                .setMeta(key: "a", value: "written"), .upsertMessages([makeMessage(id: "m", at: 1)]),
                .setCheckpoint(spaceName("A"), .messages, stamp(5)),
                .putDraft(Draft(space: spaceName("A"), thread: nil, text: "x", updated: stamp(1))),
                .setNotificationSetting(spaceName("A"), nil), .setMeta(key: "b", value: "after"))
        }
        #expect(try f.store.meta("a") == nil)
        #expect(try f.store.meta("b") == nil)
        #expect(try f.store.meta("keep") == "1")
        #expect(try f.store.message(messageName("A", "m")) == nil)
        #expect(try f.store.checkpoint(spaceName("A"), .messages) == nil)
        #expect(try f.store.drafts().isEmpty)

        try f.commit(.setMeta(key: "after-failure", value: "ok"))
        #expect(try f.store.meta("after-failure") == "ok")
    }

    @Test func fileAndDirectoryPermissionsAreOwnerOnly() throws {
        let f = try Fixture(.sqlite)
        try populateEveryTable(f)
        let modes = try fileModes(of: f.directory)
        #expect(modes["accounts"] == 0o700)
        #expect(modes[f.account.description] == 0o700)
        #expect(modes["media"] == 0o700)
        #expect(modes["store.sqlite"] == 0o600)
        for (name, mode) in modes where name.hasSuffix("-wal") || name.hasSuffix("-shm") { #expect(mode == 0o600) }

        try f.reopenSQLite()
        #expect(try fileModes(of: f.directory)["store.sqlite"] == 0o600)
        #expect(try fileModes(of: f.directory)["media"] == 0o700)
    }

    @Test func newerSchemaThanKnownIsRefused() throws {
        let f = try Fixture(.sqlite)
        try f.commit(.setMeta(key: "k", value: "v"))
        try withRawConnection(f) { try $0.execute("PRAGMA user_version = 99") }
        #expect(throws: StoreError.schemaTooNew(99)) { try SQLiteAccountStore.open(directory: f.directory, key: f.key) }
        #expect(try withRawConnection(f) { try $0.userVersion() } == 99)
    }

    @Test func reopeningPersistsEverything() throws {
        let f = try Fixture(.sqlite)
        try populateEveryTable(f)
        let spaces = try f.store.spaces()
        let rich = try #require(try f.store.message(messageName("A", "rich")))
        try f.reopenSQLite()

        #expect(try f.store.spaces() == spaces)
        #expect(spaces.first?.lastReadTime == stamp(7))
        #expect(spaces.first?.memberTitle == "Ann \(canary)")
        #expect(try f.store.message(messageName("A", "rich")) == rich)
        #expect(try f.store.messages(in: spaceName("A"), before: nil, limit: 10).count == 2)
        #expect(try f.store.members(in: spaceName("A")).count == 1)
        #expect(try f.store.drafts().count == 2)
        #expect(try f.store.outbox().count == 1)
        #expect(try f.store.meta("profile") == "meta \(canary)")
        #expect(try f.store.checkpoint(spaceName("A"), .messages) == stamp(9))
        #expect(try f.store.threadReadState(threadName("A", "t1")) == stamp(8))
        #expect(try f.store.isNotified(messageName("A", "plain")))
        try f.reopenSQLite()
        #expect(try f.store.spaces() == spaces)
    }

    @Test func databaseIsInWalModeAtLatestVersion() throws {
        let f = try Fixture(.sqlite)
        try f.commit(.setMeta(key: "k", value: "v"))
        let journal = try withRawConnection(f) { try $0.prepare("PRAGMA journal_mode").first { $0.text(0) } }
        let version = try withRawConnection(f) { try $0.userVersion() }
        #expect(journal == "wal")
        #expect(version == SQLiteAccountStore.migrations().count)
    }

    @Test func closedStoreFailsInsteadOfCrashing() throws {
        let f = try Fixture(.sqlite)
        f.closeSQLite()
        #expect(throws: StoreError.sqlite(code: SQLITE_MISUSE)) { try f.store.meta("k") }
        #expect(throws: StoreError.sqlite(code: SQLITE_MISUSE)) { try f.commit(.setMeta(key: "k", value: "v")) }
    }

    @Test func openingAGarbageFileFailsWithoutLeakingContent() throws {
        let temp = TempDirectory()
        let account = AccountID()
        let directory = AccountDirectory(root: temp.url, account: account)
        try directory.create()
        try Data(repeating: 0x41, count: 4096).write(to: directory.storeURL)
        do {
            _ = try SQLiteAccountStore.open(directory: directory, key: .random(for: account))
            Issue.record("expected failure")
        } catch {
            #expect(error == .sqlite(code: SQLITE_NOTADB))
        }
    }
}

@Suite struct SQLiteMigrationTests {
    private static let frozenV1 = """
        CREATE TABLE key_check (id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1), payload BLOB NOT NULL) STRICT;
        CREATE TABLE spaces (
            name TEXT PRIMARY KEY NOT NULL, is_hidden INTEGER NOT NULL DEFAULT 0, payload BLOB NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE messages (
            name TEXT PRIMARY KEY NOT NULL, space TEXT NOT NULL, thread TEXT, create_s INTEGER NOT NULL,
            create_n INTEGER NOT NULL, version_s INTEGER NOT NULL, version_n INTEGER NOT NULL,
            is_deleted INTEGER NOT NULL, payload BLOB NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX messages_by_space ON messages (space, create_s, create_n, name);
        CREATE INDEX messages_by_thread ON messages (thread, create_s, create_n, name);
        CREATE TABLE members (
            space TEXT PRIMARY KEY NOT NULL, fetched_s INTEGER NOT NULL, fetched_n INTEGER NOT NULL,
            payload BLOB NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE drafts (
            key TEXT PRIMARY KEY NOT NULL, space TEXT NOT NULL, updated_s INTEGER NOT NULL,
            updated_n INTEGER NOT NULL, payload BLOB NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX drafts_by_space ON drafts (space);
        CREATE TABLE read_state (
            scope TEXT PRIMARY KEY NOT NULL, space TEXT NOT NULL, read_s INTEGER NOT NULL, read_n INTEGER NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX read_state_by_space ON read_state (space);
        CREATE TABLE sync_checkpoints (
            space TEXT NOT NULL, stream TEXT NOT NULL, value_s INTEGER NOT NULL, value_n INTEGER NOT NULL,
            PRIMARY KEY (space, stream)
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE outbox (
            id TEXT PRIMARY KEY NOT NULL, space TEXT NOT NULL, created_s INTEGER NOT NULL, created_n INTEGER NOT NULL,
            payload BLOB NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE notified (
            message TEXT PRIMARY KEY NOT NULL, space TEXT NOT NULL, at_s INTEGER NOT NULL, at_n INTEGER NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX notified_by_space ON notified (space);
        CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL) STRICT, WITHOUT ROWID;
        PRAGMA user_version = 1;
        """

    @Test func opensAHandBuiltVersionOneDatabase() throws {
        let temp = TempDirectory()
        let account = AccountID()
        let key = StoreKey.random(for: account)
        let directory = AccountDirectory(root: temp.url, account: account)
        try directory.create()

        let raw = try Connection(path: directory.storeURL.path)
        try raw.execute(Self.frozenV1)
        let sealed = RowSealer(key).seal(try JSONEncoder().encode("hello"), table: "meta", rowKey: "greeting")
        try raw.prepare("INSERT INTO meta (key, payload) VALUES (?1, ?2)").run([.text("greeting"), .blob(sealed)])
        raw.close()

        let store = try SQLiteAccountStore.open(directory: directory, key: key)
        #expect(try store.meta("greeting") == "hello")
        let gate = SessionGate()
        try store.write(gate: gate, generation: gate.current!) {
            $0.append(.upsertMessages([makeMessage(id: "m", at: 1)]))
            $0.append(.mergeSpace(makeSpace()))
        }
        #expect(try store.message(messageName("A", "m")) != nil)
        store.close()
    }

    @Test func appliesPendingMigrationsInOrderAndKeepsData() throws {
        let f = try Fixture(.sqlite)
        try f.commit(.setMeta(key: "k", value: "kept"))
        f.closeSQLite()

        let migrations: [SQLiteAccountStore.Migration] =
            SQLiteAccountStore.migrations() + [
                { try $0.execute("CREATE TABLE extra (id INTEGER PRIMARY KEY NOT NULL, note TEXT)") },
                { try $0.execute("INSERT INTO extra (id, note) VALUES (1, 'second')") },
            ]
        let store = try SQLiteAccountStore.open(directory: f.directory, key: f.key, migrations: migrations)
        #expect(try store.meta("k") == "kept")
        store.close()

        let raw = try Connection(path: f.directory.storeURL.path)
        #expect(try raw.userVersion() == SQLiteAccountStore.migrations().count + 2)
        #expect(try raw.prepare("SELECT note FROM extra WHERE id = 1").first { $0.text(0) } == "second")
        raw.close()

        let again = try SQLiteAccountStore.open(directory: f.directory, key: f.key, migrations: migrations)
        #expect(try again.meta("k") == "kept")
        again.close()
    }

    @Test func aFailingMigrationRollsBackAndLeavesTheVersion() throws {
        let f = try Fixture(.sqlite)
        try f.commit(.setMeta(key: "k", value: "kept"))
        f.closeSQLite()

        let broken: [SQLiteAccountStore.Migration] =
            SQLiteAccountStore.migrations() + [
                { connection in
                    try connection.execute("CREATE TABLE half_done (id INTEGER)")
                    throw StoreError.sqlite(code: SQLITE_ERROR)
                }
            ]
        #expect(throws: StoreError.sqlite(code: SQLITE_ERROR)) {
            try SQLiteAccountStore.open(directory: f.directory, key: f.key, migrations: broken)
        }

        let raw = try Connection(path: f.directory.storeURL.path)
        #expect(try raw.userVersion() == SQLiteAccountStore.migrations().count)
        #expect(try raw.prepare("SELECT name FROM sqlite_master WHERE name = 'half_done'").first { $0.text(0) } == nil)
        raw.close()

        try f.reopenSQLite()
        #expect(try f.store.meta("k") == "kept")
    }
}
