import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import ChatNet

enum Fixtures {
    static func image(width: Int, height: Int, seed: UInt32 = 1) -> CGImage {
        var state = seed
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
            pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 16)
            pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 8)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func png(_ width: Int, _ height: Int) -> Data { encode(image(width: width, height: height), as: .png) }
    static func jpeg(_ width: Int, _ height: Int) -> Data {
        encode(image(width: width, height: height), as: .jpeg, quality: 0.8)
    }

    static func gif(frames: Int, size: Int = 32) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil)!
        let file = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, file)
        for frame in 0..<frames {
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary
            CGImageDestinationAddImage(
                destination, image(width: size, height: size, seed: UInt32(frame + 1)), properties)
        }
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Signature and IHDR only, so the declared size costs nothing to store.
    static func headerOnlyPNG(width: UInt32, height: UInt32) -> Data {
        func be(_ value: UInt32) -> [UInt8] {
            (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * UInt32($0))) }
        }
        var ihdr = Array("IHDR".utf8) + be(width) + be(height) + [8, 6, 0, 0, 0]
        let crc = crc32(ihdr)
        ihdr += be(crc)
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + be(13) + ihdr)
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

extension MemorySensitive {
    @Suite struct ImagePipelineTests {
        func pipeline(
            capacity: Int = 256 << 20, limits: ImageLimits = ImageLimits()
        ) -> (ImagePipeline, MemoryBudget) {
            let budget = MemoryBudget(capacity: capacity)
            return (ImagePipeline(budget: budget, limits: limits), budget)
        }

        @Test func downscalesPNGKeepingAspectAndHoldsOnlyTheOutput() async throws {
            let (pipeline, budget) = pipeline(capacity: 64 << 20)
            let decoded = try await pipeline.thumbnail(from: Fixtures.png(800, 400), maxPixelSize: 200)
            #expect(decoded.image.width == 200)
            #expect(decoded.image.height == 100)
            #expect(decoded.reservation.bytes == decoded.image.bytesPerRow * decoded.image.height)
            #expect(await budget.available == (64 << 20) - decoded.reservation.bytes)
            decoded.reservation.release()
            #expect(await budget.available == 64 << 20)
        }

        @Test func decodesJPEG() async throws {
            let (pipeline, _) = pipeline()
            let decoded = try await pipeline.thumbnail(from: Fixtures.jpeg(640, 480), maxPixelSize: 160)
            #expect(max(decoded.image.width, decoded.image.height) == 160)
        }

        @Test func neverUpscalesAndCapsAtTheDisplayLimit() async throws {
            let (pipeline, _) = pipeline(limits: ImageLimits(maxDisplayPixelSize: 100))
            let small = try await pipeline.thumbnail(from: Fixtures.png(50, 40), maxPixelSize: 500)
            #expect(small.image.width == 50)
            let big = try await pipeline.thumbnail(from: Fixtures.png(300, 300), maxPixelSize: 500)
            #expect(big.image.width == 100)
        }

        @Test func rejectsHeaderOnly20000SquarePNGWithoutAllocating() async throws {
            let (pipeline, budget) = pipeline()
            let data = Fixtures.headerOnlyPNG(width: 20_000, height: 20_000)
            let before = physFootprint()
            await #expect(throws: ImageError.tooLarge) {
                _ = try await pipeline.thumbnail(from: data, maxPixelSize: 512)
            }
            #expect(physFootprint() - before < 16 << 20)
            #expect(await budget.available == 256 << 20)
        }

        @Test func rejectsOverPixelAndOverByteLimits() async {
            let (pipeline, _) = pipeline(limits: ImageLimits(maxPixels: 5000, maxBytes: 1 << 20))
            await #expect(throws: ImageError.tooLarge) {
                _ = try await pipeline.thumbnail(from: Fixtures.png(100, 100), maxPixelSize: 50)
            }
            let (tiny, _) = self.pipeline(limits: ImageLimits(maxBytes: 100))
            await #expect(throws: ImageError.tooLarge) {
                _ = try await tiny.thumbnail(from: Fixtures.png(64, 64), maxPixelSize: 50)
            }
        }

        @Test func truncatedDataIsCorrupt() async {
            let (pipeline, budget) = pipeline()
            let png = Fixtures.png(300, 300)
            await #expect(throws: ImageError.corrupt) {
                _ = try await pipeline.thumbnail(from: png.prefix(png.count / 2), maxPixelSize: 100)
            }
            let jpeg = Fixtures.jpeg(300, 300)
            await #expect(throws: ImageError.corrupt) {
                _ = try await pipeline.thumbnail(from: jpeg.prefix(jpeg.count / 2), maxPixelSize: 100)
            }
            #expect(await budget.available == 256 << 20)
        }

        @Test func garbageAndEmptyAreRejected() async {
            let (pipeline, _) = pipeline()
            await #expect(throws: ImageError.unsupported) {
                _ = try await pipeline.thumbnail(from: Data("not an image at all".utf8), maxPixelSize: 100)
            }
            await #expect(throws: ImageError.corrupt) {
                _ = try await pipeline.thumbnail(from: Data(), maxPixelSize: 100)
            }
        }

        @Test func aPeakLargerThanTheWholeBudgetIsTooLarge() async {
            let (pipeline, _) = pipeline(capacity: 10_000)
            await #expect(throws: ImageError.tooLarge) {
                _ = try await pipeline.thumbnail(from: Fixtures.png(400, 400), maxPixelSize: 400)
            }
        }

        @Test func cancellationWhileWaitingForBudget() async throws {
            let (pipeline, budget) = pipeline(capacity: 2_000_000)
            let hold = try await budget.reserve(2_000_000)
            let data = Fixtures.png(200, 200)
            let task = Task { () -> ImageError? in
                do throws(ImageError) {
                    _ = try await pipeline.thumbnail(from: data, maxPixelSize: 200)
                    return nil
                } catch {
                    return error
                }
            }
            try await Task.sleep(for: .milliseconds(50))
            task.cancel()
            #expect(await task.value == .cancelled)
            hold.release()
            #expect(await budget.available == 2_000_000)
        }

        @Test func animatedGIFDecodesLazilyAndKeepsTwoFramesCached() async throws {
            let (pipeline, budget) = pipeline(capacity: 64 << 20)
            let animation = try await pipeline.animation(from: Fixtures.gif(frames: 12, size: 64), maxPixelSize: 32)
            #expect(animation.frameCount == 12)
            #expect(animation.cachedFrameCount == 0)
            let held = (64 << 20) - (await budget.available)
            #expect(held > 0)
            for index in 0..<12 {
                let frame = try await animation.frame(at: index)
                #expect(frame.image.width == 32)
                #expect(animation.cachedFrameCount <= 2)
            }
            #expect(animation.cachedFrameCount == 2)
            #expect(await budget.available == (64 << 20) - held)
            #expect(abs(animation.delay(at: 0) - 0.05) < 0.001)
            await #expect(throws: ImageError.corrupt) { _ = try await animation.frame(at: 12) }
        }

        @Test func animationReleasesItsReservationWhenDropped() async throws {
            let (pipeline, budget) = pipeline(capacity: 64 << 20)
            do {
                let animation = try await pipeline.animation(from: Fixtures.gif(frames: 3), maxPixelSize: 32)
                _ = try await animation.frame(at: 0)
            }
            #expect(await budget.available == 64 << 20)
        }

        @Test func rejectsMoreThanTheFrameLimit() async {
            let (pipeline, _) = pipeline()
            let data = Fixtures.gif(frames: 151, size: 4)
            await #expect(throws: ImageError.tooManyFrames) {
                _ = try await pipeline.animation(from: data, maxPixelSize: 4)
            }
            await #expect(throws: ImageError.tooManyFrames) {
                _ = try await pipeline.thumbnail(from: data, maxPixelSize: 4)
            }
            let exactly150 = Fixtures.gif(frames: 150, size: 4)
            let animation = try? await pipeline.animation(from: exactly150, maxPixelSize: 4)
            #expect(animation?.frameCount == 150)
        }

        @Test func hundredConcurrentThumbnailsNeverExceedTheBudget() async throws {
            let data = (0..<4).map { Fixtures.png(600 + $0 * 40, 450) }
            let probe = Fixtures.png(640, 450)
            let capacity = 8 << 20
            let (pipeline, budget) = pipeline(capacity: capacity)
            let jpeg = Fixtures.jpeg(1200, 900)
            let violations = Atomic<Int>(0)
            let sampling = Atomic<Bool>(true)
            let before = physFootprint()
            let peak = Mutex(0)
            let sampler = Task {
                while sampling.load(ordering: .acquiring) {
                    let available = await budget.available
                    if available < 0 || available > capacity { violations.add(1, ordering: .relaxed) }
                    peak.withLock { $0 = max($0, physFootprint()) }
                    await Task.yield()
                }
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<100 {
                    group.addTask {
                        let input = index % 5 == 4 ? jpeg : data[index % 4]
                        let decoded = try await pipeline.thumbnail(from: input, maxPixelSize: 256)
                        let used = capacity - (await budget.available)
                        if used < decoded.reservation.bytes || used > capacity {
                            violations.add(1, ordering: .relaxed)
                        }
                    }
                }
                try await group.waitForAll()
            }
            sampling.store(false, ordering: .releasing)
            await sampler.value
            _ = probe
            print("image stress: footprint growth \((peak.withLock { $0 } - before) / 1024) KiB")
            #expect(violations.load(ordering: .relaxed) == 0)
            #expect(await budget.available == capacity)
        }
    }
}
