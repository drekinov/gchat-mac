import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import ChatNet

extension Fixtures {
    static func image16(width: Int, height: Int) -> CGImage {
        var pixels = [UInt16](repeating: 0xFFFF, count: width * height * 4)
        var state: UInt32 = 5
        for index in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt16(truncatingIfNeeded: state >> 16)
            pixels[index + 1] = UInt16(truncatingIfNeeded: state >> 8)
            pixels[index + 2] = UInt16(truncatingIfNeeded: state)
        }
        let provider = CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func png16(_ width: Int, _ height: Int) -> Data {
        encode(image16(width: width, height: height), as: .png)
    }

    static func tiff(pages: [(Int, Int)]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, pages.count, nil)!
        for (width, height) in pages {
            CGImageDestinationAddImage(destination, image(width: width, height: height), nil)
        }
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@Suite struct ImageAccountingTests {
    func pipeline(
        capacity: Int = 256 << 20, limits: ImageLimits = ImageLimits(), heldWait: Duration = .seconds(5)
    ) -> (ImagePipeline, MemoryBudget) {
        let budget = MemoryBudget(capacity: capacity)
        return (ImagePipeline(budget: budget, limits: limits, heldWaitTimeout: heldWait), budget)
    }

    // MARK: M1: bit depth and row alignment

    @Test func sixteenBitPNGIsRetainedAtItsRealSize() async throws {
        let (pipeline, budget) = pipeline(capacity: 64 << 20)
        let decoded = try await pipeline.thumbnail(from: Fixtures.png16(400, 300), maxPixelSize: 200)
        let image = decoded.image
        #expect(image.bitsPerComponent == 16)
        #expect(image.bytesPerRow * image.height == decoded.reservation.bytes)
        #expect(decoded.reservation.bytes >= 200 * 150 * 8)
        #expect(await budget.available == (64 << 20) - decoded.reservation.bytes)
    }

    @Test(arguments: [
        (1001, 333, 16), (1001, 333, 8), (77, 1999, 16), (77, 1999, 8), (1, 1, 8), (3, 2, 16), (2048, 7, 8),
        (333, 333, 16),
    ])
    func plannedOutputCoversTheDecodedImage(width: Int, height: Int, bits: Int) async throws {
        let (pipeline, _) = pipeline()
        let data = bits == 16 ? Fixtures.png16(width, height) : Fixtures.png(width, height)
        let (_, header) = try pipeline.inspect(data, allFrames: false)
        #expect(header.frames[0].depth == bits)
        let plan = pipeline.plan(for: header.frames[0], type: header.type, maxPixelSize: 512)
        let decoded = try await pipeline.thumbnail(from: data, maxPixelSize: 512)
        let actual = decoded.image.bytesPerRow * decoded.image.height
        #expect(plan.output >= actual)
        #expect(decoded.reservation.bytes == actual)
    }

    /// (type, depth, width, height, peak growth minus output in KiB), measured decoding to 1024 px in a fresh process.
    static let measured: [(String, Int, Int, Int, Int)] = [
        ("public.jpeg", 8, 600, 600, 3234), ("public.jpeg", 8, 1024, 1024, 11008),
        ("public.jpeg", 8, 1500, 1500, 20720),
        ("public.jpeg", 8, 2048, 1536, 6640), ("public.jpeg", 8, 2500, 1800, 13756),
        ("public.jpeg", 8, 4000, 3000, 27472), ("public.jpeg", 8, 4000, 4000, 34240),
        ("public.png", 8, 600, 600, 3298), ("public.png", 8, 1024, 1024, 8720), ("public.png", 8, 1500, 1500, 13704),
        ("public.png", 8, 2048, 1536, 16304), ("public.png", 8, 2500, 1800, 12524),
        ("public.png", 8, 4000, 3000, 21680), ("public.png", 8, 4000, 4000, 27000),
        ("public.png", 16, 600, 600, 6148), ("public.png", 16, 1024, 1024, 16976),
        ("public.png", 16, 1500, 1500, 26656),
        ("public.png", 16, 2048, 1536, 31680), ("public.png", 16, 2500, 1800, 23448),
        ("public.png", 16, 4000, 3000, 42756), ("public.png", 16, 4000, 4000, 52600),
        ("com.compuserve.gif", 8, 600, 600, 3202), ("com.compuserve.gif", 8, 1024, 1024, 8656),
        ("com.compuserve.gif", 8, 1500, 1500, 13600), ("com.compuserve.gif", 8, 2048, 1536, 16144),
        ("com.compuserve.gif", 8, 2500, 1800, 22524), ("com.compuserve.gif", 8, 4000, 3000, 59232),
        ("com.compuserve.gif", 8, 4000, 4000, 78754),
        ("public.heic", 8, 600, 600, 3298), ("public.heic", 8, 1024, 1024, 4144), ("public.heic", 8, 1500, 1500, 9600),
        ("public.heic", 8, 2048, 1536, 4592), ("public.heic", 8, 2500, 1800, 8248),
        ("public.heic", 8, 4000, 3000, 8228), ("public.heic", 8, 4000, 4000, 9704),
        ("public.tiff", 8, 600, 600, 3394), ("public.tiff", 8, 1024, 1024, 8832), ("public.tiff", 8, 2048, 1536, 16432),
        ("public.tiff", 8, 2500, 1800, 8380), ("public.tiff", 8, 4000, 3000, 15904),
        ("public.tiff", 16, 1000, 1000, 8284), ("public.tiff", 16, 2000, 2000, 40368),
        ("public.tiff", 16, 4000, 3000, 31536),
        ("public.heic", 10, 1000, 1000, 83774), ("public.heic", 10, 2000, 2000, 118496),
        ("public.heic", 10, 4000, 3000, 159424),
        ("com.microsoft.bmp", 8, 600, 600, 4690), ("com.microsoft.bmp", 8, 1024, 1024, 12752),
        ("com.microsoft.bmp", 8, 2048, 1536, 28496), ("com.microsoft.bmp", 8, 2500, 1800, 38972),
        ("com.microsoft.bmp", 8, 4000, 3000, 97792),
    ]

    @Test func workspaceEstimateCoversEveryMeasuredPeak() {
        let (pipeline, _) = pipeline()
        for (type, depth, width, height, kib) in Self.measured {
            let plan = pipeline.plan(
                for: ImagePipeline.FrameInfo(width: width, height: height, depth: depth), type: type,
                maxPixelSize: 1024)
            #expect(
                plan.workspace >= kib * 1024,
                "\(type) \(depth)-bit \(width)x\(height): \(plan.workspace / 1024) KiB < \(kib) KiB")
        }
    }

    @Test func aSixteenBitPNGReservesMoreThanTheSameEightBitOne() {
        let (pipeline, _) = pipeline()
        let eight = pipeline.plan(
            for: .init(width: 2000, height: 2000, depth: 8), type: "public.png", maxPixelSize: 1024)
        let sixteen = pipeline.plan(
            for: .init(width: 2000, height: 2000, depth: 16), type: "public.png", maxPixelSize: 1024)
        #expect(sixteen.output == eight.output * 2)
        #expect(sixteen.workspace > eight.workspace)
    }

    @Test func rowsAreAlignedTo64Bytes() {
        let (pipeline, _) = pipeline()
        let plan = pipeline.plan(for: .init(width: 1000, height: 1000, depth: 8), type: "public.png", maxPixelSize: 333)
        #expect(plan.output == ((333 * 4 + 63) / 64 * 64) * 333)
    }

    // MARK: M2: encoded bytes are admitted before allocation

    @Test func encodedBytesOverTheLimitAreRefusedWithoutTouchingTheBudget() async {
        let (pipeline, budget) = pipeline(capacity: 64 << 20, limits: ImageLimits(maxBytes: 1 << 20))
        await #expect(throws: ImageError.tooLarge) { _ = try await pipeline.reserveEncoded(byteCount: (1 << 20) + 1) }
        await #expect(throws: ImageError.corrupt) { _ = try await pipeline.reserveEncoded(byteCount: 0) }
        await #expect(throws: ImageError.corrupt) { _ = try await pipeline.reserveEncoded(byteCount: -5) }
        #expect(await budget.available == 64 << 20)
    }

    @Test func admissionReservesBeforeAnyBytesExistAndWaitsInTurn() async throws {
        let (pipeline, budget) = pipeline(capacity: 4 << 20)
        let first = try await pipeline.reserveEncoded(byteCount: 3 << 20)
        #expect(await budget.available == 1 << 20)
        let second = Task { try await pipeline.reserveEncoded(byteCount: 2 << 20) }
        try await Task.sleep(for: .milliseconds(50))
        second.cancel()
        await #expect(throws: ImageError.self) { _ = try await second.value }
        #expect(await budget.available == 1 << 20)
        _ = first
    }

    @Test func anAdmissionLargerThanTheBudgetFailsImmediately() async {
        let (pipeline, _) = pipeline(capacity: 1 << 20)
        await #expect(throws: ImageError.budget) { _ = try await pipeline.reserveEncoded(byteCount: 2 << 20) }
    }

    @Test func decodingWithAnAdmissionReleasesItAfterwards() async throws {
        let (pipeline, budget) = pipeline(capacity: 64 << 20)
        let data = Fixtures.png(400, 300)
        let admission = try await pipeline.reserveEncoded(byteCount: data.count)
        #expect(await budget.available == (64 << 20) - data.count)
        let decoded = try await pipeline.thumbnail(from: data, admission: admission, maxPixelSize: 100)
        #expect(await budget.available == (64 << 20) - decoded.reservation.bytes)
        #expect(decoded.reservation.bytes == decoded.image.bytesPerRow * decoded.image.height)
    }

    @Test func dataLargerThanItsAdmissionIsRefused() async throws {
        let (pipeline, budget) = pipeline(capacity: 64 << 20)
        let data = Fixtures.png(100, 100)
        let admission = try await pipeline.reserveEncoded(byteCount: data.count - 1)
        var caught: ImageError?
        do {
            _ = try await pipeline.thumbnail(from: data, admission: admission, maxPixelSize: 50)
        } catch {
            caught = error
        }
        #expect(caught == .tooLarge)
        #expect(await budget.available == 64 << 20)
    }

    @Test func aFailedDecodeStillReleasesTheAdmission() async throws {
        let (pipeline, budget) = pipeline(capacity: 64 << 20)
        let data = Fixtures.png(300, 300)
        let cut = data.prefix(data.count / 2)
        let admission = try await pipeline.reserveEncoded(byteCount: cut.count)
        var caught: ImageError?
        do {
            _ = try await pipeline.thumbnail(from: Data(cut), admission: admission, maxPixelSize: 50)
        } catch {
            caught = error
        }
        #expect(caught == .corrupt)
        #expect(await budget.available == 64 << 20)
    }

    @Test func holdingAnAdmissionNeverWaitsForeverForTheDecodeMemory() async throws {
        let data = Fixtures.png(300, 300)
        let (pipeline, budget) = pipeline(capacity: data.count + 600_000, heldWait: .milliseconds(200))
        let admission = try await pipeline.reserveEncoded(byteCount: data.count)
        let blocker = try await budget.reserve(await budget.available)
        let clock = ContinuousClock()
        let start = clock.now
        var caught: ImageError?
        do {
            _ = try await pipeline.thumbnail(from: data, admission: admission, maxPixelSize: 100)
        } catch {
            caught = error
        }
        #expect(caught == .budget)
        #expect(clock.now - start < .seconds(2))
        blocker.release()
        #expect(await budget.available == data.count + 600_000)
    }

    @Test func animationKeepsItsAdmissionForItsLifetime() async throws {
        let (pipeline, budget) = pipeline(capacity: 64 << 20)
        let data = Fixtures.gif(frames: 4, size: 64)
        let admission = try await pipeline.reserveEncoded(byteCount: data.count)
        do {
            let animation = try await pipeline.animation(from: data, admission: admission, maxPixelSize: 32)
            #expect(await budget.available <= (64 << 20) - data.count)
            _ = try await animation.frame(at: 0)
        }
        #expect(await budget.available == 64 << 20)
    }

    // MARK: M3: frames carry their reservations

    @Test func aFrameHeldAfterEvictionStaysAccounted() async throws {
        let (pipeline, budget) = pipeline(capacity: 64 << 20)
        let animation = try await pipeline.animation(from: Fixtures.gif(frames: 8, size: 64), maxPixelSize: 32)
        let atStart = await budget.available
        let kept = try await animation.frame(at: 0)
        for index in 1..<6 { _ = try await animation.frame(at: index) }
        #expect(animation.cachedFrameCount == 2)
        #expect(kept.image.width == 32)
        #expect(kept.reservation.bytes >= kept.image.bytesPerRow * kept.image.height)
        #expect(await budget.available == atStart)
    }

    @Test func framesFromTheCacheAreTheSameOwners() async throws {
        let (pipeline, _) = pipeline(capacity: 64 << 20)
        let animation = try await pipeline.animation(from: Fixtures.gif(frames: 3, size: 32), maxPixelSize: 32)
        let first = try await animation.frame(at: 1)
        let again = try await animation.frame(at: 1)
        #expect(first === again)
    }

    @Test func releasedFramesGiveTheirSlotBack() async throws {
        let (pipeline, _) = pipeline(capacity: 64 << 20)
        let animation = try await pipeline.animation(from: Fixtures.gif(frames: 8, size: 32), maxPixelSize: 32)
        var held: [DecodedFrame] = []
        for index in 0..<3 { held.append(try await animation.frame(at: index)) }
        await #expect(throws: ImageError.budget) { _ = try await animation.frame(at: 5) }
        held.removeFirst()
        _ = try await animation.frame(at: 5)
        held.removeAll()
        for index in 6..<8 { _ = try await animation.frame(at: index) }
    }

    @Test func framesOutliveTheirAnimationWithoutLeakingTheBudget() async throws {
        let (pipeline, budget) = pipeline(capacity: 64 << 20)
        var frame: DecodedFrame?
        do {
            let animation = try await pipeline.animation(from: Fixtures.gif(frames: 3, size: 32), maxPixelSize: 32)
            frame = try await animation.frame(at: 1)
        }
        #expect(await budget.available < 64 << 20)
        #expect(frame?.image.width == 32)
        frame = nil
        #expect(await budget.available == 64 << 20)
    }

    // MARK: M4: no waiting on memory while holding some

    @Test func animationFramesNeverWaitOnTheBudget() async throws {
        let (pipeline, budget) = pipeline(capacity: 64 << 20)
        let animation = try await pipeline.animation(from: Fixtures.gif(frames: 6, size: 32), maxPixelSize: 32)
        let squatter = try await budget.reserve(await budget.available)
        let clock = ContinuousClock()
        let start = clock.now
        for index in 0..<6 { _ = try await animation.frame(at: index) }
        #expect(clock.now - start < .seconds(2))
        squatter.release()
    }

    @Test func anAnimationWhoseCombinedPeakExceedsTheBudgetFailsImmediately() async {
        let (pipeline, budget) = pipeline(capacity: 100_000)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: ImageError.budget) {
            _ = try await pipeline.animation(from: Fixtures.gif(frames: 4, size: 64), maxPixelSize: 64)
        }
        #expect(clock.now - start < .seconds(1))
        #expect(await budget.available == 100_000)
    }

    @Test func anAdmittedAnimationWhosePeakCannotFitFailsImmediately() async throws {
        let data = Fixtures.gif(frames: 4, size: 64)
        let (pipeline, budget) = pipeline(capacity: data.count + 1000)
        let admission = try await pipeline.reserveEncoded(byteCount: data.count)
        let clock = ContinuousClock()
        let start = clock.now
        var caught: ImageError?
        do {
            _ = try await pipeline.animation(from: data, admission: admission, maxPixelSize: 64)
        } catch {
            caught = error
        }
        #expect(caught == .budget)
        #expect(clock.now - start < .seconds(1))
        #expect(await budget.available == data.count + 1000)
    }

    @Test func manyAnimationsOnATightBudgetEitherRunOrFailButNeverDeadlock() async throws {
        let data = Fixtures.gif(frames: 4, size: 48)
        let (probe, probeBudget) = pipeline(capacity: 64 << 20)
        let sample = try await probe.animation(from: data, maxPixelSize: 48)
        let one = (64 << 20) - (await probeBudget.available)
        withExtendedLifetime(sample) {}
        let (pipeline, budget) = pipeline(capacity: one * 2 + 1000)
        let finished = Mutex(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let animation = try await pipeline.animation(from: data, maxPixelSize: 48)
                    for index in 0..<4 { _ = try await animation.frame(at: index) }
                    try await Task.sleep(for: .milliseconds(10))
                    finished.withLock { $0 += 1 }
                }
            }
            try await group.waitForAll()
        }
        #expect(finished.withLock { $0 } == 12)
        #expect(await budget.available == one * 2 + 1000)
    }

    // MARK: M5: every frame is validated and sized

    @Test func aLaterFrameOverThePixelLimitIsRejected() async {
        let (pipeline, _) = pipeline(limits: ImageLimits(maxPixels: 100_000))
        let data = Fixtures.tiff(pages: [(100, 100), (700, 700)])
        await #expect(throws: ImageError.tooLarge) { _ = try await pipeline.animation(from: data, maxPixelSize: 64) }
    }

    @Test func slotsAreSizedForTheLargestFrame() async throws {
        let (pipeline, _) = pipeline()
        let data = Fixtures.tiff(pages: [(40, 40), (200, 100), (60, 30)])
        let animation = try await pipeline.animation(from: data, maxPixelSize: 200)
        #expect(animation.frameCount == 3)
        let big = try await animation.frame(at: 1)
        #expect(big.image.width == 200)
        #expect(big.reservation.bytes >= big.image.bytesPerRow * big.image.height)
        let small = try await animation.frame(at: 0)
        #expect(small.image.width == 40)
    }

    @Test func aThumbnailOnlyNeedsTheFirstFrameWithinLimits() async throws {
        let (pipeline, _) = pipeline(limits: ImageLimits(maxPixels: 100_000))
        let data = Fixtures.tiff(pages: [(100, 100), (700, 700)])
        let decoded = try await pipeline.thumbnail(from: data, maxPixelSize: 50)
        #expect(decoded.image.width == 50)
    }
}
