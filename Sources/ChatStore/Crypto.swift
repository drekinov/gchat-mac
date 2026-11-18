import ChatKeychain
import ChatModel
import CryptoKit
import Foundation

public enum StoreCryptoError: Error, Sendable, Equatable {
    case malformed
    case authenticationFailed
    case truncated
    case outOfOrder
    case trailingData
}

/// Per-account AES-256-GCM key. Never regenerated beside an existing store; see `StoreKeyLifecycle`.
public struct StoreKey: Sendable {
    let key: SymmetricKey
    public let account: AccountID

    init(key: SymmetricKey, account: AccountID) {
        precondition(key.bitCount == 256)
        self.key = key
        self.account = account
    }

    public static func random(for account: AccountID) -> StoreKey {
        StoreKey(key: SymmetricKey(size: .bits256), account: account)
    }

    var rawBytes: Data { key.withUnsafeBytes { Data($0) } }
}

/// Seals one row's serialized human-readable fields as a single AES-GCM payload. The AAD binds the ciphertext to
/// its account, table and row key, so rows can't be swapped between rows, tables or accounts.
public struct RowSealer: Sendable {
    static let version: UInt8 = 1
    let storeKey: StoreKey

    public init(_ storeKey: StoreKey) { self.storeKey = storeKey }

    public func seal(_ plaintext: Data, table: String, rowKey: String) -> Data {
        let box = try! AES.GCM.seal(plaintext, using: storeKey.key, authenticating: aad(table: table, rowKey: rowKey))
        return Data([Self.version]) + box.combined!
    }

    public func open(_ sealed: Data, table: String, rowKey: String) throws(StoreCryptoError) -> Data {
        guard sealed.count >= 1 + 12 + 16, sealed.first == Self.version else { throw .malformed }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.dropFirst())
            return try AES.GCM.open(box, using: storeKey.key, authenticating: aad(table: table, rowKey: rowKey))
        } catch {
            throw .authenticationFailed
        }
    }

    func aad(table: String, rowKey: String) -> Data {
        AAD.encode("gchat-mac.row.v1", [storeKey.account.description, table, rowKey])
    }
}

/// Media is a sequence of sealed chunks of at most `chunkSize` plaintext bytes. Each chunk's AAD carries the media
/// ID, a random per-file instance ID, its index and a final flag, so truncation, reordering, splicing within or
/// across files, and cross-media substitution all fail.
///
/// File layout: `"GCM2"`, the 16-byte instance ID, then per chunk a big-endian `UInt32` sealed length followed by
/// the sealed bytes.
public struct MediaChunkSealer: Sendable {
    public static let chunkSize = 1 << 20
    static let magic = Data("GCM2".utf8)
    static let headerSize = 4 + 16
    static let sealedOverhead = 12 + 16

    let storeKey: StoreKey
    let mediaID: String
    let fileID: UUID

    /// Writers use a fresh `fileID` per file; readers take it from the header.
    public init(_ storeKey: StoreKey, mediaID: String, fileID: UUID = UUID()) {
        self.storeKey = storeKey
        self.mediaID = mediaID
        self.fileID = fileID
    }

    public func header() -> Data {
        Self.magic + withUnsafeBytes(of: fileID.uuid) { Data($0) }
    }

    public func sealChunk(_ plaintext: Data, index: UInt64, isFinal: Bool) -> Data {
        precondition(plaintext.count <= Self.chunkSize)
        let box = try! AES.GCM.seal(plaintext, using: storeKey.key, authenticating: aad(index: index, isFinal: isFinal))
        let sealed = box.combined!
        var length = UInt32(sealed.count).bigEndian
        return Data(bytes: &length, count: 4) + sealed
    }

    func aad(index: UInt64, isFinal: Bool) -> Data {
        AAD.encode(
            "gchat-mac.media.v2",
            [storeKey.account.description, mediaID, fileID.uuidString, String(index), isFinal ? "final" : "more"])
    }

    /// Incremental reader: feed bytes as they come off disk and collect plaintext chunks in order.
    public struct Reader: Sendable {
        var sealer: MediaChunkSealer
        private var buffer = Data()
        private var headerRead = false
        private var nextIndex: UInt64 = 0
        public private(set) var isComplete = false

        public init(_ sealer: MediaChunkSealer) { self.sealer = sealer }

        public mutating func consume(_ bytes: Data) throws(StoreCryptoError) -> [Data] {
            guard !isComplete || bytes.isEmpty else { throw .trailingData }
            buffer.append(bytes)
            if !headerRead {
                if buffer.count >= MediaChunkSealer.magic.count,
                    buffer.prefix(MediaChunkSealer.magic.count) != MediaChunkSealer.magic
                {
                    throw .malformed
                }
                guard buffer.count >= MediaChunkSealer.headerSize else { return [] }
                let idBytes = Array(buffer.dropFirst(MediaChunkSealer.magic.count).prefix(16))
                let uuid = idBytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
                sealer = MediaChunkSealer(sealer.storeKey, mediaID: sealer.mediaID, fileID: UUID(uuid: uuid))
                buffer.removeFirst(MediaChunkSealer.headerSize)
                headerRead = true
            }
            var output: [Data] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                guard length >= MediaChunkSealer.sealedOverhead,
                    length <= MediaChunkSealer.chunkSize + MediaChunkSealer.sealedOverhead
                else { throw .malformed }
                guard buffer.count >= 4 + length else { break }
                guard !isComplete else { throw .trailingData }
                let sealed = Data(buffer.dropFirst(4).prefix(length))
                buffer.removeFirst(4 + length)
                output.append(try open(sealed))
            }
            if isComplete, !buffer.isEmpty { throw .trailingData }
            return output
        }

        /// Call at end of file. Throws unless the final chunk was seen and nothing is left over.
        public func finish() throws(StoreCryptoError) {
            guard headerRead, isComplete, buffer.isEmpty else { throw .truncated }
        }

        private mutating func open(_ sealed: Data) throws(StoreCryptoError) -> Data {
            let box: AES.GCM.SealedBox
            do { box = try AES.GCM.SealedBox(combined: sealed) } catch { throw .malformed }
            for isFinal in [false, true] {
                if let plaintext = try? AES.GCM.open(
                    box, using: sealer.storeKey.key, authenticating: sealer.aad(index: nextIndex, isFinal: isFinal))
                {
                    nextIndex += 1
                    isComplete = isFinal
                    return plaintext
                }
            }
            throw nextIndex == 0 ? .authenticationFailed : .outOfOrder
        }
    }
}

/// Length-prefixed AAD, so no field value can be confused with a separator.
enum AAD {
    static func encode(_ domain: String, _ fields: [String]) -> Data {
        var data = Data(domain.utf8)
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt32(bytes.count).bigEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(bytes)
        }
        return data
    }
}

public enum StoreKeyState: Sendable, Equatable {
    case ready
    /// The key is gone but a store exists: the store was crypto-shredded and must be deleted, not reopened.
    case storeShredded
}

/// Key rules: an existing key is used; no key and no store creates one; no key with a store means shredded;
/// any keychain error propagates and is never treated as "absent".
public struct StoreKeyLifecycle: Sendable {
    let secrets: any SecretStore

    public init(secrets: any SecretStore) { self.secrets = secrets }

    public static func secretID(for account: AccountID) -> SecretID {
        SecretID(service: "io.github.drekinov.gchat-mac.store-key", account: account.description)
    }

    public func open(
        for account: AccountID, storeExists: Bool
    ) throws(SecretStoreError) -> (StoreKey?, StoreKeyState) {
        let id = Self.secretID(for: account)
        if let data = try secrets.read(id) {
            guard data.count == 32 else { throw .unexpectedData }
            return (StoreKey(key: SymmetricKey(data: data), account: account), .ready)
        }
        if storeExists { return (nil, .storeShredded) }
        let key = StoreKey.random(for: account)
        try secrets.write(key.rawBytes, for: id)
        return (key, .ready)
    }

    /// Crypto-shred: after this succeeds no sealed row or media of the account can be opened.
    public func shred(_ account: AccountID) throws(SecretStoreError) {
        try secrets.delete(Self.secretID(for: account))
    }
}
