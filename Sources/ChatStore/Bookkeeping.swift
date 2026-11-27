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

/// What expiry removed and still has to be cleaned up outside the store: delivered notifications of the messages and
/// cached or exported copies of their uploaded attachments. Stored under `expiredCleanup` in the same transaction as
/// the deletion, so a crash before the cleanup only delays it.
public struct ExpiredCleanup: Codable, Sendable, Equatable {
    public static let key = "expiredCleanup"
    /// Notification removal is best effort; past this many the oldest names are dropped.
    public static let maxMessages = 1000

    public var messages: [MessageName]
    /// Media resource names of uploaded attachments.
    public var media: [String]

    enum CodingKeys: String, CodingKey {
        case messages = "m"
        case media = "a"
    }

    public init(messages: [MessageName] = [], media: [String] = []) {
        self.messages = messages
        self.media = media
    }

    public var isEmpty: Bool { messages.isEmpty && media.isEmpty }

    mutating func add(_ expired: [Message]) {
        var names = Set(messages)
        var known = Set(media)
        for message in expired {
            if names.insert(message.name).inserted { messages.append(message.name) }
            for attachment in message.attachments {
                if case .uploaded(let resource) = attachment.source, known.insert(resource.rawValue).inserted {
                    media.append(resource.rawValue)
                }
            }
        }
        if messages.count > Self.maxMessages { messages.removeFirst(messages.count - Self.maxMessages) }
    }
}

/// The row work expiry needs from a store, inside its write transaction.
struct RetentionRows {
    /// Deletes the space's messages created inside `window` and before `cutoff`, returning them.
    var expire: (SpaceName, HistoryOffWindow, Timestamp) throws(StoreError) -> [Message]
    /// Deletes the space's committed outbox items created inside `window` and before `cutoff`.
    var expireOutbox: (SpaceName, HistoryOffWindow, Timestamp) throws(StoreError) -> Void
    /// The oldest create time among the space's messages inside `window`.
    var oldest: (SpaceName, HistoryOffWindow) throws(StoreError) -> Timestamp?
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
        case .owedOmitted(let space, let revision):
            guard var record = try owed(space), record.revision == revision else { return true }
            record.omitted += 1
            if !record.hasMessages, record.omitted >= OwedRecord.maxOmissions {
                try drop(space)
            } else {
                try putOwed(space, record)
            }
        case .clearOwed(let space, let revision):
            guard try owed(space)?.revision == revision else { return true }
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
            let folded = removed.subtracting(record.ids).count
            record.ids.removeAll { removed.contains($0) }
            record.overflow = max(0, record.overflow - overflow - folded)
            if gap { record.gap = false }
            try putNotify(space, record)
        case .clearExpiredCleanup(let done):
            guard var record = decode(try get(ExpiredCleanup.key), as: ExpiredCleanup.self) else { return true }
            let messages = Set(done.messages)
            let media = Set(done.media)
            record.messages.removeAll { messages.contains($0) }
            record.media.removeAll { media.contains($0) }
            try set(ExpiredCleanup.key, record.isEmpty ? nil : try encode(record))
        default:
            return false
        }
        return true
    }

    static func retention(
        _ space: SpaceName, get: (String) throws(StoreError) -> String?
    ) throws(StoreError) -> HistoryRetention? {
        decode(try get(HistoryRetention.key(space)), as: HistoryRetention.self)
    }

    /// Records a history state change of a stored space from `previous` to `historyOn`, seen at `at`. An exact time
    /// (`margin` zero) for the state already stored refines the edge a listing recorded for it.
    static func observeHistory(
        _ space: SpaceName, historyOn: Bool, previous: Bool?, at: Timestamp, margin: Duration,
        get: (String) throws(StoreError) -> String?, set: (String, String?) throws(StoreError) -> Void
    ) throws(StoreError) {
        guard previous != historyOn || margin == .zero else { return }
        var record = try retention(space, get: get) ?? HistoryRetention()
        let changed =
            previous == historyOn
            ? record.refine(historyOn: historyOn, at: at)
            : record.observe(historyOn: historyOn, previous: previous, at: at, margin: margin)
        guard changed else { return }
        try set(HistoryRetention.key(space), try encode(record))
    }

    /// Deletes what `HistoryRetention` says Google has deleted by `now` in a space whose current state is
    /// `historyOn`, queues its cleanup, and refreshes the record's `due`.
    static func expire(
        _ space: SpaceName, historyOn: Bool?, now: Timestamp, rows: RetentionRows,
        get: (String) throws(StoreError) -> String?, set: (String, String?) throws(StoreError) -> Void
    ) throws(StoreError) {
        let stored = try retention(space, get: get)
        guard stored != nil || historyOn == false else { return }
        var record = stored ?? HistoryRetention()
        record.forgetExpired(now: now)
        let windows = record.effective(historyOn: historyOn).windows
        let cutoff = HistoryRetention.cutoff(at: now)
        var expired: [Message] = []
        var due: Timestamp?
        for window in windows {
            expired += try rows.expire(space, window, cutoff)
            try rows.expireOutbox(space, window, cutoff)
            if let oldest = try rows.oldest(space, window) {
                let expires = oldest.adding(HistoryRetention.lifetime)
                due = min(due ?? expires, expires)
            }
        }
        record.due = due
        if record.windows.isEmpty, due == nil {
            if stored != nil { try set(HistoryRetention.key(space), nil) }
        } else if record != stored {
            try set(HistoryRetention.key(space), try encode(record))
        }
        guard !expired.isEmpty else { return }
        if var notify = decode(try get(NotifyRecord.key(space)), as: NotifyRecord.self) {
            let gone = Set(expired.map { id(of: $0.name) })
            notify.ids.removeAll { gone.contains($0) }
            try set(NotifyRecord.key(space), notify.isEmpty ? nil : try encode(notify))
        }
        var cleanup = decode(try get(ExpiredCleanup.key), as: ExpiredCleanup.self) ?? ExpiredCleanup()
        cleanup.add(expired)
        try set(ExpiredCleanup.key, try encode(cleanup))
    }
}
