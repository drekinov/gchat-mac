import Foundation
import Testing

@testable import ChatStore

@Suite struct MediaCachePinnedCapacityTests {
    private let entry = 10_000
    private let capacity = 35_000

    private func diskBytes(_ f: Fixture) -> Int {
        f.mediaFileNames.compactMap {
            try? f.directory.mediaURL.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]).fileSize
        }.reduce(0, +)
    }

    @Test func pinnedReadersCannotPushTheCachePastCapacity() throws {
        let f = try Fixture(.sqlite)
        let clock = TestClock()
        let cache = try f.mediaCache(capacity: capacity, clock: clock)
        var readers: [MediaReader] = []
        var rejected = 0
        for index in 0..<10 {
            clock.set(Int64(index))
            do throws(MediaCacheError) {
                try cache.put("m\(index)", pattern(entry, seed: UInt64(index + 1)))
                if let reader = try cache.open(mediaID: "m\(index)") { readers.append(reader) }
            } catch {
                #expect(error == .full)
                #expect(!cache.contains(mediaID: "m\(index)"))
                rejected += 1
            }
            #expect(cache.totalBytes <= capacity)
            #expect(diskBytes(f) <= capacity)
        }
        #expect(rejected > 0)
        #expect(readers.count == 3)
        #expect(f.mediaFileNames.allSatisfy { $0.hasSuffix(".gcm") })
        for (index, reader) in readers.enumerated() {
            var data = Data()
            while let chunk = try reader.next() { data.append(chunk) }
            #expect(data == pattern(entry, seed: UInt64(index + 1)))
        }
    }

    @Test func aRejectedCommitEvictsNothing() throws {
        let f = try Fixture(.sqlite)
        let clock = TestClock()
        let cache = try f.mediaCache(capacity: capacity, clock: clock)
        for index in 0..<3 {
            clock.set(Int64(index))
            try cache.put("m\(index)", pattern(entry))
        }
        let pinned = [try #require(try cache.open(mediaID: "m0")), try #require(try cache.open(mediaID: "m1"))]
        clock.set(10)
        #expect(throws: MediaCacheError.full) { try cache.put("big", pattern(2 * entry)) }
        #expect(["m0", "m1", "m2"].allSatisfy { cache.contains(mediaID: $0) })
        #expect(!cache.contains(mediaID: "big"))
        #expect(f.mediaFileNames.count == 3)
        withExtendedLifetime(pinned) {}
    }

    @Test func closingReadersMakesRoomAgain() throws {
        let f = try Fixture(.sqlite)
        let clock = TestClock()
        let cache = try f.mediaCache(capacity: capacity, clock: clock)
        var readers: [MediaReader] = []
        for index in 0..<3 {
            clock.set(Int64(index))
            try cache.put("m\(index)", pattern(entry))
            readers.append(try #require(try cache.open(mediaID: "m\(index)")))
        }
        clock.set(5)
        #expect(throws: MediaCacheError.full) { try cache.put("m3", pattern(entry)) }

        readers[0].close()
        clock.set(6)
        try cache.put("m3", pattern(entry))
        #expect(cache.totalBytes <= capacity)
        #expect(!cache.contains(mediaID: "m0"))
        #expect(cache.contains(mediaID: "m1") && cache.contains(mediaID: "m2") && cache.contains(mediaID: "m3"))
    }

    @Test func aReplacedEntryThatIsStillPinnedKeepsCountingUntilItsReaderCloses() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache(capacity: capacity)
        try cache.put("a", pattern(20_000, seed: 1))
        let reader = try #require(try cache.open(mediaID: "a"))
        #expect(throws: MediaCacheError.full) { try cache.put("a", pattern(20_000, seed: 2)) }
        #expect(try cache.bytes("a") == pattern(20_000, seed: 1))

        var data = Data()
        while let chunk = try reader.next() { data.append(chunk) }
        #expect(data == pattern(20_000, seed: 1))
        try cache.put("a", pattern(20_000, seed: 2))
        #expect(try cache.bytes("a") == pattern(20_000, seed: 2))
    }

    @Test func aRemovedButPinnedFileStillCountsAgainstCapacity() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache(capacity: capacity)
        try cache.put("a", pattern(20_000))
        let reader = try #require(try cache.open(mediaID: "a"))
        try cache.remove(mediaID: "a")
        #expect(throws: MediaCacheError.full) { try cache.put("b", pattern(20_000)) }
        reader.close()
        try cache.put("b", pattern(20_000))
        #expect(cache.contains(mediaID: "b"))
    }

    @Test func manyReadersOfOneEntryCountItOnce() throws {
        let f = try Fixture(.sqlite)
        let cache = try f.mediaCache(capacity: capacity)
        try cache.put("a", pattern(entry))
        let readers = try (0..<20).map { _ in try #require(try cache.open(mediaID: "a")) }
        try cache.put("b", pattern(entry))
        try cache.put("c", pattern(entry))
        #expect(cache.totalBytes <= capacity)
        withExtendedLifetime(readers) {}
    }

    @Test func reopeningWithASmallerCapacityTrims() throws {
        let f = try Fixture(.sqlite)
        let clock = TestClock()
        let big = try f.mediaCache(capacity: 100_000, clock: clock)
        for index in 0..<6 {
            clock.set(Int64(index))
            try big.put("m\(index)", pattern(entry))
        }
        big.close()
        let small = try f.mediaCache(capacity: capacity, clock: clock)
        #expect(small.totalBytes <= capacity)
        #expect(small.contains(mediaID: "m5"))
        #expect(!small.contains(mediaID: "m0"))
    }
}
