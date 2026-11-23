import Foundation
import Synchronization
import Testing

@testable import ChatNet

final class HangingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

@Suite(.serialized) struct SafeFetcherTests {
    static let hosts: Set<String> = ["media.example.com", "cdn.example.com"]

    func route(_ path: String, _ canned: StubProtocol.Canned) {
        FetchStubProtocol.routes.withLock { $0[path] = canned }
    }

    func fetcher(
        hosts: Set<String> = SafeFetcherTests.hosts, resolver: SafeFetcher.Resolver? = nil
    ) -> SafeFetcher {
        SafeFetcher(allowedHosts: hosts, protocolClasses: [FetchStubProtocol.self], resolver: resolver)
    }

    func url(_ text: String) -> URL { URL(string: text)! }

    func requestCount(host: String) -> Int {
        FetchStubProtocol.seen.withLock { $0.filter { $0.url?.host == host }.count }
    }

    @Test func fetchesBytesAndContentType() async throws {
        route("/sf/ok", .init(status: 200, headers: ["Content-Type": "image/gif"], body: Data("GIF89a".utf8)))
        let (data, type) = try await fetcher().fetch(url("https://media.example.com/sf/ok"))
        #expect(data == Data("GIF89a".utf8))
        #expect(type == "image/gif")
    }

    @Test func sendsNoCredentialsOrCookies() async throws {
        route("/sf/headers", .init(status: 200, headers: ["Set-Cookie": "a=b"], body: Data("x".utf8)))
        _ = try await fetcher().fetch(url("https://media.example.com/sf/headers"))
        _ = try await fetcher().fetch(url("https://media.example.com/sf/headers"))
        let requests = FetchStubProtocol.seen.withLock { $0.filter { $0.url?.path == "/sf/headers" } }
        #expect(requests.count >= 2)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.httpMethod == "GET")
        }
    }

    @Test(arguments: [
        "http://media.example.com/sf/x",
        "https://user@media.example.com/sf/x",
        "https://user:pw@media.example.com/sf/x",
        "https://media.example.com:8443/sf/x",
        "https://evil.example.com/sf/x",
        "https://media.example.com.evil.example/sf/x",
        "https://127.0.0.1/sf/x",
        "https://2130706433/sf/x",
        "https://127.1/sf/x",
        "https://0x7f.0.0.1/sf/x",
        "https://[::1]/sf/x",
        "https://[::ffff:127.0.0.1]/sf/x",
        "https://localhost/sf/x",
        "https://foo.localhost/sf/x",
        "https://printer.local/sf/x",
        "https://intranet/sf/x",
    ])
    func rejectsBeforeAnyRequest(target: String) async {
        let allowEverything: Set<String> = Self.hosts.union([
            "127.0.0.1", "2130706433", "127.1", "0x7f.0.0.1", "::1", "::ffff:127.0.0.1", "localhost", "foo.localhost",
            "printer.local", "intranet",
        ])
        let before = FetchStubProtocol.seen.withLock { $0.count }
        await #expect(throws: TransportError.self) {
            try await fetcher(hosts: allowEverything).fetch(url(target))
        }
        #expect(FetchStubProtocol.seen.withLock { $0.count } == before)
    }

    @Test func schemeFailureIsDistinct() async {
        await #expect(throws: TransportError.insecureScheme) {
            try await fetcher().fetch(url("http://media.example.com/sf/x"))
        }
    }

    @Test func followsAllowedRedirectsWithoutCredentials() async throws {
        route("/sf/r1", .init(status: 302, headers: ["Location": "https://cdn.example.com/sf/r2"]))
        route("/sf/r2", .init(status: 301, headers: ["Location": "/sf/r3"]))
        route("/sf/r3", .init(status: 200, headers: ["Content-Type": "image/png"], body: Data("png".utf8)))
        let (data, type) = try await fetcher().fetch(url("https://media.example.com/sf/r1"))
        #expect(data == Data("png".utf8))
        #expect(type == "image/png")
        let sent = FetchStubProtocol.seen.withLock { $0.filter { $0.url?.path.hasPrefix("/sf/r") == true } }
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test(arguments: [
        "https://evil.example.com/sf/final", "http://media.example.com/sf/final", "https://127.0.0.1/sf/final",
        "https://user:x@media.example.com/sf/final",
    ])
    func rejectsRedirectTargetsThatFailValidation(target: String) async {
        route("/sf/bad", .init(status: 302, headers: ["Location": target]))
        route("/sf/final", .init(status: 200, body: Data("leak".utf8)))
        let before = FetchStubProtocol.seen.withLock { $0.filter { $0.url?.path == "/sf/final" }.count }
        await #expect(throws: TransportError.self) {
            try await fetcher().fetch(url("https://media.example.com/sf/bad"))
        }
        #expect(FetchStubProtocol.seen.withLock { $0.filter { $0.url?.path == "/sf/final" }.count } == before)
    }

    @Test func allowsThreeRedirectsAndNotFour() async throws {
        route("/sf/c0", .init(status: 302, headers: ["Location": "/sf/c1"]))
        route("/sf/c1", .init(status: 302, headers: ["Location": "/sf/c2"]))
        route("/sf/c2", .init(status: 302, headers: ["Location": "/sf/c3"]))
        route("/sf/c3", .init(status: 302, headers: ["Location": "/sf/c4"]))
        route("/sf/c4", .init(status: 200, body: Data("end".utf8)))
        let (data, _) = try await fetcher().fetch(url("https://media.example.com/sf/c1"))
        #expect(data == Data("end".utf8))
        await #expect(throws: TransportError.redirected(status: 302, location: nil)) {
            try await fetcher().fetch(url("https://media.example.com/sf/c0"))
        }
    }

    @Test func capsBytes() async {
        route("/sf/big", .init(status: 200, body: Data(count: 1000)))
        await #expect(throws: TransportError.responseTooLarge) {
            try await fetcher().fetch(url("https://media.example.com/sf/big"), maxBytes: 100)
        }
    }

    @Test func nonSuccessStatusIsAnError() async {
        route("/sf/gone", .init(status: 404))
        await #expect(throws: TransportError.other(code: 404)) {
            try await fetcher().fetch(url("https://media.example.com/sf/gone"))
        }
    }

    @Test func emptyAllowlistRejectsEverything() async {
        await #expect(throws: TransportError.hostNotAllowed) {
            try await fetcher(hosts: []).fetch(url("https://media.example.com/sf/ok"))
        }
        #expect(
            SafeFetcher.productionHosts == [
                "lh3.googleusercontent.com", "lh4.googleusercontent.com", "lh5.googleusercontent.com",
                "lh6.googleusercontent.com",
            ])
    }

    @Test func rejectsHostsResolvingToPrivateRanges() async {
        route("/sf/dns", .init(status: 200, body: Data("x".utf8)))
        let before = requestCount(host: "media.example.com")
        let private10 = fetcher(resolver: { _ in [[93, 184, 216, 34], [10, 0, 0, 5]] })
        await #expect(throws: TransportError.hostNotAllowed) {
            try await private10.fetch(url("https://media.example.com/sf/dns"))
        }
        #expect(requestCount(host: "media.example.com") == before)
    }

    @Test func acceptsHostsResolvingToPublicAddresses() async throws {
        route("/sf/dns-ok", .init(status: 200, body: Data("x".utf8)))
        let public4 = fetcher(resolver: { _ in [[93, 184, 216, 34]] })
        let (data, _) = try await public4.fetch(url("https://media.example.com/sf/dns-ok"))
        #expect(data == Data("x".utf8))
    }

    @Test func aBurstOfFetchesWaitsForLookupSlotsInsteadOfFailing() async throws {
        route("/sf/burst", .init(status: 200, body: Data("x".utf8)))
        let slow: SafeFetcher.Resolver = { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return [[93, 184, 216, 34]]
        }
        let fetcher = fetcher(resolver: slow)
        let target = url("https://media.example.com/sf/burst")
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { (try? await fetcher.fetch(target)) != nil } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(successes == 20)
    }

    @Test func lookupsBeyondTheSlotsWaitAndNeverRunMoreAtOnce() async {
        let slots = MemoryBudget(capacity: 3)
        let running = Atomic<Int>(0)
        let peak = Atomic<Int>(0)
        let resolver: SafeFetcher.Resolver = { _ in
            let now = running.add(1, ordering: .acquiringAndReleasing).newValue
            peak.max(now, ordering: .acquiringAndReleasing)
            Thread.sleep(forTimeInterval: 0.03)
            running.subtract(1, ordering: .acquiringAndReleasing)
            return [[93, 184, 216, 34]]
        }
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    if case .addresses = await SafeFetcher.resolve(
                        "media.example.com", using: resolver, timeout: .seconds(5), slots: slots)
                    {
                        return true
                    }
                    return false
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(outcomes == 12)
        #expect(peak.load(ordering: .acquiring) <= 3)
    }

    @Test func stuckLookupsHoldTheirSlotsAndLaterOnesTimeOut() async {
        let slots = MemoryBudget(capacity: 1)
        let calls = Atomic<Int>(0)
        let stall: SafeFetcher.Resolver = { _ in
            calls.add(1, ordering: .acquiringAndReleasing)
            Thread.sleep(forTimeInterval: 1)
            return [[93, 184, 216, 34]]
        }
        let first = await SafeFetcher.resolve("a.example.com", using: stall, timeout: .milliseconds(50), slots: slots)
        let clock = ContinuousClock()
        let start = clock.now
        let second = await SafeFetcher.resolve("a.example.com", using: stall, timeout: .milliseconds(100), slots: slots)
        guard case .timedOut = first, case .timedOut = second else {
            Issue.record("expected both to time out")
            return
        }
        #expect(clock.now - start < .milliseconds(800))
        #expect(calls.load(ordering: .acquiring) == 1)
    }

    @Test func aCancelledWaiterNeverStartsItsLookup() async {
        let slots = MemoryBudget(capacity: 1)
        let held = try? await slots.reserve(1)
        let calls = Atomic<Int>(0)
        let resolver: SafeFetcher.Resolver = { _ in
            calls.add(1, ordering: .acquiringAndReleasing)
            return [[93, 184, 216, 34]]
        }
        let waiter = Task {
            await SafeFetcher.resolve("a.example.com", using: resolver, timeout: .seconds(5), slots: slots)
        }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        held?.release()
        guard case .cancelled = await waiter.value else {
            Issue.record("expected cancelled")
            return
        }
        #expect(calls.load(ordering: .acquiring) == 0)
    }

    @Test func resolutionFailureIsOffline() async {
        struct Failure: Error {}
        let broken = fetcher(resolver: { _ in throw Failure() })
        await #expect(throws: TransportError.offline) {
            try await broken.fetch(url("https://media.example.com/sf/dns-ok"))
        }
    }

    @Test func revalidatesResolutionOnEveryRedirectHop() async {
        route("/sf/hop", .init(status: 302, headers: ["Location": "https://cdn.example.com/sf/hop-final"]))
        route("/sf/hop-final", .init(status: 200, body: Data("secret".utf8)))
        let resolver: SafeFetcher.Resolver = { host in
            host == "cdn.example.com" ? [[192, 168, 1, 1]] : [[93, 184, 216, 34]]
        }
        await #expect(throws: TransportError.hostNotAllowed) {
            try await fetcher(resolver: resolver).fetch(url("https://media.example.com/sf/hop"))
        }
        #expect(FetchStubProtocol.seen.withLock { $0.filter { $0.url?.path == "/sf/hop-final" }.isEmpty })
    }

    @Test func deadlineCancelsASilentServer() async {
        let slow = SafeFetcher(
            allowedHosts: Self.hosts, protocolClasses: [HangingProtocol.self], resolver: nil,
            deadline: .milliseconds(200))
        await #expect(throws: TransportError.timedOut) {
            try await slow.fetch(url("https://media.example.com/sf/hang"))
        }
    }

    @Test func callerCancellationStopsTheFetch() async {
        let slow = SafeFetcher(
            allowedHosts: Self.hosts, protocolClasses: [HangingProtocol.self], resolver: nil, deadline: .seconds(30))
        let task = Task { () -> TransportError? in
            do throws(TransportError) {
                _ = try await slow.fetch(url("https://media.example.com/sf/hang"))
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(await task.value == .cancelled)
    }

    @Test func aStalledResolverIsAbandonedAtTheDeadline() async {
        let stall: SafeFetcher.Resolver = { _ in
            Thread.sleep(forTimeInterval: 3)
            return [[93, 184, 216, 34]]
        }
        let slow = SafeFetcher(
            allowedHosts: Self.hosts, protocolClasses: [FetchStubProtocol.self], resolver: stall,
            deadline: .milliseconds(200))
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: TransportError.timedOut) {
            try await slow.fetch(url("https://media.example.com/sf/dns-stall"))
        }
        #expect(clock.now - start < .seconds(1.5))
    }

    @Test func cancellingDuringResolutionReturnsPromptly() async {
        let stall: SafeFetcher.Resolver = { _ in
            Thread.sleep(forTimeInterval: 3)
            return [[93, 184, 216, 34]]
        }
        let slow = SafeFetcher(
            allowedHosts: Self.hosts, protocolClasses: [FetchStubProtocol.self], resolver: stall, deadline: .seconds(30)
        )
        let target = url("https://media.example.com/sf/dns-stall")
        let task = Task { () -> TransportError? in
            do throws(TransportError) {
                _ = try await slow.fetch(target)
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(clock.now - start < .seconds(1.5))
    }

    @Test func aCancelledFetchNeverConnects() async {
        FetchStubProtocol.routes.withLock { $0["/sf/never"] = .init(status: 200, body: Data("x".utf8)) }
        let resolver: SafeFetcher.Resolver = { _ in [[93, 184, 216, 34]] }
        let target = url("https://media.example.com/sf/never")
        let task = Task { () -> TransportError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(TransportError) {
                _ = try await fetcher(resolver: resolver).fetch(target)
                return nil
            } catch {
                return error
            }
        }
        #expect(await task.value == .cancelled)
        #expect(FetchStubProtocol.seen.withLock { $0.filter { $0.url?.path == "/sf/never" }.isEmpty })
    }

    @Test(
        arguments: [
            ([10, 1, 2, 3], false), ([127, 0, 0, 1], false), ([0, 0, 0, 0], false), ([100, 64, 0, 1], false),
            ([169, 254, 169, 254], false), ([172, 16, 0, 1], false), ([172, 31, 255, 255], false),
            ([172, 32, 0, 1], true), ([192, 168, 0, 1], false), ([198, 18, 0, 1], false), ([224, 0, 0, 1], false),
            ([255, 255, 255, 255], false), ([8, 8, 8, 8], true), ([93, 184, 216, 34], true), ([100, 63, 0, 1], true),
        ] as [([UInt8], Bool)])
    func classifiesIPv4(address: [UInt8], isPublic: Bool) {
        #expect(SafeFetcher.isPublicAddress(address) == isPublic)
    }

    @Test func classifiesIPv6() {
        func v6(_ text: String) -> [UInt8] {
            var address = in6_addr()
            precondition(inet_pton(AF_INET6, text, &address) == 1)
            return withUnsafeBytes(of: address) { Array($0) }
        }
        #expect(!SafeFetcher.isPublicAddress(v6("::1")))
        #expect(!SafeFetcher.isPublicAddress(v6("::")))
        #expect(!SafeFetcher.isPublicAddress(v6("fe80::1")))
        #expect(!SafeFetcher.isPublicAddress(v6("fc00::1")))
        #expect(!SafeFetcher.isPublicAddress(v6("fd12:3456::1")))
        #expect(!SafeFetcher.isPublicAddress(v6("ff02::1")))
        #expect(!SafeFetcher.isPublicAddress(v6("2001:db8::1")))
        #expect(!SafeFetcher.isPublicAddress(v6("::ffff:10.0.0.1")))
        #expect(!SafeFetcher.isPublicAddress(v6("64:ff9b::7f00:1")))
        #expect(!SafeFetcher.isPublicAddress(v6("2002:c0a8:0101::1")))
        #expect(SafeFetcher.isPublicAddress(v6("::ffff:8.8.8.8")))
        #expect(SafeFetcher.isPublicAddress(v6("2606:4700:4700::1111")))
        #expect(SafeFetcher.isPublicAddress(v6("64:ff9b::808:808")))
        #expect(!SafeFetcher.isPublicAddress([1, 2, 3]))
    }

    @Test func systemResolverFailsClosedForGarbage() throws {
        #expect(throws: (any Error).self) { _ = try SafeFetcher.systemResolver("nonexistent.invalid") }
        let loopback = try SafeFetcher.systemResolver("localhost")
        #expect(!loopback.isEmpty)
        #expect(loopback.allSatisfy { !SafeFetcher.isPublicAddress($0) })
    }
}
