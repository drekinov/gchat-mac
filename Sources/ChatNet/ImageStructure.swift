import Foundation

/// Checks container integrity only: that a PNG, JPEG or GIF is made of well-formed chunks, segments or blocks
/// that reach their terminal marker. ImageIO reports a cut-off file as complete, and a forged end marker doesn't
/// pass this walk. It does not promise that the compressed pixel stream inside is complete: a file cut inside
/// entropy-coded or deflate data and then given valid framing decodes to a partly filled image of the declared
/// size. Bytes after the terminal marker are ignored.
enum ImageStructure {
    static func isComplete(_ data: Data, type: String) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            switch type {
            case "public.png": return pngIsComplete(bytes)
            case "public.jpeg": return jpegIsComplete(bytes)
            case "com.compuserve.gif": return gifIsComplete(bytes)
            case "org.webmproject.webp": return webpIsComplete(bytes)
            default: return true
            }
        }
    }

    // MARK: PNG

    private static func pngIsComplete(_ d: UnsafeBufferPointer<UInt8>) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard d.count >= 8 + 25, d.prefix(8).elementsEqual(signature) else { return false }
        var offset = 8
        var index = 0
        var sawData = false
        while offset + 12 <= d.count {
            let length = Int(be32(d, offset))
            guard length <= 0x7FFF_FFFF else { return false }
            let end = offset + 12 + length
            guard end <= d.count else { return false }
            guard crc32(d, from: offset + 4, to: end - 4) == be32(d, end - 4) else { return false }
            let type = (d[offset + 4], d[offset + 5], d[offset + 6], d[offset + 7])
            let isIHDR = type == (0x49, 0x48, 0x44, 0x52)
            guard (index == 0) == isIHDR, !isIHDR || length == 13 else { return false }
            if type == (0x49, 0x44, 0x41, 0x54) { sawData = true }
            if type == (0x49, 0x45, 0x4E, 0x44) { return length == 0 && sawData }
            offset = end
            index += 1
        }
        return false
    }

    private static func be32(_ d: UnsafeBufferPointer<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(d[offset]) << 24 | UInt32(d[offset + 1]) << 16 | UInt32(d[offset + 2]) << 8 | UInt32(d[offset + 3])
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }

    private static func crc32(_ d: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> UInt32 {
        crcTable.withUnsafeBufferPointer { table in
            var crc: UInt32 = 0xFFFF_FFFF
            var index = start
            while index < end {
                crc = table[Int((crc ^ UInt32(d[index])) & 0xFF)] ^ (crc >> 8)
                index += 1
            }
            return ~crc
        }
    }

    // MARK: JPEG

    private static func jpegIsComplete(_ d: UnsafeBufferPointer<UInt8>) -> Bool {
        guard d.count >= 4, d[0] == 0xFF, d[1] == 0xD8 else { return false }
        var i = 2
        var sawFrame = false
        var sawScan = false
        while i < d.count {
            guard d[i] == 0xFF else { return false }
            while i < d.count, d[i] == 0xFF { i += 1 }
            guard i < d.count else { return false }
            let marker = d[i]
            i += 1
            switch marker {
            case 0xD9: return sawScan
            case 0x00: return false
            case 0x01, 0xD0...0xD8: continue
            default: break
            }
            guard i + 2 <= d.count else { return false }
            let length = Int(d[i]) << 8 | Int(d[i + 1])
            guard length >= 2, i + length <= d.count else { return false }
            i += length
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC { sawFrame = true }
            if marker == 0xDA {
                guard sawFrame else { return false }
                sawScan = true
                guard let next = nextMarker(d, from: i) else { return false }
                i = next
            }
        }
        return false
    }

    /// The offset of the next real marker's 0xFF after entropy-coded data, skipping stuffed bytes and restarts.
    private static func nextMarker(_ d: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var i = start
        while i + 1 < d.count {
            guard let found = memchr(d.baseAddress! + i, 0xFF, d.count - i - 1) else { return nil }
            let position = d.baseAddress!.distance(to: found.assumingMemoryBound(to: UInt8.self))
            let next = d[position + 1]
            if next == 0x00 || (0xD0...0xD7).contains(next) {
                i = position + 2
            } else if next == 0xFF {
                i = position + 1
            } else {
                return position
            }
        }
        return nil
    }

    // MARK: GIF

    private static func gifIsComplete(_ d: UnsafeBufferPointer<UInt8>) -> Bool {
        guard d.count >= 14, d.prefix(3).elementsEqual("GIF".utf8),
            d[3] == 0x38, d[4] == 0x37 || d[4] == 0x39, d[5] == 0x61
        else { return false }
        var i = 13
        if d[10] & 0x80 != 0 { i += 3 << (Int(d[10] & 7) + 1) }
        var sawImage = false
        while i < d.count {
            let block = d[i]
            i += 1
            switch block {
            case 0x3B:
                return sawImage
            case 0x21:
                guard i < d.count else { return false }
                i += 1
                guard skipSubBlocks(d, &i) else { return false }
            case 0x2C:
                guard i + 9 <= d.count else { return false }
                let flags = d[i + 8]
                i += 9
                if flags & 0x80 != 0 { i += 3 << (Int(flags & 7) + 1) }
                guard i < d.count else { return false }
                i += 1
                guard skipSubBlocks(d, &i) else { return false }
                sawImage = true
            default:
                return false
            }
        }
        return false
    }

    private static func skipSubBlocks(_ d: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> Bool {
        while i < d.count {
            let size = Int(d[i])
            i += 1
            if size == 0 { return true }
            i += size
        }
        return false
    }

    // MARK: WebP

    private static func webpIsComplete(_ d: UnsafeBufferPointer<UInt8>) -> Bool {
        guard d.count >= 12, d.prefix(4).elementsEqual("RIFF".utf8) else { return false }
        let size = Int(d[4]) | Int(d[5]) << 8 | Int(d[6]) << 16 | Int(d[7]) << 24
        return size + 8 <= d.count
    }
}
