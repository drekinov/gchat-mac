import ChatModel
import Foundation

/// "Messages of `space` up to `boundary` haven't been fetched yet", plus the acknowledged message IDs still missing.
/// Stored under `owed|<space>` in `meta`.
public struct OwedRecord: Codable, Sendable, Equatable {
    public static let keyPrefix = "owed|"
    public static let maxMessages = 1000
    /// Listing-derived rows without IDs are dropped after this many failed attempts.
    public static let maxAttempts = 5
    /// Listing-derived rows without IDs are dropped after this many complete listings that omit the space.
    public static let maxOmissions = 3

    public var boundary: Timestamp
    /// Message IDs within the space, the last segment of each name.
    public var ids: [String]
    public var revision: UInt64
    public var attempts: Int
    public var nextTry: Timestamp?
    public var omitted: Int

    enum CodingKeys: String, CodingKey {
        case boundary = "b"
        case ids = "m"
        case revision = "r"
        case attempts = "a"
        case nextTry = "n"
        case omitted = "o"
    }

    public init(
        boundary: Timestamp, ids: [String] = [], revision: UInt64 = 1, attempts: Int = 0, nextTry: Timestamp? = nil,
        omitted: Int = 0
    ) {
        self.boundary = boundary
        self.ids = ids
        self.revision = revision
        self.attempts = attempts
        self.nextTry = nextTry
        self.omitted = omitted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        boundary = try container.decode(Timestamp.self, forKey: .boundary)
        ids = try container.decodeIfPresent([String].self, forKey: .ids) ?? []
        revision = try container.decode(UInt64.self, forKey: .revision)
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        nextTry = try container.decodeIfPresent(Timestamp.self, forKey: .nextTry)
        omitted = try container.decodeIfPresent(Int.self, forKey: .omitted) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(boundary, forKey: .boundary)
        if !ids.isEmpty { try container.encode(ids, forKey: .ids) }
        try container.encode(revision, forKey: .revision)
        if attempts != 0 { try container.encode(attempts, forKey: .attempts) }
        try container.encodeIfPresent(nextTry, forKey: .nextTry)
        if omitted != 0 { try container.encode(omitted, forKey: .omitted) }
    }

    public static func key(_ space: SpaceName) -> String { keyPrefix + space.rawValue }

    public func messages(in space: SpaceName) -> [MessageName] { ids.map { Bookkeeping.message($0, in: space) } }

    public var hasMessages: Bool { !ids.isEmpty }

    public func isDue(at now: Timestamp) -> Bool { nextTry.map { $0 <= now } ?? true }

    /// 30 s, 2 min, 10 min, then hourly.
    public static func retryDelay(afterAttempts attempts: Int) -> Duration {
        switch attempts {
        case ...1: .seconds(30)
        case 2: .seconds(120)
        case 3: .seconds(600)
        default: .seconds(3600)
        }
    }
}

/// Message IDs of `space` eligible for a notification that hasn't been posted yet. Stored under `notify|<space>`.
public struct NotifyRecord: Codable, Sendable, Equatable {
    public static let keyPrefix = "notify|"
    /// More pending IDs than this collapse into `overflow`.
    public static let maxPending = 20

    public var ids: [String]
    /// Eligible messages counted for a summary only.
    public var overflow: Int
    /// A reseed skipped messages it never fetched.
    public var gap: Bool

    enum CodingKeys: String, CodingKey {
        case ids = "m"
        case overflow = "o"
        case gap = "g"
    }

    public init(ids: [String] = [], overflow: Int = 0, gap: Bool = false) {
        self.ids = ids
        self.overflow = overflow
        self.gap = gap
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ids = try container.decodeIfPresent([String].self, forKey: .ids) ?? []
        overflow = try container.decodeIfPresent(Int.self, forKey: .overflow) ?? 0
        gap = try container.decodeIfPresent(Bool.self, forKey: .gap) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !ids.isEmpty { try container.encode(ids, forKey: .ids) }
        if overflow != 0 { try container.encode(overflow, forKey: .overflow) }
        if gap { try container.encode(gap, forKey: .gap) }
    }

    public static func key(_ space: SpaceName) -> String { keyPrefix + space.rawValue }

    public func messages(in space: SpaceName) -> [MessageName] { ids.map { Bookkeeping.message($0, in: space) } }

    public var isEmpty: Bool { ids.isEmpty && overflow == 0 && !gap }
}

/// Durable, versioned relist requests: a listing resolves only the version it saw when it started.
public struct RelistRecord: Codable, Sendable, Equatable {
    public static let key = "relist"

    public var requested: UInt64
    public var resolved: UInt64

    enum CodingKeys: String, CodingKey {
        case requested = "q"
        case resolved = "s"
    }

    public init(requested: UInt64 = 0, resolved: UInt64 = 0) {
        self.requested = requested
        self.resolved = resolved
    }

    public var isPending: Bool { requested > resolved }
}

/// What a write reports back about conditional operations.
public struct StoreWriteResult: Sendable, Equatable {
    /// Message IDs `.mergeOwed` couldn't keep because the space's row was full; the caller must not ack them.
    public var rejectedOwed: [MessageName] = []

    public init(rejectedOwed: [MessageName] = []) { self.rejectedOwed = rejectedOwed }
}

/// The meta-backed operations, shared by both stores. Records that fail to decode count as absent.
enum Bookkeeping {
    static let sequenceKey = "owedSequence"
    static let droppedKey = "owedDropped"

    static func message(_ id: String, in space: SpaceName) -> MessageName {
        MessageName(unchecked: "\(space.rawValue)/messages/\(id)")
    }

    static func id(of message: MessageName) -> String { message.id(at: 1) }

    static func decode<T: Decodable>(_ value: String?, as type: T.Type) -> T? {
        guard let value else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(value.utf8))
    }

    static func encode<T: Encodable>(_ value: T) throws(StoreError) -> String {
        do {
            return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        } catch {
            throw .crypto(.malformed)
        }
    }

    /// Applies `operation` if it is a bookkeeping operation; returns `false` otherwise. `hasMessage` and
    /// `isNotified` read the rows as they stand at this point of the batch.
    static func apply(
        _ operation: StoreWrite.Operation,
        get: (String) throws(StoreError) -> String?,
        set: (String, String?) throws(StoreError) -> Void,
        hasMessage: (MessageName) throws(StoreError) -> Bool,
        isNotified: (MessageName) throws(StoreError) -> Bool,
        result: inout StoreWriteResult
    ) throws(StoreError) -> Bool {
        func owed(_ space: SpaceName) throws(StoreError) -> OwedRecord? {
            decode(try get(OwedRecord.key(space)), as: OwedRecord.self)
        }
        func putOwed(_ space: SpaceName, _ record: OwedRecord?) throws(StoreError) {
            try set(OwedRecord.key(space), try record.map { (record) throws(StoreError) in try encode(record) })
        }
        func drop(_ space: SpaceName) throws(StoreError) {
            try putOwed(space, nil)
            let count = Int(try get(droppedKey) ?? "") ?? 0
            try set(droppedKey, String(count + 1))
        }
        func notify(_ space: SpaceName) throws(StoreError) -> NotifyRecord {
            decode(try get(NotifyRecord.key(space)), as: NotifyRecord.self) ?? NotifyRecord()
        }
        func putNotify(_ space: SpaceName, _ record: NotifyRecord) throws(StoreError) {
            try set(NotifyRecord.key(space), record.isEmpty ? nil : try encode(record))
        }
        func relist() throws(StoreError) -> RelistRecord {
            decode(try get(RelistRecord.key), as: RelistRecord.self) ?? RelistRecord()
        }

        switch operation {
        case .mergeOwed(let space, let boundary, let messages):
            let sequence = (UInt64(try get(sequenceKey) ?? "") ?? 0) + 1
            try set(sequenceKey, String(sequence))
            var record = try owed(space) ?? OwedRecord(boundary: boundary)
            record.boundary = max(record.boundary, boundary)
            record.revision = sequence
            record.attempts = 0
            record.nextTry = nil
            record.omitted = 0
            var known = Set(record.ids)
            for message in messages where message.space == space {
                let id = id(of: message)
                guard !known.contains(id) else { continue }
                guard record.ids.count < OwedRecord.maxMessages else {
                    result.rejectedOwed.append(message)
                    continue
                }
                known.insert(id)
                record.ids.append(id)
            }
            try putOwed(space, record)
        case .resolveOwed(let space, let revision, let coveredUpTo, let fetched):
            guard var record = try owed(space) else { return true }
            let gone = Set(fetched.map(id(of:)))
            var remaining: [String] = []
            for id in record.ids where !gone.contains(id) {
                if try !hasMessage(message(id, in: space)) { remaining.append(id) }
            }
            let covered = coveredUpTo.map { $0 > record.boundary } ?? false
            if record.revision == revision, covered, remaining.isEmpty {
                try putOwed(space, nil)
            } else if remaining.count != record.ids.count {
                record.ids = remaining
                try putOwed(space, record)
            }
        case .deferOwed(let space, let revision, let now):
            guard var record = try owed(space), record.revision == revision else { return true }
            record.attempts += 1
            if !record.hasMessages, record.attempts >= OwedRecord.maxAttempts {
                try drop(space)
            } else {
                record.nextTry = now.adding(OwedRecord.retryDelay(afterAttempts: record.attempts))
                try putOwed(space, record)
            }
        case .owedOmitted(let space):
            guard var record = try owed(space) else { return true }
            record.omitted += 1
            if !record.hasMessages, record.omitted >= OwedRecord.maxOmissions {
                try drop(space)
            } else {
                try putOwed(space, record)
            }
        case .clearOwed(let space):
            try putOwed(space, nil)
        case .bumpRelist:
            var record = try relist()
            record.requested += 1
            try set(RelistRecord.key, try encode(record))
        case .resolveRelist(let version):
            var record = try relist()
            guard version > record.resolved else { return true }
            record.resolved = min(version, record.requested)
            try set(RelistRecord.key, try encode(record))
        case .addNotifyCandidates(let space, let messages):
            var record = try notify(space)
            var known = Set(record.ids)
            var added = 0
            for message in messages where message.space == space {
                let id = id(of: message)
                guard !known.contains(id), try !hasMessage(message), try !isNotified(message) else { continue }
                known.insert(id)
                record.ids.append(id)
                added += 1
            }
            guard added > 0 else { return true }
            if record.ids.count > NotifyRecord.maxPending {
                record.overflow += record.ids.count
                record.ids = []
            }
            try putNotify(space, record)
        case .flagNotifyGap(let space):
            var record = try notify(space)
            record.gap = true
            try putNotify(space, record)
        case .removeNotifyPending(let space, let messages, let overflow, let gap):
            var record = try notify(space)
            let removed = Set(messages.map(id(of:)))
            record.ids.removeAll { removed.contains($0) }
            record.overflow = max(0, record.overflow - overflow)
            if gap { record.gap = false }
            try putNotify(space, record)
        default:
            return false
        }
        return true
    }
}
