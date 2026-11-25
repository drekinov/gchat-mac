import ChatModel
import Foundation
import SQLite3
import Synchronization

private struct SpacePayload: Codable {
    var space: Space
    var notificationSetting: SpaceNotificationSetting?
    var memberTitle: String?
    var memberTitleFetched: Timestamp?
}

private struct MembersPayload: Codable {
    var members: [Membership]
    var title: String?
}

private struct RowCodec: Sendable {
    let sealer: RowSealer

    func seal<T: Encodable>(_ value: T, table: String, rowKey: String) throws(StoreError) -> Data {
        let data: Data
        do { data = try JSONEncoder().encode(value) } catch { throw .crypto(.malformed) }
        return sealer.seal(data, table: table, rowKey: rowKey)
    }

    func open<T: Decodable>(_ sealed: Data, as type: T.Type, table: String, rowKey: String) throws(StoreError) -> T {
        let data: Data
        do throws(StoreCryptoError) { data = try sealer.open(sealed, table: table, rowKey: rowKey) } catch {
            throw .crypto(error)
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw .crypto(.malformed) }
    }
}

public final class SQLiteAccountStore: AccountStore {
    typealias Migration = (Connection) throws -> Void

    static let schemaV1 = """
        CREATE TABLE key_check (
            id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
            payload BLOB NOT NULL
        ) STRICT;
        CREATE TABLE spaces (
            name TEXT PRIMARY KEY NOT NULL,
            is_hidden INTEGER NOT NULL DEFAULT 0,
            payload BLOB NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE messages (
            name TEXT PRIMARY KEY NOT NULL,
            space TEXT NOT NULL,
            thread TEXT,
            create_s INTEGER NOT NULL,
            create_n INTEGER NOT NULL,
            version_s INTEGER NOT NULL,
            version_n INTEGER NOT NULL,
            is_deleted INTEGER NOT NULL,
            payload BLOB NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX messages_by_space ON messages (space, create_s, create_n, name);
        CREATE INDEX messages_by_thread ON messages (thread, create_s, create_n, name);
        CREATE TABLE members (
            space TEXT PRIMARY KEY NOT NULL,
            fetched_s INTEGER NOT NULL,
            fetched_n INTEGER NOT NULL,
            payload BLOB NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE drafts (
            key TEXT PRIMARY KEY NOT NULL,
            space TEXT NOT NULL,
            updated_s INTEGER NOT NULL,
            updated_n INTEGER NOT NULL,
            payload BLOB NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX drafts_by_space ON drafts (space);
        CREATE TABLE read_state (
            scope TEXT PRIMARY KEY NOT NULL,
            space TEXT NOT NULL,
            read_s INTEGER NOT NULL,
            read_n INTEGER NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX read_state_by_space ON read_state (space);
        CREATE TABLE sync_checkpoints (
            space TEXT NOT NULL,
            stream TEXT NOT NULL,
            value_s INTEGER NOT NULL,
            value_n INTEGER NOT NULL,
            PRIMARY KEY (space, stream)
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE outbox (
            id TEXT PRIMARY KEY NOT NULL,
            space TEXT NOT NULL,
            created_s INTEGER NOT NULL,
            created_n INTEGER NOT NULL,
            payload BLOB NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE notified (
            message TEXT PRIMARY KEY NOT NULL,
            space TEXT NOT NULL,
            at_s INTEGER NOT NULL,
            at_n INTEGER NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX notified_by_space ON notified (space);
        CREATE TABLE meta (
            key TEXT PRIMARY KEY NOT NULL,
            payload BLOB NOT NULL
        ) STRICT, WITHOUT ROWID;
        """

    static let schemaV2 = """
        CREATE TABLE media (
            media_hash TEXT PRIMARY KEY NOT NULL,
            bytes INTEGER NOT NULL,
            last_access_s INTEGER NOT NULL,
            payload BLOB NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX media_by_access ON media (last_access_s);
        """

    /// Forward-only; entry `i` upgrades the schema from `user_version` `i` to `i + 1`.
    static func migrations() -> [Migration] {
        [{ connection in try connection.execute(schemaV1) }, { connection in try connection.execute(schemaV2) }]
    }

    private let state: Mutex<Connection?>
    private let codec: RowCodec
    private let directory: AccountDirectory

    private init(connection: sending Connection, key: StoreKey, directory: AccountDirectory) {
        state = Mutex(connection)
        codec = RowCodec(sealer: RowSealer(key))
        self.directory = directory
    }

    public static func open(directory: AccountDirectory, key: StoreKey) throws(StoreError) -> SQLiteAccountStore {
        try open(directory: directory, key: key, migrations: migrations())
    }

    static func open(
        directory: AccountDirectory, key: StoreKey, migrations: [Migration]
    ) throws(StoreError) -> SQLiteAccountStore {
        guard key.account == directory.account else { throw .crypto(.authenticationFailed) }
        try directory.create()
        if !directory.storeExists() {
            guard FileManager.default.createFile(atPath: directory.storeURL.path, contents: nil) else {
                throw .io(code: Int(errno))
            }
        }
        try directory.restrictFile(directory.storeURL)

        let store = SQLiteAccountStore(
            connection: try Connection(path: directory.storeURL.path), key: key, directory: directory)
        try store.prepareDatabase(migrations: migrations)
        try store.restrictSidecarFiles()
        return store
    }

    private func prepareDatabase(migrations: [Migration]) throws(StoreError) {
        try withConnection { connection throws(StoreError) in
            try connection.configure()
            let current = try connection.userVersion()
            guard (0...migrations.count).contains(current) else { throw .schemaTooNew(current) }
            for version in current..<migrations.count {
                try connection.transaction { () throws(StoreError) in
                    do {
                        try migrations[version](connection)
                    } catch let error as StoreError {
                        throw error
                    } catch {
                        throw .io(code: (error as NSError).code)
                    }
                    try connection.execute("PRAGMA user_version = \(version + 1)")
                }
            }
            let table = "key_check"
            let select = try connection.prepare("SELECT payload FROM key_check WHERE id = 1")
            if let blob = try select.first([], { $0.blob(0) }) {
                _ = try self.codec.open(blob, as: String.self, table: table, rowKey: "1")
            } else {
                let sealed = try self.codec.seal("ok", table: table, rowKey: "1")
                try connection.prepare("INSERT INTO key_check (id, payload) VALUES (1, ?1)").run([.blob(sealed)])
            }
        }
    }

    private func restrictSidecarFiles() throws(StoreError) {
        for suffix in ["-wal", "-shm"] {
            let url = URL(fileURLWithPath: directory.storeURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) { try directory.restrictFile(url) }
        }
    }

    /// Further use fails with a SQLite misuse error.
    public func close() {
        state.withLock { connection in
            connection?.close()
            connection = nil
        }
    }

    private func withConnection<T: Sendable>(_ body: (Connection) throws(StoreError) -> T) throws(StoreError) -> T {
        try state.withLock { (slot) throws(StoreError) -> T in
            guard let connection = slot else { throw .sqlite(code: SQLITE_MISUSE) }
            return try body(connection)
        }
    }

    // MARK: Reads

    public func spaces() throws(StoreError) -> [StoredSpace] {
        try withConnection { connection throws(StoreError) in
            try self.querySpaces(connection, name: nil)
        }
    }

    public func space(_ name: SpaceName) throws(StoreError) -> StoredSpace? {
        try withConnection { connection throws(StoreError) in
            try self.querySpaces(connection, name: name).first
        }
    }

    private func querySpaces(_ connection: Connection, name: SpaceName?) throws(StoreError) -> [StoredSpace] {
        let statement = try connection.prepare(
            """
            SELECT s.name, s.is_hidden, s.payload, r.read_s, r.read_n
            FROM spaces s LEFT JOIN read_state r ON r.scope = s.name
            WHERE (?1 IS NULL OR s.name = ?1)
            ORDER BY s.name
            """)
        return try statement.rows([name.map { .text($0.rawValue) } ?? .null]) { row throws(StoreError) in
            let payload = try self.codec.open(
                row.blob(2), as: SpacePayload.self, table: "spaces", rowKey: row.text(0))
            return StoredSpace(
                space: payload.space, lastReadTime: try row.timestamp(3),
                notificationSetting: payload.notificationSetting, memberTitle: payload.memberTitle,
                memberTitleFetched: payload.memberTitleFetched, isHidden: row.int(1) != 0)
        }
    }

    public func messages(in space: SpaceName, before: Timestamp?, limit: Int) throws(StoreError) -> [Message] {
        guard limit > 0 else { return [] }
        return try withConnection { connection throws(StoreError) in
            let statement = try connection.prepare(
                """
                SELECT name, payload FROM messages
                WHERE space = ?1 AND (?2 IS NULL OR (create_s, create_n) < (?2, ?3))
                ORDER BY create_s DESC, create_n DESC, name DESC LIMIT ?4
                """)
            let values: [SQLValue] = [
                .text(space.rawValue), .seconds(before), .nanos(before), .int(Int64(limit)),
            ]
            return try self.decodeMessages(statement.rows(values) { ($0.text(0), $0.blob(1)) }).reversed()
        }
    }

    public func messages(inThread thread: ThreadName, limit: Int) throws(StoreError) -> [Message] {
        guard limit > 0 else { return [] }
        return try withConnection { connection throws(StoreError) in
            let statement = try connection.prepare(
                """
                SELECT name, payload FROM messages WHERE thread = ?1
                ORDER BY create_s DESC, create_n DESC, name DESC LIMIT ?2
                """)
            let values: [SQLValue] = [.text(thread.rawValue), .int(Int64(limit))]
            return try self.decodeMessages(statement.rows(values) { ($0.text(0), $0.blob(1)) }).reversed()
        }
    }

    public func message(_ name: MessageName) throws(StoreError) -> Message? {
        try withConnection { connection throws(StoreError) in
            let statement = try connection.prepare("SELECT name, payload FROM messages WHERE name = ?1")
            let row = try statement.first([.text(name.rawValue)]) { ($0.text(0), $0.blob(1)) }
            guard let row else { return nil }
            return try self.decodeMessages([row]).first
        }
    }

    private func decodeMessages(_ rows: [(String, Data)]) throws(StoreError) -> [Message] {
        var messages: [Message] = []
        messages.reserveCapacity(rows.count)
        for (name, blob) in rows {
            messages.append(try codec.open(blob, as: Message.self, table: "messages", rowKey: name))
        }
        return messages
    }

    public func checkpoint(_ space: SpaceName, _ stream: SyncStream) throws(StoreError) -> Timestamp? {
        try withConnection { connection throws(StoreError) in
            let statement = try connection.prepare(
                "SELECT value_s, value_n FROM sync_checkpoints WHERE space = ?1 AND stream = ?2")
            return try statement.first([.text(space.rawValue), .text(stream.rawValue)]) { row throws(StoreError) in
                try row.timestamp(0)
            }.flatMap { $0 }
        }
    }

    public func threadReadState(_ thread: ThreadName) throws(StoreError) -> Timestamp? {
        try withConnection { connection throws(StoreError) in
            let statement = try connection.prepare("SELECT read_s, read_n FROM read_state WHERE scope = ?1")
            return try statement.first([.text(thread.rawValue)]) { row throws(StoreError) in
                try row.timestamp(0)
            }.flatMap { $0 }
        }
    }

    public func members(in space: SpaceName) throws(StoreError) -> [Membership] {
        try withConnection { connection throws(StoreError) in
            try self.loadMembers(space, connection)?.payload.members ?? []
        }
    }

    public func drafts() throws(StoreError) -> [Draft] {
        try withConnection { connection throws(StoreError) in
            let statement = try connection.prepare("SELECT key, payload FROM drafts ORDER BY key")
            let rows = try statement.rows { ($0.text(0), $0.blob(1)) }
            return try rows.map { (key, blob) throws(StoreError) in
                try self.codec.open(blob, as: Draft.self, table: "drafts", rowKey: key)
            }
        }
    }

    public func outbox() throws(StoreError) -> [OutboxItem] {
        try withConnection { connection throws(StoreError) in
            let statement = try connection.prepare("SELECT id, payload FROM outbox ORDER BY created_s, created_n, id")
            let rows = try statement.rows { ($0.text(0), $0.blob(1)) }
            return try rows.map { (id, blob) throws(StoreError) in
                try self.codec.open(blob, as: OutboxItem.self, table: "outbox", rowKey: id)
            }
        }
    }

    public func isNotified(_ message: MessageName) throws(StoreError) -> Bool {
        try withConnection { connection throws(StoreError) in
            let statement = try connection.prepare("SELECT 1 FROM notified WHERE message = ?1")
            return try statement.first([.text(message.rawValue)]) { $0.int(0) } != nil
        }
    }

    public func meta(_ key: String) throws(StoreError) -> String? {
        try withConnection { connection throws(StoreError) in
            let statement = try connection.prepare("SELECT payload FROM meta WHERE key = ?1")
            guard let blob = try statement.first([.text(key)], { $0.blob(0) }) else { return nil }
            return try self.codec.open(blob, as: String.self, table: "meta", rowKey: key)
        }
    }

    public func metas(prefix: String) throws(StoreError) -> [String: String] {
        try withConnection { connection throws(StoreError) in
            let rows: [(String, Data)]
            if let upper = Self.upperBound(of: prefix) {
                rows = try connection.prepare("SELECT key, payload FROM meta WHERE key >= ?1 AND key < ?2").rows([
                    .text(prefix), .text(upper),
                ]) { ($0.text(0), $0.blob(1)) }
            } else {
                rows = try connection.prepare("SELECT key, payload FROM meta WHERE key >= ?1").rows([.text(prefix)]) {
                    ($0.text(0), $0.blob(1))
                }
            }
            var values: [String: String] = [:]
            for (key, blob) in rows where key.hasPrefix(prefix) {
                values[key] = try self.codec.open(blob, as: String.self, table: "meta", rowKey: key)
            }
            return values
        }
    }

    /// The smallest key above every key with `prefix`, when its last character is printable ASCII.
    static func upperBound(of prefix: String) -> String? {
        guard let last = prefix.utf8.last, last >= 0x20, last < 0x7E else { return nil }
        return String(prefix.dropLast()) + String(UnicodeScalar(last + 1))
    }

    // MARK: Writes

    @discardableResult
    public func write(
        _ batch: StoreWrite, gate: SessionGate, generation: Generation
    ) throws(StoreError) -> StoreWriteResult {
        do {
            return try gate.commit(generation) { () throws(StoreError) -> StoreWriteResult in
                try self.withConnection { connection throws(StoreError) -> StoreWriteResult in
                    try connection.transaction { () throws(StoreError) -> StoreWriteResult in
                        var result = StoreWriteResult()
                        for operation in batch.operations { try self.apply(operation, connection, &result) }
                        return result
                    }
                }
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw .gateClosed
        }
    }

    private func exists(_ table: String, _ column: String, _ value: String, _ c: Connection) throws(StoreError) -> Bool
    {
        try c.prepare("SELECT 1 FROM \(table) WHERE \(column) = ?1").first([.text(value)]) { $0.int(0) } != nil
    }

    private func readMeta(_ key: String, _ c: Connection) throws(StoreError) -> String? {
        guard let blob = try c.prepare("SELECT payload FROM meta WHERE key = ?1").first([.text(key)], { $0.blob(0) })
        else { return nil }
        return try codec.open(blob, as: String.self, table: "meta", rowKey: key)
    }

    private func writeMeta(_ key: String, _ value: String?, _ c: Connection) throws(StoreError) {
        if let value {
            let sealed = try codec.seal(value, table: "meta", rowKey: key)
            try c.prepare("INSERT OR REPLACE INTO meta (key, payload) VALUES (?1, ?2)").run([.text(key), .blob(sealed)])
        } else {
            try c.prepare("DELETE FROM meta WHERE key = ?1").run([.text(key)])
        }
    }

    private func apply(
        _ operation: StoreWrite.Operation, _ c: Connection, _ result: inout StoreWriteResult
    ) throws(StoreError) {
        let handled = try Bookkeeping.apply(
            operation,
            get: { (key) throws(StoreError) in try self.readMeta(key, c) },
            set: { (key, value) throws(StoreError) in try self.writeMeta(key, value, c) },
            hasMessage: { (name) throws(StoreError) in try self.exists("messages", "name", name.rawValue, c) },
            isNotified: { (name) throws(StoreError) in try self.exists("notified", "message", name.rawValue, c) },
            result: &result)
        if handled { return }
        switch operation {
        case .mergeSpace(let space): try mergeSpace(space, c)
        case .setSpaceHidden(let name, let hidden):
            try c.prepare("UPDATE spaces SET is_hidden = ?2 WHERE name = ?1").run([.text(name.rawValue), .bool(hidden)])
        case .deleteSpace(let name): try deleteSpace(name, c)
        case .upsertMessages(let messages): try upsertMessages(messages, c)
        case .replaceMessages(let space, let messages, let coveredBefore):
            let keep = Set(messages.map(\.name.rawValue))
            let covered = try c.prepare(
                "SELECT name FROM messages WHERE space = ?1 AND (create_s, create_n) < (?2, ?3)"
            ).rows([.text(space.rawValue), .seconds(coveredBefore), .nanos(coveredBefore)]) { $0.text(0) }
            let delete = try c.prepare("DELETE FROM messages WHERE name = ?1")
            for name in covered where !keep.contains(name) { try delete.run([.text(name)]) }
            try upsertMessages(messages.filter { $0.space == space }, c, rewriteEqual: true)
        case .updateReactions(let name, let reactions):
            let row = try c.prepare("SELECT payload FROM messages WHERE name = ?1").first([.text(name.rawValue)]) {
                $0.blob(0)
            }
            guard let row else { break }
            var message = try codec.open(row, as: Message.self, table: "messages", rowKey: name.rawValue)
            message.reactions = reactions
            let sealed = try codec.seal(message, table: "messages", rowKey: name.rawValue)
            try c.prepare("UPDATE messages SET payload = ?2 WHERE name = ?1").run([.text(name.rawValue), .blob(sealed)])
        case .setCheckpoint(let space, let stream, let value):
            try c.prepare(
                """
                INSERT INTO sync_checkpoints (space, stream, value_s, value_n) VALUES (?1, ?2, ?3, ?4)
                ON CONFLICT (space, stream) DO UPDATE SET value_s = excluded.value_s, value_n = excluded.value_n
                WHERE (excluded.value_s, excluded.value_n) > (sync_checkpoints.value_s, sync_checkpoints.value_n)
                """
            ).run([.text(space.rawValue), .text(stream.rawValue), .seconds(value), .nanos(value)])
        case .setReadState(let space, let time):
            try setReadState(scope: space.rawValue, space: space, time, c)
        case .setThreadReadState(let thread, let time):
            try setReadState(scope: thread.rawValue, space: thread.space, time, c)
        case .setNotificationSetting(let name, let setting):
            guard var payload = try loadSpacePayload(name, c) else { return }
            payload.notificationSetting = setting
            try storeSpacePayload(payload, c)
        case .setMembers(let space, let members, let title, let fetched):
            try setMembers(space, members, title: title, fetched: fetched, c)
        case .putDraft(let draft):
            try storeDraft(draft, c)
        case .putDraftIfAbsent(let draft):
            let statement = try c.prepare("SELECT payload FROM drafts WHERE key = ?1")
            if let blob = try statement.first([.text(draft.key)], { $0.blob(0) }),
                try !codec.open(blob, as: Draft.self, table: "drafts", rowKey: draft.key).isEmpty
            {
                return
            }
            try storeDraft(draft, c)
        case .deleteDraft(let key):
            try c.prepare("DELETE FROM drafts WHERE key = ?1").run([.text(key)])
        case .putOutbox(let item):
            let id = item.id.uuidString
            let sealed = try codec.seal(item, table: "outbox", rowKey: id)
            try c.prepare(
                "INSERT OR REPLACE INTO outbox (id, space, created_s, created_n, payload) VALUES (?1, ?2, ?3, ?4, ?5)"
            ).run([
                .text(id), .text(item.space.rawValue), .seconds(item.created), .nanos(item.created), .blob(sealed),
            ])
        case .deleteOutbox(let id):
            try c.prepare("DELETE FROM outbox WHERE id = ?1").run([.text(id.uuidString)])
        case .markNotified(let names, let time):
            let statement = try c.prepare(
                "INSERT OR IGNORE INTO notified (message, space, at_s, at_n) VALUES (?1, ?2, ?3, ?4)")
            for name in names {
                try statement.run([.text(name.rawValue), .text(name.space.rawValue), .seconds(time), .nanos(time)])
            }
        case .setMeta(let key, let value):
            try writeMeta(key, value, c)
        case .pruneMessages(let space, let keep):
            try c.prepare(
                """
                DELETE FROM messages WHERE space = ?1 AND name NOT IN (
                    SELECT name FROM messages WHERE space = ?1
                    ORDER BY create_s DESC, create_n DESC, name DESC LIMIT ?2)
                """
            ).run([.text(space.rawValue), .int(Int64(max(0, keep)))])
        case .mergeOwed, .resolveOwed, .deferOwed, .owedOmitted, .clearOwed, .bumpRelist, .resolveRelist,
            .addNotifyCandidates, .flagNotifyGap, .removeNotifyPending:
            break
        }
    }

    private func storeDraft(_ draft: Draft, _ c: Connection) throws(StoreError) {
        let sealed = try codec.seal(draft, table: "drafts", rowKey: draft.key)
        try c.prepare(
            "INSERT OR REPLACE INTO drafts (key, space, updated_s, updated_n, payload) VALUES (?1, ?2, ?3, ?4, ?5)"
        ).run([
            .text(draft.key), .text(draft.space.rawValue), .seconds(draft.updated), .nanos(draft.updated),
            .blob(sealed),
        ])
    }

    private func loadSpacePayload(_ name: SpaceName, _ c: Connection) throws(StoreError) -> SpacePayload? {
        let statement = try c.prepare("SELECT payload FROM spaces WHERE name = ?1")
        guard let blob = try statement.first([.text(name.rawValue)], { $0.blob(0) }) else { return nil }
        return try codec.open(blob, as: SpacePayload.self, table: "spaces", rowKey: name.rawValue)
    }

    private func storeSpacePayload(_ payload: SpacePayload, _ c: Connection) throws(StoreError) {
        let name = payload.space.name.rawValue
        let sealed = try codec.seal(payload, table: "spaces", rowKey: name)
        try c.prepare(
            """
            INSERT INTO spaces (name, payload) VALUES (?1, ?2)
            ON CONFLICT (name) DO UPDATE SET payload = excluded.payload
            """
        ).run([.text(name), .blob(sealed)])
    }

    private func loadMembers(
        _ space: SpaceName, _ c: Connection
    ) throws(StoreError) -> (payload: MembersPayload, fetched: Timestamp)? {
        let statement = try c.prepare("SELECT payload, fetched_s, fetched_n FROM members WHERE space = ?1")
        let row = try statement.first([.text(space.rawValue)]) { row throws(StoreError) in
            (row.blob(0), try row.timestamp(1))
        }
        guard let (blob, fetched) = row, let fetched else { return nil }
        let payload = try codec.open(blob, as: MembersPayload.self, table: "members", rowKey: space.rawValue)
        return (payload, fetched)
    }

    private func mergeSpace(_ space: Space, _ c: Connection) throws(StoreError) {
        if var payload = try loadSpacePayload(space.name, c) {
            payload.space = space
            try storeSpacePayload(payload, c)
        } else {
            var payload = SpacePayload(space: space)
            if let members = try loadMembers(space.name, c) {
                payload.memberTitle = members.payload.title
                payload.memberTitleFetched = members.fetched
            }
            try storeSpacePayload(payload, c)
        }
    }

    private func setMembers(
        _ space: SpaceName, _ members: [Membership], title: String?, fetched: Timestamp, _ c: Connection
    ) throws(StoreError) {
        let sealed = try codec.seal(
            MembersPayload(members: members, title: title), table: "members", rowKey: space.rawValue)
        try c.prepare(
            "INSERT OR REPLACE INTO members (space, fetched_s, fetched_n, payload) VALUES (?1, ?2, ?3, ?4)"
        ).run([.text(space.rawValue), .seconds(fetched), .nanos(fetched), .blob(sealed)])
        if var payload = try loadSpacePayload(space, c) {
            payload.memberTitle = title
            payload.memberTitleFetched = fetched
            try storeSpacePayload(payload, c)
        }
    }

    private func setReadState(
        scope: String, space: SpaceName, _ time: Timestamp?, _ c: Connection
    ) throws(StoreError) {
        guard let time else {
            try c.prepare("DELETE FROM read_state WHERE scope = ?1").run([.text(scope)])
            return
        }
        try c.prepare(
            "INSERT OR REPLACE INTO read_state (scope, space, read_s, read_n) VALUES (?1, ?2, ?3, ?4)"
        ).run([.text(scope), .text(space.rawValue), .seconds(time), .nanos(time)])
    }

    /// `rewriteEqual` lets a fresh authoritative copy replace a stored row of the same version, e.g. after mapping
    /// gained fields.
    private func upsertMessages(
        _ messages: [Message], _ c: Connection, rewriteEqual: Bool = false
    ) throws(StoreError) {
        let select = try c.prepare("SELECT version_s, version_n, is_deleted FROM messages WHERE name = ?1")
        let payload = try c.prepare("SELECT payload FROM messages WHERE name = ?1")
        let insert = try c.prepare(
            """
            INSERT OR REPLACE INTO messages
                (name, space, thread, create_s, create_n, version_s, version_n, is_deleted, payload)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            """)
        for incoming in messages {
            let name = incoming.name.rawValue
            var message = incoming
            if let (seconds, nanos, storedDeleted) = try select.first(
                [.text(name)], { ($0.int(0), $0.int(1), $0.int(2) != 0) })
            {
                let older = (incoming.version.seconds, Int64(incoming.version.nanos)) < (seconds, nanos)
                let equal = (incoming.version.seconds, Int64(incoming.version.nanos)) == (seconds, nanos)
                switch (storedDeleted, incoming.isDeleted) {
                case (true, false): continue
                case (false, false): if older || (equal && !rewriteEqual) { continue }
                case (true, true): if older { continue }
                case (false, true): break
                }
                // Only a tombstone needs the stored copy: Google's deletion events leave out the thread and sender.
                if incoming.isDeleted, let sealed = try payload.first([.text(name)], { $0.blob(0) }) {
                    let stored = try codec.open(sealed, as: Message.self, table: "messages", rowKey: name)
                    message = Message.merge(incoming, over: stored, rewriteEqual: true) ?? incoming
                }
            }
            let version = message.version
            let sealed = try codec.seal(message, table: "messages", rowKey: name)
            try insert.run([
                .text(name), .text(message.space.rawValue), message.thread.map { .text($0.rawValue) } ?? .null,
                .seconds(message.createTime), .nanos(message.createTime), .seconds(version), .nanos(version),
                .bool(message.isDeleted), .blob(sealed),
            ])
        }
    }

    private func deleteSpace(_ name: SpaceName, _ c: Connection) throws(StoreError) {
        let key = [SQLValue.text(name.rawValue)]
        try c.prepare("DELETE FROM spaces WHERE name = ?1").run(key)
        for table in ["messages", "members", "drafts", "read_state", "sync_checkpoints", "notified"] {
            try c.prepare("DELETE FROM \(table) WHERE space = ?1").run(key)
        }
        try writeMeta(NotifyRecord.key(name), nil, c)
    }
}
