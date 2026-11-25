import ChatModel
import ChatStore
import CoreGraphics
import FakeChatServer
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatNet
@testable import ChatSync

private let url = URL(string: "https://lh3.googleusercontent.com/a/x=s64-c")!

private func image() async throws -> DecodedImage {
    let context = try #require(
        CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let reservation = try await MemoryBudget(capacity: 16).reserve(4)
    return DecodedImage(image: try #require(context.makeImage()), reservation: reservation)
}

/// A scripted fetch: each call takes the next outcome, optionally after `gate` opens.
private final class Script: Sendable {
    let calls = Atomic<Int>(0)
    let running = Atomic<Int>(0)
    let peak = Atomic<Int>(0)
    let outcomes: Mutex<[Result<Void, MediaLoadError>]>
    let hold: Duration

    init(_ outcomes: [Result<Void, MediaLoadError>], hold: Duration = .zero) {
        self.outcomes = Mutex(outcomes)
        self.hold = hold
    }

    var fetch: AvatarLoads.Fetch {
        { () async throws(MediaLoadError) -> DecodedImage in
            self.calls.add(1, ordering: .acquiringAndReleasing)
            let now = self.running.add(1, ordering: .acquiringAndReleasing).newValue
            self.peak.max(now, ordering: .acquiringAndReleasing)
            defer { self.running.subtract(1, ordering: .acquiringAndReleasing) }
            if self.hold > .zero { try? await Task.sleep(for: self.hold) }
            let next = self.outcomes.withLock { $0.isEmpty ? .success(()) : $0.removeFirst() }
            if case .failure(let error) = next { throw error }
            guard let made = try? await image() else { throw .image(.corrupt) }
            return made
        }
    }
}

private let noWait: @Sendable (Duration) async throws -> Void = { _ in }

struct AvatarLoadsTests {
    @Test func callersShareOneDownload() async {
        let loads = AvatarLoads(sleep: noWait)
        let script = Script([], hold: .milliseconds(50))
        let fetch = script.fetch
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 { group.addTask { await loads.load(url, fetch: fetch) != nil } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(results == 10)
        #expect(script.calls.load(ordering: .acquiring) == 1)
    }

    @Test func aCancelledCallerLeavesPromptlyAndTheOthersStillGetThePhoto() async {
        let loads = AvatarLoads(sleep: noWait)
        let script = Script([], hold: .seconds(1))
        let fetch = script.fetch
        let leaving = Task { await loads.load(url, fetch: fetch) }
        let staying = Task { await loads.load(url, fetch: fetch) }
        #expect(await pollAsync { await loads.waiterCount(url) == 2 })
        #expect(await poll { script.running.load(ordering: .acquiring) == 1 })
        leaving.cancel()
        #expect(await leaving.value == nil)
        #expect(script.running.load(ordering: .acquiring) == 1, "the cancelled caller waited for the download")
        #expect(await staying.value != nil)
        #expect(script.calls.load(ordering: .acquiring) == 1)
    }

    @Test func nothingIsFetchedWhenEveryCallerLeavesWhileQueued() async {
        let loads = AvatarLoads(concurrent: 1, sleep: noWait)
        let blocker = Script([], hold: .milliseconds(200))
        let other = URL(string: "https://lh3.googleusercontent.com/a/other=s64-c")!
        let busy = Task { await loads.load(other, fetch: blocker.fetch) }
        try? await Task.sleep(for: .milliseconds(30))
        let queued = Script([])
        let waiter = Task { await loads.load(url, fetch: queued.fetch) }
        try? await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        #expect(await waiter.value == nil)
        _ = await busy.value
        try? await Task.sleep(for: .milliseconds(50))
        #expect(queued.calls.load(ordering: .acquiring) == 0)
    }

    @Test func aBriefFailureIsRetried() async {
        let loads = AvatarLoads(sleep: noWait)
        let script = Script([.failure(.transport(.offline)), .failure(.transport(.other(code: 503)))])
        #expect(await loads.load(url, fetch: script.fetch) != nil)
        #expect(script.calls.load(ordering: .acquiring) == 3)
    }

    @Test func aMissingPhotoIsFetchedOnceForTheRun() async {
        let loads = AvatarLoads(sleep: noWait)
        let script = Script([.failure(.transport(.other(code: 404)))])
        #expect(await loads.load(url, fetch: script.fetch) == nil)
        #expect(await loads.load(url, fetch: script.fetch) == nil)
        #expect(script.calls.load(ordering: .acquiring) == 1)
    }

    @Test func exhaustedBriefFailuresAreTriedAgainNextTime() async {
        let loads = AvatarLoads(sleep: noWait)
        let offline = Result<Void, MediaLoadError>.failure(.transport(.timedOut))
        let script = Script([offline, offline, offline])
        #expect(await loads.load(url, fetch: script.fetch) == nil)
        #expect(script.calls.load(ordering: .acquiring) == 3)
        #expect(await loads.load(url, fetch: script.fetch) != nil)
    }

    @Test func atMostFourDownloadsRunAtOnceAndNoSlotIsHeldDuringBackoff() async {
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let loads = AvatarLoads(
            concurrent: 4,
            sleep: { _ in await withCheckedContinuation { continuation in gate.withLock { $0 = continuation } } })
        let backingOff = Script([.failure(.transport(.offline))])
        let first = Task { await loads.load(url, fetch: backingOff.fetch) }
        try? await Task.sleep(for: .milliseconds(30))
        let script = Script([], hold: .milliseconds(40))
        let fetch = script.fetch
        let others = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<12 {
                let other = URL(string: "https://lh3.googleusercontent.com/a/\(index)=s64-c")!
                group.addTask { await loads.load(other, fetch: fetch) != nil }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(others == 12)
        #expect(script.peak.load(ordering: .acquiring) == 4)
        gate.withLock { $0?.resume() }
        #expect(await first.value != nil)
    }

    @Test(arguments: [
        (MediaLoadError.transport(.offline), AvatarLoads.Outcome.retry),
        (.transport(.timedOut), .retry),
        (.transport(.connectionLost), .retry),
        (.transport(.other(code: 408)), .retry),
        (.transport(.other(code: 429)), .retry),
        (.transport(.other(code: 500)), .retry),
        (.transport(.other(code: 404)), .permanent),
        (.transport(.other(code: 403)), .permanent),
        (.transport(.hostNotAllowed), .permanent),
        (.transport(.redirected(status: 302, location: nil)), .permanent),
        (.transport(.responseTooLarge), .permanent),
        (.transport(.tls), .stop),
        (.transport(.cancelled), .stop),
        (.image(.budget), .retry),
        (.image(.corrupt), .permanent),
        (.image(.unsupported), .permanent),
        (.image(.cancelled), .stop),
        (.retired, .stop),
    ])
    func outcomes(_ error: MediaLoadError, _ expected: AvatarLoads.Outcome) {
        #expect(AvatarLoads.outcome(error) == expected)
    }
}

/// Serves the same small PNG for every request.
final class PhotoHost: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = FakeMedia.png()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png", "Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct AvatarDownloadTests {
    func loader(budget: Int) throws -> (MediaLoader, URL) {
        let h = Harness()
        let client = GoogleChatClient(transport: h.server.makeTransport(), tokens: StaticTokens(token: h.alice.token))
        let root = FileManager.default.temporaryDirectory.appending(path: "gchat-avatar-\(UUID().uuidString)")
        let account = AccountID()
        let directory = AccountDirectory(root: root, account: account)
        let key = StoreKey.random(for: account)
        _ = try SQLiteAccountStore.open(directory: directory, key: key)
        let loader = MediaLoader(
            media: client, cache: try MediaCache(directory: directory, key: key),
            exports: ExportDirectory(directory: directory),
            pipeline: ImagePipeline(budget: MemoryBudget(capacity: budget)),
            fetcher: SafeFetcher(allowedHosts: SafeFetcher.profilePhotoHosts, protocolClasses: [PhotoHost.self]),
            gate: h.gate)
        return (loader, root)
    }

    @Test func aProfilePhotoDownloadsAndDecodes() async throws {
        let (loader, root) = try loader(budget: 32 << 20)
        defer { try? FileManager.default.removeItem(at: root) }
        let decoded = try await loader.avatar(at: url, maxPixelSize: 64)
        #expect(decoded.image.width <= 64 && decoded.image.width > 0)
    }

    @Test func aBudgetTooSmallForAPhotoIsTooLarge() async throws {
        let (loader, root) = try loader(budget: 1024)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: MediaLoadError.image(.tooLarge)) {
            _ = try await loader.avatar(at: url, maxPixelSize: 64)
        }
    }
}
