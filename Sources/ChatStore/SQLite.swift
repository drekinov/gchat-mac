import ChatModel
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null

    static func bool(_ value: Bool) -> SQLValue { .int(value ? 1 : 0) }
    static func seconds(_ timestamp: Timestamp?) -> SQLValue { timestamp.map { .int($0.seconds) } ?? .null }
    static func nanos(_ timestamp: Timestamp?) -> SQLValue { timestamp.map { .int(Int64($0.nanos)) } ?? .null }
}

/// One SQLite handle opened NOMUTEX: the owner serializes every use.
final class Connection {
    private var handle: OpaquePointer?

    init(path: String) throws(StoreError) {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            sqlite3_close_v2(db)
            throw .sqlite(code: rc)
        }
        handle = db
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    func configure(busyTimeoutMilliseconds: Int32 = 5000) throws(StoreError) {
        try execute("PRAGMA busy_timeout = \(busyTimeoutMilliseconds)")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA secure_delete = ON")
        try execute("PRAGMA synchronous = NORMAL")
        let journal = try prepare("PRAGMA journal_mode = WAL").first { $0.text(0) }
        guard journal?.lowercased() == "wal" else { throw .sqlite(code: SQLITE_ERROR) }
        let secure = try prepare("PRAGMA secure_delete").first { $0.int(0) }
        guard secure == 1 else { throw .sqlite(code: SQLITE_ERROR) }
    }

    func execute(_ sql: String) throws(StoreError) {
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw .sqlite(code: rc) }
    }

    func prepare(_ sql: String) throws(StoreError) -> Statement {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw .sqlite(code: rc)
        }
        return Statement(statement, connection: self)
    }

    func userVersion() throws(StoreError) -> Int {
        try Int(prepare("PRAGMA user_version").first { $0.int(0) } ?? 0)
    }

    func transaction<T>(_ body: () throws(StoreError) -> T) throws(StoreError) -> T {
        try execute("BEGIN IMMEDIATE")
        do throws(StoreError) {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }
}

final class Statement {
    private let statement: OpaquePointer
    private let connection: Connection

    fileprivate init(_ statement: OpaquePointer, connection: Connection) {
        self.statement = statement
        self.connection = connection
    }

    deinit { sqlite3_finalize(statement) }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func bind(_ values: [SQLValue]) throws(StoreError) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .int(let number):
                rc = sqlite3_bind_int64(statement, index, number)
            case .double(let number):
                rc = sqlite3_bind_double(statement, index, number)
            case .text(var string):
                if string.isEmpty {
                    rc = sqlite3_bind_text(statement, index, "", 0, sqliteTransient)
                } else {
                    rc = string.withUTF8 {
                        sqlite3_bind_text64(
                            statement, index, $0.baseAddress, UInt64($0.count), sqliteTransient, UInt8(SQLITE_UTF8))
                    }
                }
            case .blob(let data):
                rc =
                    data.isEmpty
                    ? sqlite3_bind_zeroblob(statement, index, 0)
                    : data.withUnsafeBytes {
                        sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64($0.count), sqliteTransient)
                    }
            case .null:
                rc = sqlite3_bind_null(statement, index)
            }
            guard rc == SQLITE_OK else { throw .sqlite(code: rc) }
        }
    }

    /// Returns true when a row is available.
    func step() throws(StoreError) -> Bool {
        let rc = sqlite3_step(statement)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw .sqlite(code: rc)
        }
    }

    func run(_ values: [SQLValue] = []) throws(StoreError) {
        reset()
        try bind(values)
        while try step() {}
        reset()
    }

    func rows<T>(_ values: [SQLValue] = [], _ map: (Statement) throws(StoreError) -> T) throws(StoreError) -> [T] {
        reset()
        defer { reset() }
        try bind(values)
        var result: [T] = []
        while try step() { result.append(try map(self)) }
        return result
    }

    func first<T>(_ values: [SQLValue] = [], _ map: (Statement) throws(StoreError) -> T) throws(StoreError) -> T? {
        reset()
        defer { reset() }
        try bind(values)
        return try step() ? try map(self) : nil
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    func blob(_ column: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }

    /// Reads a seconds/nanos column pair starting at `column`; `nil` when the seconds column is NULL.
    func timestamp(_ column: Int32) throws(StoreError) -> Timestamp? {
        guard !isNull(column) else { return nil }
        let nanos = int(column + 1)
        guard (0..<1_000_000_000).contains(nanos) else { throw .crypto(.malformed) }
        return Timestamp(seconds: int(column), nanos: Int32(nanos))
    }
}
