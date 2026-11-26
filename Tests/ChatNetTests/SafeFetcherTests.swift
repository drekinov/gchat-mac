import Foundation
import Synchronization
import Testing

@testable import ChatNet

final class HangingProtocol: URLProtocol, @unchecked Sendable {
    /// The request timeout each started path carried.
    static let started = Mutex<[String: TimeInterval]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.started.withLock { $0[path] = request.timeoutInterval }
    }
    override func stopLoading() {}
}

/// Opens once; any number of tasks can wait before or after. A waiter whose task is cancelled throws.
final class Gate: Sendable {
    private struct State {
        var open = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())

    var waiting: Int { state.withLock { $0.waiters.count } }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result: Result<Void, any Error>? = state.withLock { state in
                    if state.open { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
}

/// Blocks resolver threads until opened, and counts the ones that have arrived.
final class ThreadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var arrivals = 0

    var arrived: Int {
        condition.lock()
        defer { condition.unlock() }
        return arrivals
    }

    func pass() {
        condition.lock()
        defer { condition.unlock() }
        arrivals += 1
        while !isOpen { condition.wait() }
    }

    func open() {
        condition.lock()
        defer { condition.unlock() }
        isOpen = true
        condition.broadcast()
    }
}

extension SafeFetcher.Resolution {
    var isTimedOut: Bool { if case .timedOut = self { true } else { false } }
    var isCancelled: Bool { if case .cancelled = self { true } else { false } }
    var isAddresses: Bool { if case .addresses = self { true } else { false } }
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

    /// A fetcher whose deadlines end only when their gates open, with lookups in their own slots. Its session's
    /// own request timeout is out of reach, so a `.timedOut` can only come from a gate.
    func gated(
        protocolClass: AnyClass = FetchStubProtocol.self, resolver: SafeFetcher.Resolver?, slots: MemoryBudget,
        fetch: Gate = Gate(), slot: Gate = Gate(), lookup: Gate = Gate()
    ) -> SafeFetcher {
        SafeFetcher(
            allowedHosts: Self.hosts, protocolClasses: [protocolClass], resolver: resolver, deadline: .seconds(3600),
            requestTimeout: 3600, slots: slots,
            expiries: .init(
                fetch: { try await fetch.wait() }, slot: { try await slot.wait() }, lookup: { try await lookup.wait() })
        )
    }

    func outcome(of fetcher: SafeFetcher, _ target: URL) -> Recorded<TransportError?> {
        Recorded {
            do throws(TransportError) {
                _ = try await fetcher.fetch(target)
                return nil
            } catch {
                return error
            }
        }
    }

    /// A resolver that waits at `gate`.
    func held(by gate: ThreadGate, calls: Counter? = nil) -> SafeFetcher.Resolver {
        { _ in
            calls?.bump()
            gate.pass()
            return [[93, 184, 216, 34]]
        }
    }

    func requestCount(path: String) -> Int {
        FetchStubProtocol.seen.withLock { $0.filter { $0.url?.path == path }.count }
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
            #expect(request.timeoutInterval == 20)
        }
    }

    struct Rejection: Sendable, CustomTestStringConvertible {
        let target: String
        let error: TransportError
        /// False for hosts that fail only because they are missing from the allowlist.
        var allowHost = true

        var marker: String { URL(string: target)!.path() }
        var testDescription: String { target }
    }

    @Test(arguments: [
        Rejection(target: "http://media.example.com/sf/rej/scheme", error: .insecureScheme),
        Rejection(target: "https://user@media.example.com/sf/rej/user", error: .hostNotAllowed),
        Rejection(target: "https://user:pw@media.example.com/sf/rej/password", error: .hostNotAllowed),
        Rejection(target: "https://media.example.com:8443/sf/rej/port", error: .hostNotAllowed),
        Rejection(target: "https://evil.example.com/sf/rej/foreign", error: .hostNotAllowed, allowHost: false),
        Rejection(
            target: "https://media.example.com.evil.example/sf/rej/suffix", error: .hostNotAllowed, allowHost: false),
        Rejection(target: "https://127.0.0.1/sf/rej/v4", error: .hostNotAllowed),
        Rejection(target: "https://2130706433/sf/rej/v4-integer", error: .hostNotAllowed),
        Rejection(target: "https://127.1/sf/rej/v4-short", error: .hostNotAllowed),
        Rejection(target: "https://0x7f.0.0.1/sf/rej/v4-hex", error: .hostNotAllowed),
        Rejection(target: "https://[::1]/sf/rej/v6", error: .hostNotAllowed),
        Rejection(target: "https://[::ffff:127.0.0.1]/sf/rej/v6-mapped", error: .hostNotAllowed),
        Rejection(target: "https://localhost/sf/rej/localhost", error: .hostNotAllowed),
        Rejection(target: "https://foo.localhost/sf/rej/sub-localhost", error: .hostNotAllowed),
        Rejection(target: "https://printer.local/sf/rej/mdns", error: .hostNotAllowed),
        Rejection(target: "https://intranet/sf/rej/single-label", error: .hostNotAllowed),
    ])
    func rejectsBeforeAnyRequest(_ rejection: Rejection) async throws {
        let parsed = try #require(URL(string: rejection.target))
        let host = try #require(parsed.host()?.lowercased())
        let hosts = rejection.allowHost ? Self.hosts.union([host]) : Self.hosts
        route(rejection.marker, .init(status: 200, body: Data("leak".utf8)))
        await #expect(throws: rejection.error) {
            try await fetcher(hosts: hosts).fetch(parsed)
        }
        #expect(FetchStubProtocol.seen.withLock { $0.filter { $0.url?.path == rejection.marker }.isEmpty })
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

    @Test(.timeLimit(.minutes(2))) func aBurstOfFetchesWaitsForLookupSlotsInsteadOfFailing() async throws {
        route("/sf/burst", .init(status: 200, body: Data("x".utf8)))
        let slots = MemoryBudget(capacity: 2)
        let lookups = ThreadGate()
        defer { lookups.open() }
        let fetcher = gated(resolver: held(by: lookups), slots: slots)
        let target = url("https://media.example.com/sf/burst")
        let fetches = (0..<20).map { _ in outcome(of: fetcher, target) }
        defer { for fetch in fetches { fetch.cancel() } }
        try #require(await eventually { lookups.arrived == 2 && slots.waiterCount == 18 })
        lookups.open()
        for fetch in fetches {
            #expect(await fetch.settled() == .some(nil))
        }
    }

    @Test(.timeLimit(.minutes(2))) func lookupsBeyondTheSlotsWaitAndNeverRunMoreAtOnce() async throws {
        let slots = MemoryBudget(capacity: 3)
        let lookups = ThreadGate()
        defer { lookups.open() }
        let running = Atomic<Int>(0)
        let peak = Atomic<Int>(0)
        let resolver: SafeFetcher.Resolver = { _ in
            let now = running.add(1, ordering: .acquiringAndReleasing).newValue
            peak.max(now, ordering: .acquiringAndReleasing)
            lookups.pass()
            running.subtract(1, ordering: .acquiringAndReleasing)
            return [[93, 184, 216, 34]]
        }
        let never = Gate()
        let resolutions = (0..<12).map { _ in
            Recorded {
                await SafeFetcher.resolve(
                    "media.example.com", using: resolver, timeout: .seconds(3600), slots: slots,
                    slotExpiry: { try await never.wait() }, lookupExpiry: { try await never.wait() })
            }
        }
        defer { for resolution in resolutions { resolution.cancel() } }
        try #require(await eventually { lookups.arrived == 3 && slots.waiterCount == 9 })
        #expect(peak.load(ordering: .acquiring) == 3)
        lookups.open()
        for resolution in resolutions {
            #expect(await resolution.settled()?.isAddresses == true)
        }
        #expect(peak.load(ordering: .acquiring) == 3)
        #expect(lookups.arrived == 12)
    }

    @Test(.timeLimit(.minutes(2))) func anExpiredLookupKeepsItsSlotUntilItsThreadReturns() async throws {
        let slots = MemoryBudget(capacity: 1)
        let lookups = ThreadGate()
        defer { lookups.open() }
        let calls = Counter()
        let lookupExpiry = Gate()
        let slotExpiry = Gate()
        let resolver = held(by: lookups, calls: calls)
        let first = Recorded {
            await SafeFetcher.resolve(
                "a.example.com", using: resolver, timeout: .seconds(3600), slots: slots,
                slotExpiry: { try await slotExpiry.wait() }, lookupExpiry: { try await lookupExpiry.wait() })
        }
        defer { first.cancel() }
        try #require(await eventually { lookups.arrived == 1 })
        lookupExpiry.open()
        #expect(await first.settled()?.isTimedOut == true)
        #expect(await slots.available == 0)
        lookups.open()
        #expect(await eventually { await slots.available == 1 })
        #expect(calls.count == 1)
    }

    @Test(.timeLimit(.minutes(2))) func aLookupQueuedBehindAStuckOneTimesOutWithoutStarting() async throws {
        let slots = MemoryBudget(capacity: 1)
        let lookups = ThreadGate()
        defer { lookups.open() }
        let calls = Counter()
        let never = Gate()
        let queuedExpiry = Gate()
        let resolver = held(by: lookups, calls: calls)
        let stuck = Recorded {
            await SafeFetcher.resolve(
                "a.example.com", using: resolver, timeout: .seconds(3600), slots: slots,
                slotExpiry: { try await never.wait() }, lookupExpiry: { try await never.wait() })
        }
        defer { stuck.cancel() }
        try #require(await eventually { lookups.arrived == 1 })
        let queued = Recorded {
            await SafeFetcher.resolve(
                "a.example.com", using: resolver, timeout: .seconds(3600), slots: slots,
                slotExpiry: { try await queuedExpiry.wait() }, lookupExpiry: { try await never.wait() })
        }
        defer { queued.cancel() }
        try #require(await eventually { slots.waiterCount == 1 })
        queuedExpiry.open()
        #expect(await queued.settled()?.isTimedOut == true)
        #expect(slots.waiterCount == 0)
        lookups.open()
        #expect(await stuck.settled()?.isAddresses == true)
        #expect(await eventually { await slots.available == 1 })
        #expect(calls.count == 1)
    }

    @Test(.timeLimit(.minutes(2))) func aCancelledWaiterNeverStartsItsLookup() async throws {
        let slots = MemoryBudget(capacity: 1)
        let held = try await slots.reserve(1)
        defer { held.release() }
        let calls = Counter()
        let resolver: SafeFetcher.Resolver = { _ in
            calls.bump()
            return [[93, 184, 216, 34]]
        }
        let never = Gate()
        let waiter = Recorded {
            await SafeFetcher.resolve(
                "a.example.com", using: resolver, timeout: .seconds(3600), slots: slots,
                slotExpiry: { try await never.wait() }, lookupExpiry: { try await never.wait() })
        }
        defer { waiter.cancel() }
        try #require(await eventually { slots.waiterCount == 1 })
        waiter.cancel()
        #expect(await waiter.settled()?.isCancelled == true)
        #expect(slots.waiterCount == 0)
        held.release()
        #expect(await slots.available == 1)
        #expect(calls.count == 0)
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

    @Test(.timeLimit(.minutes(2))) func deadlineCancelsASilentServer() async throws {
        let deadline = Gate()
        let slow = gated(
            protocolClass: HangingProtocol.self, resolver: nil, slots: MemoryBudget(capacity: 1), fetch: deadline)
        let fetch = outcome(of: slow, url("https://media.example.com/sf/hang-deadline"))
        defer { fetch.cancel() }
        try #require(await eventually { HangingProtocol.started.withLock { $0["/sf/hang-deadline"] != nil } })
        #expect(HangingProtocol.started.withLock { $0["/sf/hang-deadline"] } == 3600)
        deadline.open()
        #expect(await fetch.settled() == .some(.timedOut))
    }

    @Test(.timeLimit(.minutes(2))) func callerCancellationStopsTheFetch() async throws {
        let slow = gated(protocolClass: HangingProtocol.self, resolver: nil, slots: MemoryBudget(capacity: 1))
        let fetch = outcome(of: slow, url("https://media.example.com/sf/hang-cancel"))
        defer { fetch.cancel() }
        try #require(await eventually { HangingProtocol.started.withLock { $0["/sf/hang-cancel"] != nil } })
        fetch.cancel()
        #expect(await fetch.settled() == .some(.cancelled))
    }

    @Test(.timeLimit(.minutes(2))) func aStalledResolverIsAbandonedAtTheDeadline() async throws {
        let slots = MemoryBudget(capacity: 1)
        let lookups = ThreadGate()
        defer { lookups.open() }
        let deadline = Gate()
        let slow = gated(resolver: held(by: lookups), slots: slots, fetch: deadline)
        let fetch = outcome(of: slow, url("https://media.example.com/sf/dns-stall"))
        defer { fetch.cancel() }
        try #require(await eventually { lookups.arrived == 1 })
        deadline.open()
        #expect(await fetch.settled() == .some(.timedOut))
        #expect(await slots.available == 0)
        lookups.open()
        #expect(await eventually { await slots.available == 1 })
        #expect(requestCount(path: "/sf/dns-stall") == 0)
    }

    @Test(.timeLimit(.minutes(2))) func cancellingDuringResolutionReturnsWhileTheLookupIsStuck() async throws {
        let slots = MemoryBudget(capacity: 1)
        let lookups = ThreadGate()
        defer { lookups.open() }
        let slow = gated(resolver: held(by: lookups), slots: slots)
        let fetch = outcome(of: slow, url("https://media.example.com/sf/dns-cancel"))
        defer { fetch.cancel() }
        try #require(await eventually { lookups.arrived == 1 })
        fetch.cancel()
        #expect(await fetch.settled() == .some(.cancelled))
        #expect(await slots.available == 0)
        lookups.open()
        #expect(await eventually { await slots.available == 1 })
        #expect(requestCount(path: "/sf/dns-cancel") == 0)
    }

    @Test func aCancelledFetchNeverConnects() async {
        FetchStubProtocol.routes.withLock { $0["/sf/never"] = .init(status: 200, body: Data("x".utf8)) }
        let resolver: SafeFetcher.Resolver = { _ in [[93, 184, 216, 34]] }
        let target = url("https://media.example.com/sf/never")
        let fetch = Recorded { () -> TransportError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(TransportError) {
                _ = try await fetcher(resolver: resolver).fetch(target)
                return nil
            } catch {
                return error
            }
        }
        #expect(await fetch.settled() == .some(.cancelled))
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
