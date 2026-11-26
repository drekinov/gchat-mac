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

/// A scripted fetch: each call takes the next outcome, once `open()` has been called if the script is held.
private final class Script: Sendable {
    private struct Hold {
        var open: Bool
        var parked: [CheckedContinuation<Void, Never>] = []
    }

    let calls = Atomic<Int>(0)
    let running = Atomic<Int>(0)
    let peak = Atomic<Int>(0)
    let outcomes: Mutex<[Result<Void, MediaLoadError>]>
    private let hold: Mutex<Hold>

    init(_ outcomes: [Result<Void, MediaLoadError>], held: Bool = false) {
        self.outcomes = Mutex(outcomes)
        hold = Mutex(Hold(open: !held))
    }

    /// Lets every parked and later fetch through.
    func open() {
        let parked = hold.withLock { hold in
            hold.open = true
            defer { hold.parked = [] }
            return hold.parked
        }
        for continuation in parked { continuation.resume() }
    }

    var fetch: AvatarLoads.Fetch {
        { () async throws(MediaLoadError) -> DecodedImage in
            self.calls.add(1, ordering: .acquiringAndReleasing)
            let now = self.running.add(1, ordering: .acquiringAndReleasing).newValue
            self.peak.max(now, ordering: .acquiringAndReleasing)
            defer { self.running.subtract(1, ordering: .acquiringAndReleasing) }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let go = self.hold.withLock { hold in
                    if !hold.open { hold.parked.append(continuation) }
                    return hold.open
                }
                if go { continuation.resume() }
            }
            let next = self.outcomes.withLock { $0.isEmpty ? .success(()) : $0.removeFirst() }
            if case .failure(let error) = next { throw error }
            guard let made = try? await image() else { throw .image(.corrupt) }
            return made
        }
    }
}

private let noWait: @Sendable (Duration) async throws -> Void = { _ in }

extension AvatarLoads {
    /// Downloads waiting for one of the slots.
    fileprivate var queuedForSlot: Int { slots.waiterCount }
}

/// Loads `url` in its own task; true if a photo came back.
private func loading(_ url: URL, from loads: AvatarLoads, _ script: Script) -> Running<Bool> {
    let fetch = script.fetch
    return Running { await loads.load(url, fetch: fetch) != nil }
}

struct AvatarLoadsTests {
    @Test func callersShareOneDownload() async throws {
        let loads = AvatarLoads(sleep: noWait)
        let script = Script([], held: true)
        defer { script.open() }
        let callers = (0..<10).map { _ in loading(url, from: loads, script) }
        defer { for caller in callers { caller.cancel() } }
        try #require(
            await eventually {
                await loads.waiterCount(url) == 10 && script.running.load(ordering: .acquiring) == 1
            })
        script.open()
        var results = 0
        for caller in callers where await caller.settled() == true { results += 1 }
        #expect(results == 10)
        #expect(script.calls.load(ordering: .acquiring) == 1)
    }

    @Test func aCancelledCallerLeavesPromptlyAndTheOthersStillGetThePhoto() async throws {
        let loads = AvatarLoads(sleep: noWait)
        let script = Script([], held: true)
        defer { script.open() }
        let leaving = loading(url, from: loads, script)
        let staying = loading(url, from: loads, script)
        defer { staying.cancel() }
        try #require(
            await eventually {
                await loads.waiterCount(url) == 2 && script.running.load(ordering: .acquiring) == 1
            })
        leaving.cancel()
        #expect(await leaving.settled() == false, "the cancelled caller waited for the download")
        #expect(await loads.waiterCount(url) == 1)
        script.open()
        #expect(await staying.settled() == true)
        #expect(script.calls.load(ordering: .acquiring) == 1)
    }

    @Test func nothingIsFetchedWhenEveryCallerLeavesWhileQueued() async throws {
        let loads = AvatarLoads(concurrent: 1, sleep: noWait)
        let blocker = Script([], held: true)
        defer { blocker.open() }
        let other = URL(string: "https://lh3.googleusercontent.com/a/other=s64-c")!
        let busy = loading(other, from: loads, blocker)
        defer { busy.cancel() }
        try #require(await eventually { blocker.running.load(ordering: .acquiring) == 1 })
        let queued = Script([])
        let waiter = loading(url, from: loads, queued)
        try #require(await eventually { await loads.queuedForSlot == 1 })
        #expect(await loads.waiterCount(url) == 1)
        waiter.cancel()
        #expect(await waiter.settled() == false, "the cancelled caller waited for the slot")
        #expect(await eventually { await loads.queuedForSlot == 0 })
        blocker.open()
        #expect(await busy.settled() == true)
        // Slots are granted in order, so the probe runs only after the queued download had its turn.
        let probe = Script([])
        let third = URL(string: "https://lh3.googleusercontent.com/a/probe=s64-c")!
        #expect(await loading(third, from: loads, probe).settled() == true)
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

    /// With the first download parked in its backoff, four of twelve others hold the four slots and eight queue.
    @Test func atMostFourDownloadsRunAtOnceAndNoSlotIsHeldDuringBackoff() async throws {
        let backoff = Pauses()
        defer { backoff.fire(0) }
        let loads = AvatarLoads(concurrent: 4, sleep: backoff.sleep)
        let backingOff = Script([.failure(.transport(.offline))])
        let first = loading(url, from: loads, backingOff)
        defer { first.cancel() }
        try #require(await eventually { backoff.asked.count == 1 })
        #expect(backoff.asked == [.seconds(2)])
        let script = Script([], held: true)
        defer { script.open() }
        let others = (0..<12).map { index in
            loading(URL(string: "https://lh3.googleusercontent.com/a/\(index)=s64-c")!, from: loads, script)
        }
        defer { for other in others { other.cancel() } }
        try #require(
            await eventually {
                await loads.queuedForSlot == 8 && script.running.load(ordering: .acquiring) == 4
            })
        script.open()
        var loaded = 0
        for other in others where await other.settled() == true { loaded += 1 }
        #expect(loaded == 12)
        #expect(script.peak.load(ordering: .acquiring) == 4)
        backoff.fire(0)
        #expect(await first.settled() == true)
        #expect(backingOff.calls.load(ordering: .acquiring) == 2)
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
