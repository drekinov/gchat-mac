import ChatModel
import CryptoKit
import Foundation
import Synchronization

public enum MediaCacheError: Error, Sendable, Equatable {
    /// A writer for the same media ID is still open.
    case busy
    /// The entry would exceed the cache capacity.
    case tooLarge
    /// Open readers pin enough entries that this one can't be admitted; retry after they close.
    case full
    case closed
    /// The account store doesn't exist yet or hasn't been migrated to the media schema.
    case indexUnavailable
    /// The cached file failed verification and has been deleted.
    case corrupt(StoreCryptoError)
    case store(StoreError)
    case io(code: Int)
}

private struct MediaPayload: Codable {
    var mediaID: String
    var contentType: String
    var plainBytes: Int
}

private struct MediaIndex {
    let connection: Connection

    func wrap<T>(_ body: () throws(StoreError) -> T) throws(MediaCacheError) -> T {
        do throws(StoreError) { return try body() } catch { throw .store(error) }
    }

    func row(_ hash: String) throws(MediaCacheError) -> Data? {
        try wrap { () throws(StoreError) in
            try connection.prepare("SELECT payload FROM media WHERE media_hash = ?1").first([.text(hash)]) {
                $0.blob(0)
            }
        }
    }

    func upsert(_ hash: String, bytes: Int, access: Int64, payload: Data) throws(MediaCacheError) {
        try wrap { () throws(StoreError) in
            try connection.prepare(
                """
                INSERT INTO media (media_hash, bytes, last_access_s, payload) VALUES (?1, ?2, ?3, ?4)
                ON CONFLICT (media_hash) DO UPDATE SET
                    bytes = excluded.bytes, last_access_s = excluded.last_access_s, payload = excluded.payload
                """
            ).run([.text(hash), .int(Int64(bytes)), .int(access), .blob(payload)])
        }
    }

    func touch(_ hash: String, access: Int64) throws(MediaCacheError) {
        try wrap { () throws(StoreError) in
            try connection.prepare("UPDATE media SET last_access_s = ?2 WHERE media_hash = ?1")
                .run([.text(hash), .int(access)])
        }
    }

    func delete(_ hash: String) throws(MediaCacheError) {
        try wrap { () throws(StoreError) in
            try connection.prepare("DELETE FROM media WHERE media_hash = ?1").run([.text(hash)])
        }
    }

    func deleteAll() throws(MediaCacheError) {
        try wrap { () throws(StoreError) in try connection.prepare("DELETE FROM media").run() }
    }

    func totalBytes() throws(MediaCacheError) -> Int {
        try wrap { () throws(StoreError) in
            try Int(connection.prepare("SELECT COALESCE(SUM(bytes), 0) FROM media").first { $0.int(0) } ?? 0)
        }
    }

    func allHashes() throws(MediaCacheError) -> Set<String> {
        try wrap { () throws(StoreError) in
            Set(try connection.prepare("SELECT media_hash FROM media").rows { $0.text(0) })
        }
    }

    func oldestFirst() throws(MediaCacheError) -> [(hash: String, bytes: Int)] {
        try wrap { () throws(StoreError) in
            try connection.prepare("SELECT media_hash, bytes FROM media ORDER BY last_access_s ASC, media_hash ASC")
                .rows { ($0.text(0), Int($0.int(1))) }
        }
    }
}

private struct ReaderInfo {
    var hash: String
    var device: dev_t
    var inode: ino_t
    var bytes: Int
    /// The entry was removed or replaced while this reader holds the file; it still occupies disk.
    var orphaned = false
}

private struct CacheState {
    var index: MediaIndex?
    var readers: [Int: ReaderInfo] = [:]
    var nextReaderID = 0
    var writers: Set<String> = []

    func isPinned(_ hash: String) -> Bool {
        readers.values.contains { $0.hash == hash && !$0.orphaned }
    }

    /// Disk held only by readers of files that are no longer in the index, each file counted once.
    var orphanBytes: Int {
        var seen = Set<[UInt64]>()
        var total = 0
        for reader in readers.values where reader.orphaned {
            if seen.insert([UInt64(bitPattern: Int64(reader.device)), UInt64(reader.inode)]).inserted {
                total += reader.bytes
            }
        }
        return total
    }

    mutating func orphanReaders(of hash: String) {
        for id in readers.keys where readers[id]?.hash == hash { readers[id]?.orphaned = true }
    }
}

func writeAll(_ fd: Int32, _ data: Data) throws(MediaCacheError) {
    var failure: Int32 = 0
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                failure = errno
                return
            }
            offset += written
        }
    }
    if failure != 0 { throw .io(code: Int(failure)) }
}

/// Encrypted, LRU-bounded media files for one account, indexed in the account store's `media` table.
///
/// The account store must have been opened (and so migrated) first. Only the SHA-256 of the media ID is plaintext, in
/// file names and the index; the media ID, content type and size are sealed in the index row.
public final class MediaCache: Sendable {
    public static let defaultCapacityBytes = 256 * 1024 * 1024

    public let capacityBytes: Int
    let directory: AccountDirectory
    fileprivate let storeKey: StoreKey
    private let sealer: RowSealer
    private let now: @Sendable () -> Int64
    private let state: Mutex<CacheState>

    public convenience init(
        directory: AccountDirectory, key: StoreKey, capacityBytes: Int = MediaCache.defaultCapacityBytes
    ) throws(MediaCacheError) {
        try self.init(
            directory: directory, key: key, capacityBytes: capacityBytes,
            now: { Int64(Date().timeIntervalSince1970) })
    }

    init(
        directory: AccountDirectory, key: StoreKey, capacityBytes: Int, now: @escaping @Sendable () -> Int64
    ) throws(MediaCacheError) {
        guard key.account == directory.account else { throw .store(.crypto(.authenticationFailed)) }
        precondition(capacityBytes > 0)
        do throws(StoreError) { try directory.create() } catch { throw .store(error) }
        guard directory.storeExists() else { throw .indexUnavailable }
        self.directory = directory
        self.storeKey = key
        self.capacityBytes = capacityBytes
        self.now = now
        sealer = RowSealer(key)
        state = Mutex(CacheState(index: try Self.openIndex(directory)))
        try state.withLock { (s) throws(MediaCacheError) in
            guard let index = s.index else { throw .closed }
            try self.reconcile(index)
            try self.trim(&s, index)
        }
    }

    private static func openIndex(_ directory: AccountDirectory) throws(MediaCacheError) -> MediaIndex {
        let connection: Connection
        let version: Int
        do throws(StoreError) {
            connection = try Connection(path: directory.storeURL.path)
            try connection.configure()
            version = try connection.userVersion()
        } catch {
            throw .store(error)
        }
        guard version >= 2 else {
            connection.close()
            throw .indexUnavailable
        }
        return MediaIndex(connection: connection)
    }

    // MARK: Queries

    public func contains(mediaID: String) -> Bool {
        let hash = Self.hash(mediaID, key: storeKey)
        return state.withLock { s -> Bool in
            guard let index = s.index, (try? index.row(hash)) != nil else { return false }
            return access(filePath(hash), F_OK) == 0
        }
    }

    /// On-disk bytes of all entries.
    public var totalBytes: Int {
        state.withLock { s in (try? s.index?.totalBytes()) ?? 0 }
    }

    // MARK: Reading

    /// Returns nil when the media isn't cached. A corrupt entry is deleted and throws `.corrupt`.
    public func open(mediaID: String) throws(MediaCacheError) -> MediaReader? {
        let hash = Self.hash(mediaID, key: storeKey)
        return try state.withLock { (s) throws(MediaCacheError) -> MediaReader? in
            guard let index = s.index else { throw .closed }
            guard let sealed = try index.row(hash) else { return nil }
            let payload: MediaPayload
            do throws(StoreCryptoError) {
                payload = try self.openPayload(sealed, hash: hash)
                guard payload.mediaID == mediaID else { throw .authenticationFailed }
            } catch {
                try? self.removeEntry(hash, &s)
                throw .corrupt(error)
            }
            let fd = Darwin.open(self.filePath(hash), O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else {
                guard errno == ENOENT else { throw .io(code: Int(errno)) }
                try index.delete(hash)
                return nil
            }
            var info = stat()
            guard fstat(fd, &info) == 0 else {
                let code = Int(errno)
                Darwin.close(fd)
                throw .io(code: code)
            }
            try? index.touch(hash, access: self.now())
            let id = s.nextReaderID
            s.nextReaderID += 1
            s.readers[id] = ReaderInfo(hash: hash, device: info.st_dev, inode: info.st_ino, bytes: Int(info.st_size))
            return MediaReader(
                cache: self, key: self.storeKey, hash: hash, payload: payload, fd: fd, readerID: id,
                device: info.st_dev, inode: info.st_ino)
        }
    }

    // MARK: Writing

    /// Only one writer per media ID may be open; a second `beginWrite` throws `.busy`.
    public func beginWrite(mediaID: String, contentType: String) throws(MediaCacheError) -> MediaWriter {
        let hash = Self.hash(mediaID, key: storeKey)
        try state.withLock { (s) throws(MediaCacheError) in
            guard s.index != nil else { throw .closed }
            guard s.writers.insert(hash).inserted else { throw .busy }
        }
        do throws(MediaCacheError) {
            return try MediaWriter(
                cache: self, key: storeKey, mediaID: mediaID, hash: hash, contentType: contentType,
                tempPath: directory.mediaURL.appendingPathComponent("\(hash).\(UUID().uuidString).tmp").path)
        } catch {
            releaseWriter(hash)
            throw error
        }
    }

    // MARK: Removal

    public func remove(mediaID: String) throws(MediaCacheError) {
        let hash = Self.hash(mediaID, key: storeKey)
        try state.withLock { (s) throws(MediaCacheError) in
            guard s.index != nil else { throw .closed }
            try self.removeEntry(hash, &s)
        }
    }

    /// Open readers keep their already-open file until closed.
    public func removeAll() throws(MediaCacheError) {
        try state.withLock { (s) throws(MediaCacheError) in
            guard let index = s.index else { throw .closed }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: self.directory.mediaURL.path)) ?? []
            where name.hasSuffix(".gcm") {
                unlink(self.directory.mediaURL.appendingPathComponent(name).path)
            }
            for id in s.readers.keys { s.readers[id]?.orphaned = true }
            try index.deleteAll()
        }
    }

    /// Closes the index connection. Further operations throw `.closed`.
    public func close() {
        state.withLock { s in
            s.index?.connection.close()
            s.index = nil
        }
    }

    // MARK: Internals shared with the reader and writer

    /// Keyed, so a copy of the account directory can't confirm a guessed media ID from file names.
    static func hash(_ mediaID: String, key: StoreKey) -> String {
        let nameKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key.key, info: Data("gchat-mac.media-name.v1".utf8), outputByteCount: 32)
        return HMAC<SHA256>.authenticationCode(for: Data(mediaID.utf8), using: nameKey)
            .map { String(format: "%02x", $0) }.joined()
    }

    private func filePath(_ hash: String) -> String {
        directory.mediaURL.appendingPathComponent("\(hash).gcm").path
    }

    private func openPayload(_ sealed: Data, hash: String) throws(StoreCryptoError) -> MediaPayload {
        let plain = try sealer.open(sealed, table: "media", rowKey: hash)
        do { return try JSONDecoder().decode(MediaPayload.self, from: plain) } catch { throw .malformed }
    }

    private func removeEntry(_ hash: String, _ s: inout CacheState) throws(MediaCacheError) {
        guard let index = s.index else { throw .closed }
        if unlink(filePath(hash)) != 0, errno != ENOENT { throw .io(code: Int(errno)) }
        s.orphanReaders(of: hash)
        try index.delete(hash)
    }

    /// Drops temp files and files without an index row, and index rows without a file.
    private func reconcile(_ index: MediaIndex) throws(MediaCacheError) {
        let indexed = try index.allHashes()
        var present = Set<String>()
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: directory.mediaURL.path)) ?? [] {
            let hash = String(name.dropLast(4))
            if name.hasSuffix(".gcm"), indexed.contains(hash) {
                present.insert(hash)
            } else {
                try? manager.removeItem(at: directory.mediaURL.appendingPathComponent(name))
            }
        }
        for hash in indexed.subtracting(present) { try index.delete(hash) }
    }

    func releaseWriter(_ hash: String) {
        state.withLock { _ = $0.writers.remove(hash) }
    }

    func releaseReader(_ id: Int) {
        state.withLock { _ = $0.readers.removeValue(forKey: id) }
    }

    /// Deletes the entry only if the file on disk is still the instance the reader opened.
    func discardCorrupt(hash: String, device: dev_t, inode: ino_t) {
        state.withLock { s in
            var info = stat()
            if stat(filePath(hash), &info) == 0, info.st_dev == device, info.st_ino == inode {
                try? removeEntry(hash, &s)
            }
        }
    }

    func finishCommit(
        hash: String, mediaID: String, contentType: String, tempPath: String, fileBytes: Int, plainBytes: Int
    ) throws(MediaCacheError) {
        let payload: Data
        do {
            let json = try JSONEncoder().encode(
                MediaPayload(mediaID: mediaID, contentType: contentType, plainBytes: plainBytes))
            payload = sealer.seal(json, table: "media", rowKey: hash)
        } catch {
            throw .corrupt(.malformed)
        }
        try state.withLock { (s) throws(MediaCacheError) in
            guard let index = s.index else { throw .closed }
            guard fileBytes <= self.capacityBytes else { throw .tooLarge }
            let victims = try self.admit(s, index, replacing: hash, newBytes: fileBytes)
            for victim in victims { try self.removeEntry(victim, &s) }
            let final = self.filePath(hash)
            guard rename(tempPath, final) == 0 else { throw .io(code: Int(errno)) }
            s.orphanReaders(of: hash)
            do throws(MediaCacheError) {
                try index.upsert(hash, bytes: fileBytes, access: self.now(), payload: payload)
            } catch {
                unlink(final)
                throw error
            }
        }
    }

    /// Chooses the least recently used unpinned entries to evict so the new entry fits, without changing anything.
    /// Pinned entries and files held only by readers count in full; if they leave no room the commit is refused.
    private func admit(
        _ s: CacheState, _ index: MediaIndex, replacing hash: String, newBytes: Int
    ) throws(MediaCacheError) -> [String] {
        var projected = newBytes + s.orphanBytes
        var evictable: [(hash: String, bytes: Int)] = []
        for row in try index.oldestFirst() {
            if row.hash == hash {
                if s.isPinned(hash) { projected += row.bytes }
                continue
            }
            projected += row.bytes
            if !s.isPinned(row.hash) { evictable.append(row) }
        }
        var victims: [String] = []
        for row in evictable where projected > capacityBytes {
            victims.append(row.hash)
            projected -= row.bytes
        }
        guard projected <= capacityBytes else { throw .full }
        return victims
    }

    /// Evicts least recently used unpinned entries until the cache fits.
    private func trim(_ s: inout CacheState, _ index: MediaIndex) throws(MediaCacheError) {
        var total = try index.totalBytes() + s.orphanBytes
        guard total > capacityBytes else { return }
        for row in try index.oldestFirst() where !s.isPinned(row.hash) {
            try removeEntry(row.hash, &s)
            total -= row.bytes
            if total <= capacityBytes { return }
        }
    }
}

/// Streams plaintext into a sealed temp file, then commits it atomically. Holds at most one chunk of plaintext.
public final class MediaWriter: Sendable {
    private struct WriterState {
        var fd: Int32
        var sealer: MediaChunkSealer
        var buffer = Data()
        var nextIndex: UInt64 = 0
        var fileBytes: Int
        var plainBytes = 0
        var closed = false
        var released = false
    }

    private let cache: MediaCache
    private let mediaID: String
    private let hash: String
    private let contentType: String
    private let tempPath: String
    private let state: Mutex<WriterState>

    fileprivate init(
        cache: MediaCache, key: StoreKey, mediaID: String, hash: String, contentType: String, tempPath: String
    ) throws(MediaCacheError) {
        let fd = Darwin.open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .io(code: Int(errno)) }
        let sealer = MediaChunkSealer(key, mediaID: mediaID)
        let header = sealer.header()
        do throws(MediaCacheError) {
            guard fchmod(fd, 0o600) == 0 else { throw .io(code: Int(errno)) }
            try writeAll(fd, header)
        } catch {
            Darwin.close(fd)
            unlink(tempPath)
            throw error
        }
        self.cache = cache
        self.mediaID = mediaID
        self.hash = hash
        self.contentType = contentType
        self.tempPath = tempPath
        state = Mutex(WriterState(fd: fd, sealer: sealer, fileBytes: header.count))
    }

    deinit { teardown() }

    /// Plaintext currently buffered; never more than `MediaChunkSealer.chunkSize`.
    var bufferedBytes: Int { state.withLock { $0.buffer.count } }

    /// A failure discards the writer.
    public func append(_ data: Data) throws(MediaCacheError) {
        do throws(MediaCacheError) {
            try state.withLock { (w) throws(MediaCacheError) in
                guard !w.closed else { throw .closed }
                let chunk = MediaChunkSealer.chunkSize
                var offset = data.startIndex
                while offset < data.endIndex {
                    if w.buffer.count == chunk { try self.flush(&w, isFinal: false) }
                    let take = min(chunk - w.buffer.count, data.endIndex - offset)
                    w.buffer.append(data[offset..<offset + take])
                    offset += take
                }
                w.plainBytes += data.count
            }
        } catch {
            teardown()
            throw error
        }
    }

    /// Seals the final chunk and publishes the entry. The writer is unusable afterwards, whatever the outcome.
    public func commit() throws(MediaCacheError) {
        defer { teardown() }
        let (fileBytes, plainBytes) = try state.withLock { (w) throws(MediaCacheError) -> (Int, Int) in
            guard !w.closed else { throw .closed }
            try self.flush(&w, isFinal: true)
            fsync(w.fd)
            Darwin.close(w.fd)
            w.closed = true
            return (w.fileBytes, w.plainBytes)
        }
        try cache.finishCommit(
            hash: hash, mediaID: mediaID, contentType: contentType, tempPath: tempPath, fileBytes: fileBytes,
            plainBytes: plainBytes)
    }

    public func abort() { teardown() }

    private func flush(_ w: inout WriterState, isFinal: Bool) throws(MediaCacheError) {
        let sealed = w.sealer.sealChunk(w.buffer, index: w.nextIndex, isFinal: isFinal)
        w.buffer.removeAll(keepingCapacity: true)
        w.nextIndex += 1
        w.fileBytes += sealed.count
        guard w.fileBytes <= cache.capacityBytes else { throw .tooLarge }
        try writeAll(w.fd, sealed)
    }

    private func teardown() {
        let release = state.withLock { w -> Bool in
            if !w.closed {
                Darwin.close(w.fd)
                w.closed = true
            }
            unlink(tempPath)
            defer { w.released = true }
            return !w.released
        }
        if release { cache.releaseWriter(hash) }
    }
}

/// Returns verified plaintext chunks in order. Truncation or tampering throws `.corrupt` and deletes the entry.
public final class MediaReader: Sendable {
    private static let readSize = 256 * 1024

    private struct ReaderState {
        var fd: Int32
        var reader: MediaChunkSealer.Reader
        var scratch = [UInt8](repeating: 0, count: MediaReader.readSize)
        var pending: [Data] = []
        var seen = 0
        var done = false
        var released = false
    }

    public let mediaID: String
    public let contentType: String
    /// Plaintext length recorded when the entry was written.
    public let plaintextBytes: Int
    private let cache: MediaCache
    private let hash: String
    private let readerID: Int
    private let device: dev_t
    private let inode: ino_t
    private let state: Mutex<ReaderState>

    fileprivate init(
        cache: MediaCache, key: StoreKey, hash: String, payload: MediaPayload, fd: Int32, readerID: Int,
        device: dev_t, inode: ino_t
    ) {
        self.cache = cache
        self.hash = hash
        self.readerID = readerID
        self.device = device
        self.inode = inode
        mediaID = payload.mediaID
        contentType = payload.contentType
        plaintextBytes = payload.plainBytes
        state = Mutex(
            ReaderState(
                fd: fd, reader: MediaChunkSealer.Reader(MediaChunkSealer(key, mediaID: payload.mediaID))))
    }

    deinit { close() }

    /// The next plaintext chunk (up to 1 MiB), or nil at the verified end.
    public func next() throws(MediaCacheError) -> Data? {
        do throws(MediaCacheError) {
            return try state.withLock { (r) throws(MediaCacheError) -> Data? in try self.advance(&r) }
        } catch {
            if case .corrupt = error { cache.discardCorrupt(hash: hash, device: device, inode: inode) }
            close()
            throw error
        }
    }

    /// Releases the file and lets the entry be evicted again. Called by `deinit`.
    public func close() {
        state.withLock { release(&$0) }
    }

    private func advance(_ r: inout ReaderState) throws(MediaCacheError) -> Data? {
        while true {
            if !r.pending.isEmpty { return r.pending.removeFirst() }
            if r.done { return nil }
            guard !r.released else { throw .closed }
            let fd = r.fd
            let count = r.scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw .io(code: Int(errno))
            }
            do throws(StoreCryptoError) {
                if count == 0 {
                    try r.reader.finish()
                    guard r.seen == plaintextBytes else { throw .truncated }
                    r.done = true
                    release(&r)
                } else {
                    for chunk in try r.reader.consume(Data(r.scratch[0..<count])) where !chunk.isEmpty {
                        r.seen += chunk.count
                        guard r.seen <= plaintextBytes else { throw .trailingData }
                        r.pending.append(chunk)
                    }
                }
            } catch {
                throw .corrupt(error)
            }
        }
    }

    private func release(_ r: inout ReaderState) {
        guard !r.released else { return }
        r.released = true
        Darwin.close(r.fd)
        cache.releaseReader(readerID)
    }
}
