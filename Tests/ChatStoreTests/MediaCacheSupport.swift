import ChatModel
import CryptoKit
import Foundation
import Synchronization

@testable import ChatStore

let mebibyte = 1 << 20

/// Deterministic, incompressible-looking bytes.
func pattern(_ count: Int, seed: UInt64 = 1) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    var index = 0
    while index < count {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        var word = state
        for _ in 0..<min(8, count - index) {
            bytes[index] = UInt8(truncatingIfNeeded: word)
            word >>= 8
            index += 1
        }
    }
    return Data(bytes)
}

final class TestClock: Sendable {
    private let value = Mutex<Int64>(0)

    func set(_ seconds: Int64) { value.withLock { $0 = seconds } }
    var now: @Sendable () -> Int64 { { [self] in value.withLock { $0 } } }
}

extension Fixture {
    func mediaCache(
        capacity: Int = MediaCache.defaultCapacityBytes, clock: TestClock = TestClock()
    ) throws -> MediaCache {
        try MediaCache(directory: directory, key: key, capacityBytes: capacity, now: clock.now)
    }

    func mediaFile(_ mediaID: String) -> URL {
        directory.mediaURL.appendingPathComponent(MediaCache.hash(mediaID, key: key) + ".gcm")
    }

    var mediaFileNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.mediaURL.path)) ?? []).sorted()
    }
}

extension MediaCache {
    func put(_ mediaID: String, _ data: Data, type: String = "image/png", pieceSize: Int? = nil) throws(MediaCacheError)
    {
        let writer = try beginWrite(mediaID: mediaID, contentType: type)
        if let pieceSize {
            var offset = 0
            while offset < data.count {
                try writer.append(data.subdata(in: offset..<min(offset + pieceSize, data.count)))
                offset += pieceSize
            }
        } else {
            try writer.append(data)
        }
        try writer.commit()
    }

    func chunks(_ mediaID: String) throws(MediaCacheError) -> [Data]? {
        guard let reader = try open(mediaID: mediaID) else { return nil }
        var result: [Data] = []
        while let chunk = try reader.next() { result.append(chunk) }
        return result
    }

    func bytes(_ mediaID: String) throws(MediaCacheError) -> Data? {
        try chunks(mediaID).map { $0.reduce(into: Data()) { $0.append($1) } }
    }
}

func fileMode(_ url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
}

func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Paths under `root` whose bytes (or name) contain `needle`.
func filesContaining(_ needle: String, under root: URL) -> [String] {
    let bytes = Data(needle.utf8)
    var hits: [String] = []
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return hits
    }
    for case let url as URL in walker {
        if url.path.contains(needle) { hits.append(url.path) }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        if let data = try? Data(contentsOf: url), data.range(of: bytes) != nil { hits.append(url.path) }
    }
    return hits
}
