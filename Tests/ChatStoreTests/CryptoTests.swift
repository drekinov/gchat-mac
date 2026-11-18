import ChatKeychain
import ChatModel
import Foundation
import Testing

@testable import ChatStore

struct RowSealerTests {
    let a = StoreKey.random(for: AccountID())

    @Test func roundTrips() throws {
        let sealer = RowSealer(a)
        let sealed = sealer.seal(Data("hello".utf8), table: "messages", rowKey: "spaces/A/messages/1")
        #expect(try sealer.open(sealed, table: "messages", rowKey: "spaces/A/messages/1") == Data("hello".utf8))
    }

    @Test func rejectsRowTableAndAccountSubstitution() {
        let sealer = RowSealer(a)
        let sealed = sealer.seal(Data("x".utf8), table: "messages", rowKey: "r1")
        #expect(throws: StoreCryptoError.authenticationFailed) {
            try sealer.open(sealed, table: "messages", rowKey: "r2")
        }
        #expect(throws: StoreCryptoError.authenticationFailed) {
            try sealer.open(sealed, table: "drafts", rowKey: "r1")
        }

        let sameKeyOtherAccount = RowSealer(StoreKey(key: a.key, account: AccountID()))
        #expect(throws: StoreCryptoError.authenticationFailed) {
            try sameKeyOtherAccount.open(sealed, table: "messages", rowKey: "r1")
        }
        #expect(throws: StoreCryptoError.authenticationFailed) {
            try RowSealer(.random(for: a.account)).open(sealed, table: "messages", rowKey: "r1")
        }
    }

    @Test func aadFieldsCantBeShifted() {
        let sealer = RowSealer(a)
        #expect(sealer.aad(table: "ab", rowKey: "c") != sealer.aad(table: "a", rowKey: "bc"))
        #expect(sealer.aad(table: "a|b", rowKey: "c") != sealer.aad(table: "a", rowKey: "b|c"))
    }

    @Test func rejectsTamperingAndGarbage() {
        let sealer = RowSealer(a)
        var sealed = sealer.seal(Data("x".utf8), table: "t", rowKey: "r")
        sealed[sealed.count - 1] ^= 1
        #expect(throws: StoreCryptoError.authenticationFailed) { try sealer.open(sealed, table: "t", rowKey: "r") }
        #expect(throws: StoreCryptoError.malformed) { try sealer.open(Data([1, 2, 3]), table: "t", rowKey: "r") }
        #expect(throws: StoreCryptoError.malformed) { try sealer.open(Data(count: 64), table: "t", rowKey: "r") }
    }
}

struct MediaChunkTests {
    let key = StoreKey.random(for: AccountID())

    static let fileID = UUID()

    func file(
        _ chunks: [Data], mediaID: String = "m1", fileID: UUID = MediaChunkTests.fileID, finalAt: Int? = nil
    ) -> [Data] {
        let sealer = MediaChunkSealer(key, mediaID: mediaID, fileID: fileID)
        return chunks.enumerated().map { index, chunk in
            sealer.sealChunk(chunk, index: UInt64(index), isFinal: index == (finalAt ?? chunks.count - 1))
        }
    }

    func read(_ parts: [Data], mediaID: String = "m1", splitEvery: Int = 7) throws(StoreCryptoError) -> Data {
        var reader = MediaChunkSealer.Reader(MediaChunkSealer(key, mediaID: mediaID))
        let bytes = MediaChunkSealer(key, mediaID: mediaID, fileID: Self.fileID).header() + parts.reduce(Data(), +)
        var output = Data()
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + splitEvery, bytes.count)
            for chunk in try reader.consume(bytes.subdata(in: offset..<end)) { output += chunk }
            offset = end
        }
        try reader.finish()
        return output
    }

    @Test func roundTripsAcrossArbitraryReadBoundaries() throws {
        let chunks = [Data(repeating: 1, count: 100), Data(repeating: 2, count: 50), Data()]
        #expect(try read(file(chunks)) == chunks.reduce(Data(), +))
        #expect(try read(file(chunks), splitEvery: 1) == chunks.reduce(Data(), +))
    }

    @Test func detectsTruncation() {
        let parts = file([Data("a".utf8), Data("b".utf8), Data("c".utf8)])
        #expect(throws: StoreCryptoError.truncated) { try read(Array(parts.prefix(2))) }
        let cut = parts.reduce(Data(), +).dropLast(3)
        #expect(throws: StoreCryptoError.truncated) { try read([Data(cut)]) }
    }

    @Test func detectsReorderingAndDuplication() {
        let parts = file([Data("a".utf8), Data("b".utf8), Data("c".utf8)])
        #expect(throws: StoreCryptoError.outOfOrder) { try read([parts[0], parts[2], parts[1]]) }
        #expect(throws: StoreCryptoError.outOfOrder) { try read([parts[0], parts[0], parts[1], parts[2]]) }
    }

    @Test func detectsDataAfterFinalChunk() {
        let parts = file([Data("a".utf8), Data("b".utf8)])
        #expect(throws: StoreCryptoError.trailingData) { try read(parts + [parts[1]]) }
    }

    @Test func detectsCrossMediaSubstitution() {
        let mine = file([Data("a".utf8), Data("b".utf8)], mediaID: "m1")
        let other = file([Data("x".utf8), Data("y".utf8)], mediaID: "m2")
        #expect(throws: StoreCryptoError.authenticationFailed) { try read([other[0], mine[1]]) }
        #expect(throws: StoreCryptoError.outOfOrder) { try read([mine[0], other[1]]) }
    }

    @Test func detectsSplicingAcrossInstancesOfTheSameMedia() {
        let first = file([Data("a".utf8), Data("b".utf8)])
        let second = file([Data("x".utf8), Data("y".utf8)], fileID: UUID())
        #expect(throws: StoreCryptoError.outOfOrder) { try read([first[0], second[1]]) }
        #expect(throws: StoreCryptoError.authenticationFailed) { try read([second[0], first[1]]) }
    }

    @Test func rejectsBadHeaderAndOversizeLength() {
        var reader = MediaChunkSealer.Reader(MediaChunkSealer(key, mediaID: "m1"))
        #expect(throws: StoreCryptoError.malformed) { _ = try reader.consume(Data("NOPE".utf8)) }
        var reader2 = MediaChunkSealer.Reader(MediaChunkSealer(key, mediaID: "m1"))
        #expect(throws: StoreCryptoError.malformed) {
            _ = try reader2.consume(MediaChunkSealer(key, mediaID: "m1").header() + Data([0xFF, 0xFF, 0xFF, 0xFF]))
        }
    }
}

struct StoreKeyLifecycleTests {
    let account = AccountID()

    @Test func createsKeyOnlyWhenNoStoreExists() throws {
        let secrets = InMemorySecretStore()
        let lifecycle = StoreKeyLifecycle(secrets: secrets)
        let (first, state) = try lifecycle.open(for: account, storeExists: false)
        #expect(state == .ready)
        let (again, _) = try lifecycle.open(for: account, storeExists: true)
        #expect(first?.rawBytes == again?.rawBytes)
    }

    @Test func missingKeyBesideStoreIsShreddedAndNeverRegenerated() throws {
        let secrets = InMemorySecretStore()
        let lifecycle = StoreKeyLifecycle(secrets: secrets)
        let (key, state) = try lifecycle.open(for: account, storeExists: true)
        #expect(key == nil)
        #expect(state == .storeShredded)
        #expect(secrets.storedIDs.isEmpty)
    }

    @Test func keychainErrorsPropagateAndCreateNothing() {
        let secrets = InMemorySecretStore()
        secrets.setFailure(.interactionNotAllowed, for: StoreKeyLifecycle.secretID(for: account))
        let lifecycle = StoreKeyLifecycle(secrets: secrets)
        #expect(throws: SecretStoreError.interactionNotAllowed) { try lifecycle.open(for: account, storeExists: false) }
        #expect(throws: SecretStoreError.interactionNotAllowed) { try lifecycle.open(for: account, storeExists: true) }
    }

    @Test func shredMakesOldRowsUnreadable() throws {
        let secrets = InMemorySecretStore()
        let lifecycle = StoreKeyLifecycle(secrets: secrets)
        let key = try #require(try lifecycle.open(for: account, storeExists: false).0)
        let sealed = RowSealer(key).seal(Data("secret".utf8), table: "t", rowKey: "r")
        try lifecycle.shred(account)
        #expect(try lifecycle.open(for: account, storeExists: true).1 == .storeShredded)
        let fresh = try #require(try lifecycle.open(for: account, storeExists: false).0)
        #expect(throws: StoreCryptoError.authenticationFailed) {
            try RowSealer(fresh).open(sealed, table: "t", rowKey: "r")
        }
    }

    @Test func wrongLengthKeyIsAnErrorNotAbsent() {
        let secrets = InMemorySecretStore()
        try? secrets.write(Data(count: 16), for: StoreKeyLifecycle.secretID(for: account))
        #expect(throws: SecretStoreError.unexpectedData) {
            try StoreKeyLifecycle(secrets: secrets).open(for: account, storeExists: true)
        }
    }
}
