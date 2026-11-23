import CoreGraphics
import Foundation
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
        let script = Script([], hold: .milliseconds(200))
        let fetch = script.fetch
        let leaving = Task { await loads.load(url, fetch: fetch) }
        let staying = Task { await loads.load(url, fetch: fetch) }
        try? await Task.sleep(for: .milliseconds(30))
        let clock = ContinuousClock()
        let start = clock.now
        leaving.cancel()
        #expect(await leaving.value == nil)
        #expect(clock.now - start < .milliseconds(150))
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
