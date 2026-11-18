import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ChatNet

extension MemorySensitive {
    @Suite struct ImageStructureTests {
        func pipeline() -> ImagePipeline { ImagePipeline(budget: MemoryBudget(capacity: 128 << 20)) }

        static let forgedPNGEnd = Data([0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])

        func chunkOffsets(_ png: Data) -> [(type: String, start: Int, length: Int)] {
            var result: [(String, Int, Int)] = []
            var offset = 8
            while offset + 12 <= png.count {
                let length = png[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
                result.append((String(decoding: png[(offset + 4)..<(offset + 8)], as: UTF8.self), offset, length))
                offset += 12 + length
            }
            return result
        }

        @Test func pngCutInsideIDATWithForgedIENDChunkIsCorrupt() async throws {
            let png = Fixtures.png(300, 300)
            let idat = try #require(chunkOffsets(png).first { $0.type == "IDAT" })
            let forged = png.prefix(idat.start + 8 + idat.length / 2) + Self.forgedPNGEnd
            await #expect(throws: ImageError.corrupt) {
                _ = try await pipeline().thumbnail(from: forged, maxPixelSize: 100)
            }
        }

        @Test func pngWithJustTheIENDBytesAppendedToATruncationIsCorrupt() async {
            let png = Fixtures.png(300, 300)
            let forged = png.prefix(png.count / 2) + Data("IEND".utf8)
            await #expect(throws: ImageError.corrupt) {
                _ = try await pipeline().thumbnail(from: forged, maxPixelSize: 100)
            }
        }

        @Test func pngWithACorruptedChunkCRCIsCorrupt() async throws {
            var png = Fixtures.png(64, 64)
            let idat = try #require(chunkOffsets(png).first { $0.type == "IDAT" })
            png[idat.start + 8 + 3] ^= 0xFF
            await #expect(throws: ImageError.corrupt) {
                _ = try await pipeline().thumbnail(from: png, maxPixelSize: 32)
            }
        }

        @Test func pngWithoutIDATIsCorrupt() async throws {
            let png = Fixtures.png(64, 64)
            let chunks = chunkOffsets(png)
            let ihdr = try #require(chunks.first { $0.type == "IHDR" })
            let iend = try #require(chunks.first { $0.type == "IEND" })
            let stripped = png[0..<(ihdr.start + 12 + ihdr.length)] + png[iend.start...]
            await #expect(throws: ImageError.corrupt) {
                _ = try await pipeline().thumbnail(from: Data(stripped), maxPixelSize: 32)
            }
        }

        @Test func gifCutInsideImageDataWithForgedTrailerIsCorrupt() async {
            let gif = Fixtures.gif(frames: 1, size: 200)
            let forged = gif.prefix(gif.count * 2 / 3) + Data([0x3B])
            await #expect(throws: ImageError.corrupt) {
                _ = try await pipeline().thumbnail(from: forged, maxPixelSize: 100)
            }
            await #expect(throws: ImageError.corrupt) {
                _ = try await pipeline().animation(from: forged, maxPixelSize: 100)
            }
        }

        @Test func jpegCutInsideAHeaderSegmentWithForgedEOIIsCorrupt() async throws {
            let jpeg = Fixtures.jpeg(300, 300)
            let sos = try #require(jpeg.indices.dropLast().first { jpeg[$0] == 0xFF && jpeg[$0 + 1] == 0xDA })
            let forged = jpeg.prefix(sos - 6) + Data([0xFF, 0xD9])
            await #expect(throws: ImageError.corrupt) {
                _ = try await pipeline().thumbnail(from: forged, maxPixelSize: 100)
            }
        }

        @Test func jpegWithAnEOIInsideAnAPPSegmentButNoRealEndIsCorrupt() async throws {
            let jpeg = Fixtures.jpeg(300, 300)
            let eoi = Data([0xFF, 0xD9])
            let sos = try #require(jpeg.indices.dropLast().first { jpeg[$0] == 0xFF && jpeg[$0 + 1] == 0xDA })
            let payload = Data(repeating: 0, count: 10) + eoi + Data(repeating: 0, count: 80)
            let length = payload.count + 2
            let app = Data([0xFF, 0xE9, UInt8(length >> 8), UInt8(length & 0xFF)]) + payload
            let tampered = jpeg.prefix(sos) + app + jpeg[sos...].prefix(10) + eoi
            await #expect(throws: ImageError.corrupt) {
                _ = try await pipeline().thumbnail(from: tampered, maxPixelSize: 100)
            }
        }

        @Test func validFilesStillDecode() async throws {
            let p = pipeline()
            _ = try await p.thumbnail(from: Fixtures.png(300, 300), maxPixelSize: 100)
            _ = try await p.thumbnail(from: Fixtures.jpeg(300, 300), maxPixelSize: 100)
            _ = try await p.thumbnail(from: Fixtures.gif(frames: 3, size: 64), maxPixelSize: 32)
            _ = try await p.thumbnail(from: Fixtures.png(300, 300) + Data(repeating: 0, count: 100), maxPixelSize: 100)
        }
    }
}
