import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import ChatNet

extension Fixtures {
    static func oriented(_ image: CGImage, orientation: Int, as type: UTType) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var options: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if type == .jpeg { options[kCGImageDestinationLossyCompressionQuality] = 0.8 }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func floatTIFF(_ width: Int, _ height: Int) -> Data {
        let pixels = [Float](repeating: 0.5, count: width * height * 4)
        let provider = CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
            space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return encode(image, as: .tiff)
    }
}

@Suite struct OrientationTests {
    func pipeline() -> ImagePipeline { ImagePipeline(budget: MemoryBudget(capacity: 128 << 20)) }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8], [UTType.png, UTType.jpeg])
    func everyOrientationDecodesWithinItsPlan(orientation: Int, type: UTType) async throws {
        let pipeline = pipeline()
        let data = Fixtures.oriented(Fixtures.image(width: 600, height: 400), orientation: orientation, as: type)
        let (_, header) = try pipeline.inspect(data, allFrames: false)
        #expect(header.frames[0].orientation == orientation)
        let plan = pipeline.plan(for: header.frames[0], type: header.type, maxPixelSize: 512)
        let decoded = try await pipeline.thumbnail(from: data, maxPixelSize: 512)
        let actual = decoded.image.bytesPerRow * decoded.image.height
        #expect(plan.output >= actual)
        #expect(decoded.reservation.bytes == actual)
        if orientation >= 5 {
            #expect(decoded.image.height == 512)
            #expect(decoded.image.width < decoded.image.height)
        } else {
            #expect(decoded.image.width == 512)
        }
    }

    @Test func rotatedAnimationFramesFitTheirSlots() async throws {
        let data = Fixtures.tiff(pages: [(300, 200), (300, 200)])
        let animation = try await pipeline().animation(from: data, maxPixelSize: 256)
        _ = try await animation.frame(at: 1)
    }
}

@Suite struct DeepPixelTests {
    func pipeline() -> ImagePipeline { ImagePipeline(budget: MemoryBudget(capacity: 128 << 20)) }

    @Test func floatSamplesAreUnsupportedBeforeAnyDecode() async {
        let data = Fixtures.floatTIFF(64, 64)
        await #expect(throws: ImageError.unsupported) {
            _ = try await pipeline().thumbnail(from: data, maxPixelSize: 32)
        }
        await #expect(throws: ImageError.unsupported) {
            _ = try await pipeline().animation(from: data, maxPixelSize: 32)
        }
    }

    @Test func sixteenBitNonPNGGetsALargerWorkspaceThanEightBit() {
        let pipeline = pipeline()
        for type in ["public.tiff", "public.heic", "com.microsoft.bmp"] {
            let eight = pipeline.plan(for: .init(width: 2000, height: 2000, depth: 8), type: type, maxPixelSize: 1024)
            let sixteen = pipeline.plan(
                for: .init(width: 2000, height: 2000, depth: 16), type: type, maxPixelSize: 1024)
            #expect(sixteen.workspace >= eight.workspace * 3 / 2, "\(type)")
        }
    }

    @Test func aSixteenBitTIFFStaysWithinItsReservation() async throws {
        let data = Fixtures.encode(Fixtures.image16(width: 1200, height: 900), as: .tiff)
        let pipeline = pipeline()
        let (_, header) = try pipeline.inspect(data, allFrames: false)
        #expect(header.frames[0].depth == 16)
        _ = try await pipeline.thumbnail(from: data, maxPixelSize: 512)
    }
}

@Suite struct TimedReserveTests {
    @Test(.timeLimit(.minutes(2))) func theExpiryLaunchesOnlyAfterTheWaiterIsQueued() async throws {
        let budget = MemoryBudget(capacity: 100)
        let held = try await budget.reserve(100)
        defer { held.release() }
        let queuedAtLaunch = Mutex<Bool?>(nil)
        let expiry = Gate()
        let waiter = Recorded { () -> MemoryBudgetError? in
            do {
                _ = try await budget.reserve(
                    50, timeout: .seconds(3600), expiry: { try await expiry.wait() },
                    onExpiryLaunch: { queued in queuedAtLaunch.withLock { $0 = queued } })
                return nil
            } catch let error as MemoryBudgetError {
                return error
            } catch {
                return .invalidSize
            }
        }
        defer { waiter.cancel() }
        try #require(await eventually { queuedAtLaunch.withLock { $0 } != nil && expiry.waiting == 1 })
        #expect(queuedAtLaunch.withLock { $0 } == true)
        #expect(budget.waiterCount == 1)
        expiry.open()
        #expect(await waiter.settled() == .some(.timedOut))
        #expect(budget.waiterCount == 0)
        held.release()
        #expect(await budget.available == 100)
    }

    @Test func zeroTimeoutAlwaysCompletesUnderContention() async throws {
        let budget = MemoryBudget(capacity: 100)
        let held = try await budget.reserve(100)
        for _ in 0..<200 {
            let attempt = Recorded(catching: { try await budget.reserve(10, timeout: .zero) })
            let refused = try #require(await attempt.settled(), "a wait with no time left never ended")
            #expect(throws: MemoryBudgetError.timedOut) { _ = try refused.get() }
        }
        held.release()
        #expect(await budget.available == 100)
    }

    @Test func aTimeoutDoesNotDisturbTheQueueBehindIt() async throws {
        let budget = MemoryBudget(capacity: 100)
        let held = try await budget.reserve(90)
        let expiry = Gate()
        let head = Recorded(catching: {
            try await budget.reserve(50, timeout: .seconds(3600), expiry: { try await expiry.wait() })
        })
        defer { head.cancel() }
        try #require(await eventually { budget.waiterCount == 1 })
        let behind = Recorded(catching: { try await budget.reserve(5) })
        defer { behind.cancel() }
        try #require(await eventually { budget.waiterCount == 2 })
        expiry.open()
        let refused = try #require(await head.settled())
        #expect(throws: MemoryBudgetError.timedOut) { _ = try refused.get() }
        try #require(await eventually { budget.waiterCount == 0 })
        let granted = try #require(await behind.settled()).get()
        #expect(granted.bytes == 5)
        #expect(held.bytes == 90)
        #expect(await budget.available == 5)
    }
}

@Suite(.serialized) struct IdentityWindowTests {
    let directory: URL

    init() throws { directory = try makeTempDirectory() }

    func makeStream(_ url: URL, suffix: String = "", afterRead: (@Sendable () -> Void)? = nil) throws
        -> CompositeInputStream
    {
        let opened = try OpenedFile.open(url)
        return CompositeInputStream(
            prefix: Data(), file: opened, identity: opened.identity, suffix: Data(suffix.utf8), afterRead: afterRead)
    }

    @Test func aRewriteThatRestoresTheModificationTimeIsStillCaught() throws {
        let url = directory.appending(path: "r.bin")
        try Data(repeating: 1, count: 1000).write(to: url)
        var before = stat()
        #expect(stat(url.path(percentEncoded: false), &before) == 0)
        let stream = try makeStream(url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(repeating: 2, count: 1000))
        try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        #expect(utimensat(AT_FDCWD, url.path(percentEncoded: false), &times, 0) == 0)
        var after = stat()
        #expect(stat(url.path(percentEncoded: false), &after) == 0)
        #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 2000)
        #expect(stream.read(&buffer, maxLength: 2000) == -1)
    }

    @Test func aMutationBetweenTheReadAndItsReturnIsCaught() throws {
        let url = directory.appending(path: "w.bin")
        try Data(repeating: 1, count: 1000).write(to: url)
        let stream = try makeStream(url) {
            let handle = try? FileHandle(forWritingTo: url)
            try? handle?.write(contentsOf: Data(repeating: 2, count: 1000))
            try? handle?.close()
        }
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 2000)
        #expect(stream.read(&buffer, maxLength: 2000) == -1)
        #expect(stream.streamStatus == .error)
    }

    @Test func aMutationAfterTheFileButBeforeTheSuffixIsCaught() throws {
        let url = directory.appending(path: "s.bin")
        try Data(repeating: 1, count: 100).write(to: url)
        let stream = try makeStream(url, suffix: "--end")
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 200)
        #expect(stream.read(&buffer, maxLength: 200) == 100)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(repeating: 2, count: 100))
        try handle.close()
        #expect(stream.read(&buffer, maxLength: 200) == -1)
    }

    @Test func aFileChangedWhileTheServerAnswersFailsTheSend() async throws {
        let url = directory.appending(path: "t.bin")
        try Data(repeating: 1, count: 4000).write(to: url)
        HookedBodyProtocol.beforeResponse.withLock {
            $0["/up/late-change"] = {
                let handle = try? FileHandle(forWritingTo: url)
                try? handle?.write(contentsOf: Data(repeating: 2, count: 4000))
                try? handle?.close()
            }
        }
        defer { HookedBodyProtocol.beforeResponse.withLock { $0["/up/late-change"] = nil } }
        let transport = AuthTransport(allowedHosts: ["chat.googleapis.com"], protocolClasses: [HookedBodyProtocol.self])
        await #expect(throws: TransportError.requestBodyUnavailable) {
            try await transport.send(
                HTTPRequest(
                    method: .post, url: URL(string: "https://chat.googleapis.com/up/late-change")!,
                    bodyFile: FileBody(file: url)))
        }
    }
}

@Suite(.serialized) struct AdmittedFetchTests {
    let hosts: Set<String> = ["media.example.com"]

    func fetcher() -> SafeFetcher {
        SafeFetcher(allowedHosts: hosts, protocolClasses: [AdmitStubProtocol.self], resolver: nil)
    }

    func route(_ path: String, _ canned: StubProtocol.Canned) {
        AdmitStubProtocol.routes.withLock { $0[path] = canned }
    }

    func url(_ path: String) -> URL { URL(string: "https://media.example.com\(path)")! }

    @Test func downloadsIntoTheAdmissionAndShrinksItToTheBytesReceived() async throws {
        route("/af/small", .init(status: 200, headers: ["Content-Type": "image/gif"], body: Data(count: 5000)))
        let budget = MemoryBudget(capacity: 64 << 20)
        let pipeline = ImagePipeline(budget: budget)
        let admission = try await pipeline.reserveEncoded(byteCount: 1 << 20)
        #expect(await budget.available == (64 << 20) - (1 << 20))
        let (data, type) = try await fetcher().fetch(url("/af/small"), maxBytes: 1 << 20, admission: admission)
        #expect(data.count == 5000)
        #expect(type == "image/gif")
        #expect(admission.byteCount == 5000)
        #expect(await budget.available == (64 << 20) - 5000)
    }

    @Test func theAdmissionBoundsTheDownloadEvenWhenMaxBytesIsLarger() async throws {
        route("/af/big", .init(status: 200, body: Data(count: 4000)))
        let budget = MemoryBudget(capacity: 64 << 20)
        let pipeline = ImagePipeline(budget: budget)
        let admission = try await pipeline.reserveEncoded(byteCount: 1000)
        var caught: TransportError?
        do {
            _ = try await fetcher().fetch(url("/af/big"), maxBytes: 20 << 20, admission: admission)
        } catch {
            caught = error
        }
        #expect(caught == .responseTooLarge)
        #expect(admission.byteCount == 1000)
    }

    @Test func maxBytesBelowTheAdmissionStillApplies() async throws {
        route("/af/cap", .init(status: 200, body: Data(count: 4000)))
        let pipeline = ImagePipeline(budget: MemoryBudget(capacity: 64 << 20))
        let admission = try await pipeline.reserveEncoded(byteCount: 1 << 20)
        var caught: TransportError?
        do {
            _ = try await fetcher().fetch(url("/af/cap"), maxBytes: 100, admission: admission)
        } catch {
            caught = error
        }
        #expect(caught == .responseTooLarge)
    }

    @Test func aFailedDownloadLeavesNothingReservedOnceTheAdmissionIsDropped() async throws {
        route("/af/missing", .init(status: 404))
        let budget = MemoryBudget(capacity: 64 << 20)
        let pipeline = ImagePipeline(budget: budget)
        do {
            let admission = try await pipeline.reserveEncoded(byteCount: 1 << 20)
            var caught: TransportError?
            do {
                _ = try await fetcher().fetch(url("/af/missing"), admission: admission)
            } catch {
                caught = error
            }
            #expect(caught == .other(code: 404))
        }
        #expect(await budget.available == 64 << 20)
    }

    @Test func aFetchedGIFFlowsStraightIntoAnAnimationWithoutReReserving() async throws {
        let gif = Fixtures.gif(frames: 4, size: 48)
        route("/af/anim", .init(status: 200, headers: ["Content-Type": "image/gif"], body: gif))
        let budget = MemoryBudget(capacity: 64 << 20)
        let pipeline = ImagePipeline(budget: budget)
        let admission = try await pipeline.reserveEncoded(byteCount: 2 << 20)
        let (data, _) = try await fetcher().fetch(url("/af/anim"), maxBytes: 2 << 20, admission: admission)
        #expect(admission.byteCount == gif.count)
        let animation = try await pipeline.animation(from: data, admission: admission, maxPixelSize: 48)
        #expect(animation.frameCount == 4)
        #expect((64 << 20) - (await budget.available) >= gif.count)
        _ = try await animation.frame(at: 2)
    }

    @Test func aRedirectedDownloadAlsoLandsInTheAdmission() async throws {
        route("/af/hop", .init(status: 302, headers: ["Location": "https://media.example.com/af/final"]))
        route("/af/final", .init(status: 200, body: Data(count: 777)))
        let pipeline = ImagePipeline(budget: MemoryBudget(capacity: 64 << 20))
        let admission = try await pipeline.reserveEncoded(byteCount: 1 << 20)
        let (data, _) = try await fetcher().fetch(url("/af/hop"), admission: admission)
        #expect(data.count == 777)
        #expect(admission.byteCount == 777)
    }
}
