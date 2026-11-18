import ChatKeychain
import ChatModel
import Foundation
import Synchronization
import Testing

@testable import ChatStore

private let canary = "CANARY-7f3a"

@Suite struct MediaCacheRoundTripTests {
    @Test(arguments: [0, 1, mebibyte, mebibyte + 1, 5 * mebibyte + mebibyte / 2], [nil, 100_003])
    func roundTrips(size: Int, pieceSize: Int?) throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        let data = pattern(size)
        try cache.put("media/one", data, type: "image/jpeg", pieceSize: pieceSize)

        let reader = try #require(try cache.open(mediaID: "media/one"))
        #expect(reader.mediaID == "media/one")
        #expect(reader.contentType == "image/jpeg")
        #expect(reader.plaintextBytes == size)
        var chunks: [Data] = []
        while let chunk = try reader.next() { chunks.append(chunk) }
        #expect(try reader.next() == nil)

        #expect(chunks.reduce(into: Data()) { $0.append($1) } == data)
        #expect(chunks.count == (size + mebibyte - 1) / mebibyte)
        #expect(chunks.dropLast().allSatisfy { $0.count == mebibyte })
        #expect(cache.contains(mediaID: "media/one"))
        #expect(try f.mediaFile("media/one").resourceValues(forKeys: [.fileSizeKey]).fileSize == cache.totalBytes)
    }

    @Test func unknownMediaIsNil() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        #expect(try cache.open(mediaID: "nope") == nil)
        #expect(!cache.contains(mediaID: "nope"))
        #expect(cache.totalBytes == 0)
    }

    @Test func rewritingAnEntryReplacesIt() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        try cache.put("m", pattern(500, seed: 1))
        try cache.put("m", pattern(900, seed: 2), type: "text/plain")
        #expect(try cache.bytes("m") == pattern(900, seed: 2))
        #expect(try cache.open(mediaID: "m")?.contentType == "text/plain")
        #expect(f.mediaFileNames.count == 1)
    }

    @Test func writerBuffersAtMostOneChunk() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        let writer = try cache.beginWrite(mediaID: "big", contentType: "application/octet-stream")
        try writer.append(pattern(5 * mebibyte + 17))
        #expect(writer.bufferedBytes <= MediaChunkSealer.chunkSize)
        for _ in 0..<5 {
            try writer.append(pattern(333_333))
            #expect(writer.bufferedBytes <= MediaChunkSealer.chunkSize)
        }
        try writer.commit()
        #expect(try cache.bytes("big")?.count == 5 * mebibyte + 17 + 5 * 333_333)
    }

    @Test func onDiskNamesAndPermissions() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        try cache.put("media/secret-name.png", pattern(10))
        #expect(f.mediaFileNames == [MediaCache.hash("media/secret-name.png", key: f.key) + ".gcm"])
        #expect(try fileMode(f.mediaFile("media/secret-name.png")) == 0o600)
        #expect(try fileMode(f.directory.mediaURL) == 0o700)
        #expect(try f.mediaFile("media/secret-name.png").path.contains("secret-name") == false)
    }

    @Test func removeAndRemoveAll() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        try cache.put("a", pattern(10))
        try cache.put("b", pattern(10))
        try cache.remove(mediaID: "a")
        #expect(!cache.contains(mediaID: "a"))
        #expect(cache.contains(mediaID: "b"))
        try cache.remove(mediaID: "a")
        try cache.removeAll()
        #expect(cache.totalBytes == 0)
        #expect(f.mediaFileNames.isEmpty)
        #expect(try cache.open(mediaID: "b") == nil)
    }

    @Test func survivesReopening() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        try cache.put("m", pattern(3 * mebibyte))
        cache.close()
        #expect(throws: MediaCacheError.closed) { try cache.open(mediaID: "m") }
        let again = try f.mediaCache()
        #expect(try again.bytes("m") == pattern(3 * mebibyte))
    }
}

@Suite struct MediaCacheWriterTests {
    @Test func aSecondWriterForTheSameMediaIsBusy() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        let first = try cache.beginWrite(mediaID: "m", contentType: "x")
        #expect(throws: MediaCacheError.busy) { try cache.beginWrite(mediaID: "m", contentType: "x") }
        _ = try cache.beginWrite(mediaID: "other", contentType: "x")
        first.abort()
        let second = try cache.beginWrite(mediaID: "m", contentType: "x")
        try second.append(pattern(5))
        try second.commit()
        _ = try cache.beginWrite(mediaID: "m", contentType: "x")
    }

    @Test func abortAndDeinitDeleteTheTempFile() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        let aborted = try cache.beginWrite(mediaID: "a", contentType: "x")
        try aborted.append(pattern(2 * mebibyte))
        #expect(f.mediaFileNames.count == 1)
        aborted.abort()
        #expect(f.mediaFileNames.isEmpty)
        #expect(throws: MediaCacheError.closed) { try aborted.append(pattern(1)) }

        do {
            let dropped = try cache.beginWrite(mediaID: "b", contentType: "x")
            try dropped.append(pattern(2 * mebibyte))
            #expect(f.mediaFileNames.count == 1)
        }
        #expect(f.mediaFileNames.isEmpty)
        #expect(!cache.contains(mediaID: "a") && !cache.contains(mediaID: "b"))
        _ = try cache.beginWrite(mediaID: "b", contentType: "x")
    }

    @Test func nothingIsVisibleBeforeCommit() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        let writer = try cache.beginWrite(mediaID: "m", contentType: "x")
        try writer.append(pattern(100))
        #expect(try cache.open(mediaID: "m") == nil)
        try writer.commit()
        #expect(try cache.bytes("m") == pattern(100))
        #expect(throws: MediaCacheError.closed) { try writer.commit() }
    }

    @Test func crashMidWriteLeavesATempFileThatInitRemoves() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        try cache.put("keep", pattern(1000))
        let crashed = try cache.beginWrite(mediaID: "lost", contentType: "x")
        try crashed.append(pattern(3 * mebibyte))
        #expect(f.mediaFileNames.contains { $0.hasSuffix(".tmp") })

        let orphan = f.directory.mediaURL.appendingPathComponent("stray.tmp")
        try Data("junk".utf8).write(to: orphan)
        let unindexed = f.directory.mediaURL.appendingPathComponent(String(repeating: "a", count: 64) + ".gcm")
        try Data("junk".utf8).write(to: unindexed)

        let restarted = try f.mediaCache()
        #expect(f.mediaFileNames == [MediaCache.hash("keep", key: f.key) + ".gcm"])
        #expect(try restarted.bytes("keep") == pattern(1000))
        #expect(try restarted.open(mediaID: "lost") == nil)
        crashed.abort()
    }

    @Test func indexRowsWithoutFilesAreDropped() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        try cache.put("m", pattern(1000))
        cache.close()
        try FileManager.default.removeItem(at: f.mediaFile("m"))
        let restarted = try f.mediaCache()
        #expect(restarted.totalBytes == 0)
        #expect(!restarted.contains(mediaID: "m"))
    }

    @Test func aSingleEntryLargerThanTheCapacityIsRejectedCleanly() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache(capacity: 35_000)
        let writer = try cache.beginWrite(mediaID: "huge", contentType: "x")
        try writer.append(pattern(50_000))
        #expect(throws: MediaCacheError.tooLarge) { try writer.commit() }
        #expect(f.mediaFileNames.isEmpty)
        #expect(cache.totalBytes == 0)
        _ = try cache.beginWrite(mediaID: "huge", contentType: "x")
    }

    @Test func aFailedAppendDiscardsTheWriter() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache(capacity: 2 * mebibyte)
        let writer = try cache.beginWrite(mediaID: "huge", contentType: "x")
        #expect(throws: MediaCacheError.tooLarge) { try writer.append(pattern(4 * mebibyte)) }
        #expect(f.mediaFileNames.isEmpty)
        _ = try cache.beginWrite(mediaID: "huge", contentType: "x")
    }
}

@Suite struct MediaCacheIntegrityTests {
    private func corrupt(_ name: String, _ mutate: (inout Data) -> Void) throws -> Fixture {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        try cache.put(name, pattern(5 * mebibyte / 2))
        var bytes = try Data(contentsOf: f.mediaFile(name))
        mutate(&bytes)
        try bytes.write(to: f.mediaFile(name))
        return f
    }

    private func expectRejected(_ f: Fixture, _ name: String) throws {
        let cache = try f.mediaCache()
        let reader = try #require(try cache.open(mediaID: name))
        do throws(MediaCacheError) {
            while try reader.next() != nil {}
            Issue.record("expected the read to fail")
        } catch {
            if case .corrupt = error {} else { Issue.record("unexpected error \(error)") }
        }
        #expect(!cache.contains(mediaID: name))
        #expect(!FileManager.default.fileExists(atPath: f.mediaFile(name).path))
        #expect(try cache.open(mediaID: name) == nil)
    }

    private var chunkRecord: Int { 4 + mebibyte + MediaChunkSealer.sealedOverhead }

    @Test(arguments: [100, 20 + 10, 1_500_000, 2_200_000]) func flippedByte(at offset: Int) throws {
        let f = try corrupt("m") { $0[offset] ^= 0x01 }
        try expectRejected(f, "m")
    }

    @Test func truncatedMidChunk() throws {
        let f = try corrupt("m") { $0.removeLast(1000) }
        try expectRejected(f, "m")
    }

    @Test func truncatedAtAChunkBoundary() throws {
        let boundary = MediaChunkSealer.headerSize + 2 * chunkRecord
        let f = try corrupt("m") { $0.removeSubrange(boundary...) }
        try expectRejected(f, "m")
    }

    @Test func truncatedToHeaderOrNothing() throws {
        try expectRejected(try corrupt("m") { $0.removeSubrange(MediaChunkSealer.headerSize...) }, "m")
        try expectRejected(try corrupt("m") { $0.removeAll() }, "m")
    }

    @Test func reorderedChunks() throws {
        let f = try corrupt("m") { bytes in
            let start = MediaChunkSealer.headerSize
            let first = bytes.subdata(in: start..<start + chunkRecord)
            let second = bytes.subdata(in: start + chunkRecord..<start + 2 * chunkRecord)
            bytes.replaceSubrange(start..<start + 2 * chunkRecord, with: second + first)
        }
        try expectRejected(f, "m")
    }

    @Test func trailingGarbage() throws {
        let f = try corrupt("m") { $0.append(Data([1, 2, 3, 4, 5])) }
        try expectRejected(f, "m")
    }

    @Test func anotherMediasFileInPlace() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        try cache.put("a", pattern(3000, seed: 1))
        try cache.put("b", pattern(3000, seed: 1))
        try FileManager.default.removeItem(at: f.mediaFile("a"))
        try FileManager.default.copyItem(at: f.mediaFile("b"), to: f.mediaFile("a"))
        try expectRejected(f, "a")
        #expect(try cache.bytes("b") == pattern(3000, seed: 1))
    }

    @Test func aTamperedIndexRowIsRejected() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        try cache.put("a", pattern(100))
        try cache.put("b", pattern(100))
        cache.close()
        let raw = try Connection(path: f.directory.storeURL.path)
        try raw.execute(
            "UPDATE media SET payload = (SELECT payload FROM media WHERE media_hash = '\(MediaCache.hash("b", key: f.key))') "
                + "WHERE media_hash = '\(MediaCache.hash("a", key: f.key))'")
        raw.close()
        let again = try f.mediaCache()
        #expect(throws: MediaCacheError.corrupt(.authenticationFailed)) { try again.open(mediaID: "a") }
        #expect(!again.contains(mediaID: "a"))
        #expect(try again.bytes("b") == pattern(100))
    }

    @Test func replacingAFileUnderAnOpenReaderDoesNotDeleteTheNewEntry() throws {
        let f = try corrupt("m") { $0[1_500_000] ^= 0x01 }
        let cache = try f.mediaCache()
        let stale = try #require(try cache.open(mediaID: "m"))
        try cache.put("m", pattern(2000, seed: 9))
        #expect(throws: MediaCacheError.self) { while try stale.next() != nil {} }
        #expect(try cache.bytes("m") == pattern(2000, seed: 9))
    }
}

@Suite struct MediaCacheEvictionTests {
    private let entry = 10_000
    private let capacity = 35_000

    private func present(_ cache: MediaCache, _ ids: [String]) -> [String] {
        ids.filter { cache.contains(mediaID: $0) }
    }

    @Test func evictsLeastRecentlyUsedFirst() throws {
        let f = try Fixture(.sqlite)
        let clock = TestClock()
        let cache = try f.mediaCache(capacity: capacity, clock: clock)
        for (offset, id) in ["a", "b", "c"].enumerated() {
            clock.set(Int64(offset + 1))
            try cache.put(id, pattern(entry))
        }
        clock.set(4)
        #expect(try cache.bytes("a") != nil)
        clock.set(5)
        try cache.put("d", pattern(entry))
        #expect(present(cache, ["a", "b", "c", "d"]) == ["a", "c", "d"])
        clock.set(6)
        try cache.put("e", pattern(entry))
        #expect(present(cache, ["a", "b", "c", "d", "e"]) == ["a", "d", "e"])
    }

    @Test func openReadersAreNeverEvicted() throws {
        let f = try Fixture(.sqlite)
        let clock = TestClock()
        let cache = try f.mediaCache(capacity: capacity, clock: clock)
        clock.set(1)
        try cache.put("a", pattern(entry, seed: 7))
        clock.set(2)
        let reader = try #require(try cache.open(mediaID: "a"))
        for (offset, id) in ["b", "c", "d", "e"].enumerated() {
            clock.set(Int64(offset + 3))
            try cache.put(id, pattern(entry))
        }
        #expect(present(cache, ["a", "b", "c", "d", "e"]) == ["a", "d", "e"])
        var data = Data()
        while let chunk = try reader.next() { data.append(chunk) }
        #expect(data == pattern(entry, seed: 7))

        clock.set(10)
        try cache.put("f", pattern(entry))
        #expect(present(cache, ["a", "d", "e", "f"]) == ["d", "e", "f"])
    }

    @Test func aClosedReaderReleasesItsEntry() throws {
        let f = try Fixture(.sqlite)
        let clock = TestClock()
        let cache = try f.mediaCache(capacity: capacity, clock: clock)
        clock.set(1)
        try cache.put("a", pattern(entry))
        clock.set(2)
        var reader = try cache.open(mediaID: "a")
        for (offset, id) in ["b", "c", "d"].enumerated() {
            clock.set(Int64(offset + 3))
            try cache.put(id, pattern(entry))
        }
        #expect(cache.contains(mediaID: "a"))
        reader?.close()
        reader = nil
        clock.set(9)
        try cache.put("e", pattern(entry))
        #expect(present(cache, ["a", "b", "c", "d", "e"]) == ["c", "d", "e"])
    }

    @Test func totalStaysWithinCapacity() throws {
        let f = try Fixture(.sqlite)
        let clock = TestClock()
        let cache = try f.mediaCache(capacity: capacity, clock: clock)
        for index in 0..<30 {
            clock.set(Int64(index))
            try cache.put("m\(index)", pattern(entry + index * 100, seed: UInt64(index + 1)))
            #expect(cache.totalBytes <= capacity)
        }
        #expect(cache.totalBytes > 0)
        #expect(cache.contains(mediaID: "m29"))
        #expect(!cache.contains(mediaID: "m0"))
        let onDisk = f.mediaFileNames.compactMap {
            try? f.directory.mediaURL.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]).fileSize
        }
        #expect(onDisk.reduce(0, +) == cache.totalBytes)
    }

    @Test func theFreshEntryIsKeptEvenWhenTimestampsTie() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache(capacity: capacity, clock: TestClock())
        for index in 0..<10 { try cache.put("m\(index)", pattern(entry)) }
        #expect(cache.contains(mediaID: "m9"))
        #expect(cache.totalBytes <= capacity)
    }
}

@Suite struct MediaCacheConcurrencyTests {
    @Test func parallelWritersAndReadersOfDifferentMedia() async throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let id = "media/\(index)"
                    let data = pattern(300_000 + index * 77_777, seed: UInt64(index + 1))
                    try cache.put(id, data, pieceSize: 50_000)
                    for _ in 0..<5 {
                        let readBack = try cache.bytes(id)
                        #expect(readBack == data)
                    }
                }
            }
            try await group.waitForAll()
        }
        for index in 0..<16 {
            #expect(try cache.bytes("media/\(index)") == pattern(300_000 + index * 77_777, seed: UInt64(index + 1)))
        }
        #expect(f.mediaFileNames.allSatisfy { $0.hasSuffix(".gcm") })
    }

    @Test func racingWritersOfOneMediaAllowExactlyOneAtATime() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        let data = pattern(2 * mebibyte)
        let outcomes = Mutex((committed: 0, busy: 0))
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do throws(MediaCacheError) {
                try cache.put("same", data, pieceSize: 400_000)
                outcomes.withLock { $0.committed += 1 }
            } catch {
                if error == .busy {
                    outcomes.withLock { $0.busy += 1 }
                } else {
                    Issue.record("unexpected \(error)")
                }
            }
        }
        let result = outcomes.withLock { $0 }
        #expect(result.committed >= 1)
        #expect(result.committed + result.busy == 16)
        #expect(try cache.bytes("same") == data)
        #expect(f.mediaFileNames.count == 1)
    }

    @Test func readersAndEvictionRaceSafely() async throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache(capacity: 600_000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    for round in 0..<10 {
                        let id = "m\((index + round) % 6)"
                        do throws(MediaCacheError) {
                            try cache.put(id, pattern(100_000, seed: UInt64((index + round) % 6 + 1)))
                        } catch {
                            #expect(error == .busy)
                        }
                        if let data = try cache.bytes("m\(round % 6)") {
                            #expect(data.count == 100_000)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(cache.totalBytes <= 600_000)
    }
}

@Suite struct MediaCacheAtRestTests {
    @Test func nothingReadableLandsOnDisk() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache()
        let secret = Data((String(repeating: "\(canary) ", count: 40_000)).utf8)
        let id = "media/\(canary)/id"
        try cache.put(id, secret, type: "image/\(canary)", pieceSize: 70_000)
        try cache.put("small", Data(canary.utf8), type: canary)
        #expect(try cache.bytes(id) == secret)

        #expect(filesContaining(canary, under: f.temp.url).isEmpty)
        cache.close()
        f.closeSQLite()
        #expect(filesContaining(canary, under: f.temp.url).isEmpty)
        let scanned = (FileManager.default.enumerator(atPath: f.temp.url.path)?.allObjects ?? []).count
        #expect(scanned >= 4)
    }

    @Test func theScannerFindsPlaintext() throws {
        let temp = TempDirectory()
        try FileManager.default.createDirectory(at: temp.url, withIntermediateDirectories: true)
        try Data("xx\(canary)yy".utf8).write(to: temp.url.appendingPathComponent("plain.bin"))
        #expect(filesContaining(canary, under: temp.url).count == 1)
    }

    @Test func afterTheKeyIsShreddedNothingCanBeRead() throws {
        let secrets = InMemorySecretStore()
        let lifecycle = StoreKeyLifecycle(secrets: secrets)
        let temp = TempDirectory()
        let account = AccountID()
        let directory = AccountDirectory(root: temp.url, account: account)
        let (opened, state) = try lifecycle.open(for: account, storeExists: false)
        let key = try #require(opened)
        #expect(state == .ready)

        let store = try SQLiteAccountStore.open(directory: directory, key: key)
        let cache = try MediaCache(directory: directory, key: key)
        try cache.put("m", pattern(5000))
        #expect(try cache.bytes("m") == pattern(5000))
        cache.close()
        store.close()

        try lifecycle.shred(account)
        let (shredded, shreddedState) = try lifecycle.open(for: account, storeExists: directory.storeExists())
        #expect(shredded == nil)
        #expect(shreddedState == .storeShredded)

        let stranger = StoreKey.random(for: account)
        #expect(throws: StoreError.crypto(.authenticationFailed)) {
            try SQLiteAccountStore.open(directory: directory, key: stranger)
        }
        // Names are keyed too, so a stranger key doesn't even find the file; the ciphertext stays unreadable.
        let blind = try MediaCache(directory: directory, key: stranger)
        #expect(try blind.open(mediaID: "m") == nil)
    }
}

@Suite struct MediaCacheSchemaTests {
    @Test func migratesFromVersionOneToTwo() throws {
        let temp = TempDirectory()
        let account = AccountID()
        let key = StoreKey.random(for: account)
        let directory = AccountDirectory(root: temp.url, account: account)
        let gate = SessionGate()

        let v1 = Array(SQLiteAccountStore.migrations().prefix(1))
        let old = try SQLiteAccountStore.open(directory: directory, key: key, migrations: v1)
        try old.write(gate: gate, generation: gate.current!) { $0.append(.setMeta(key: "k", value: "kept")) }
        old.close()

        let before = try Connection(path: directory.storeURL.path)
        #expect(try before.userVersion() == 1)
        #expect(try before.prepare("SELECT name FROM sqlite_master WHERE name = 'media'").first { $0.text(0) } == nil)
        before.close()
        #expect(throws: MediaCacheError.indexUnavailable) { try MediaCache(directory: directory, key: key) }

        let store = try SQLiteAccountStore.open(directory: directory, key: key)
        #expect(try store.meta("k") == "kept")
        let after = try Connection(path: directory.storeURL.path)
        #expect(try after.userVersion() == 2)
        let columns = try after.prepare("PRAGMA table_info(media)").rows { $0.text(1) }
        #expect(columns == ["media_hash", "bytes", "last_access_s", "payload"])
        after.close()

        let cache = try MediaCache(directory: directory, key: key)
        try cache.put("m", pattern(10))
        #expect(try cache.bytes("m") == pattern(10))
        store.close()
    }

    @Test func requiresAnExistingStore() throws {
        let temp = TempDirectory()
        let account = AccountID()
        let directory = AccountDirectory(root: temp.url, account: account)
        #expect(throws: MediaCacheError.indexUnavailable) {
            try MediaCache(directory: directory, key: StoreKey.random(for: account))
        }
        #expect(!directory.storeExists())
    }

    @Test func rejectsAKeyOfAnotherAccount() throws {
        let f = try Fixture(.sqlite)
        #expect(throws: MediaCacheError.store(.crypto(.authenticationFailed))) {
            try MediaCache(directory: f.directory, key: StoreKey.random(for: AccountID()))
        }
    }
}
