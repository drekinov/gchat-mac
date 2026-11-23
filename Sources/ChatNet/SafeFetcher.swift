import Foundation
import Synchronization

/// Fetches token-less media (GIFs, custom emoji) from an explicit host allowlist. It has no way to attach
/// credentials, never stores cookies or cache, and re-validates every redirect target itself.
///
/// Name resolution is checked before connecting, but the connection resolves again, so DNS rebinding in
/// between is not covered; the exact-host allowlist is the primary control. Lookups run on their own threads,
/// so a stalled resolver is abandoned at the deadline instead of holding the fetch.
public final class SafeFetcher: Sendable {
    /// Profile photos only so far; GIF and custom-emoji hosts are added once observed.
    public static let productionHosts: Set<String> = profilePhotoHosts
    /// The People API has been seen to hand out photos on lh3; the other lh hosts serve the same content.
    public static let profilePhotoHosts: Set<String> = [
        "lh3.googleusercontent.com", "lh4.googleusercontent.com", "lh5.googleusercontent.com",
        "lh6.googleusercontent.com",
    ]
    public static let maxRedirects = 3
    public static let deadline: Duration = .seconds(20)
    static let maxResolverThreads = 8
    static let lookupSlots = MemoryBudget(capacity: maxResolverThreads)

    typealias Resolver = @Sendable (String) throws -> [[UInt8]]

    private struct Fetched: Sendable {
        var data: Data
        var contentType: String?
    }

    private let allowedHosts: Set<String>
    private let session: TransferSession
    private let resolver: Resolver?
    private let deadline: Duration

    /// A non-nil `protocolClasses` replaces the network with an in-process stub, so the DNS check is skipped.
    public convenience init(allowedHosts: Set<String> = SafeFetcher.productionHosts, protocolClasses: [AnyClass]? = nil)
    {
        self.init(
            allowedHosts: allowedHosts, protocolClasses: protocolClasses,
            resolver: protocolClasses == nil ? Self.systemResolver : nil)
    }

    init(
        allowedHosts: Set<String>, protocolClasses: [AnyClass]?, resolver: Resolver?,
        deadline: Duration = SafeFetcher.deadline
    ) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.resolver = resolver
        self.deadline = deadline
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.timeoutIntervalForRequest = 20
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = TransferSession(configuration: configuration)
    }

    /// Downloads into memory that `admission` has already reserved. At most `min(maxBytes, admission.byteCount)`
    /// bytes are accepted, and on success `admission` is shrunk to the bytes actually received. On failure the
    /// caller still owns the admission, and dropping it releases the budget.
    public func fetch(
        _ url: URL, maxBytes: Int = 20 << 20, admission: borrowing EncodedAdmission
    ) async throws(TransportError) -> (Data, contentType: String?) {
        let (data, contentType) = try await fetch(url, maxBytes: min(maxBytes, admission.byteCount))
        admission.shrink(to: data.count)
        return (data, contentType)
    }

    /// Non-2xx statuses throw `.other(code: status)`; redirects past the limit throw `.redirected` without a URL.
    public func fetch(
        _ url: URL, maxBytes: Int = 20 << 20
    ) async throws(TransportError) -> (Data, contentType: String?) {
        let outcome = await withTaskGroup(of: Result<Fetched, TransportError>?.self) { group in
            group.addTask { await self.followRedirects(from: url, maxBytes: maxBytes) }
            group.addTask {
                do { try await Task.sleep(for: self.deadline) } catch { return nil }
                return .failure(.timedOut)
            }
            var first: Result<Fetched, TransportError>?
            for await result in group where result != nil {
                first = result
                break
            }
            group.cancelAll()
            return first ?? .failure(.cancelled)
        }
        let fetched = try outcome.get()
        return (fetched.data, fetched.contentType)
    }

    private func followRedirects(from start: URL, maxBytes: Int) async -> Result<Fetched, TransportError> {
        var url = start
        var hop = 0
        while true {
            do throws(TransportError) {
                guard !Task.isCancelled else { throw .cancelled }
                try await validate(url)
                guard !Task.isCancelled else { throw .cancelled }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.httpShouldHandleCookies = false
                request.timeoutInterval = 20
                let buffer = Mutex(Data())
                let head = try await session.run(request, mode: .buffered, maxBytes: maxBytes) { chunk in
                    buffer.withLock { $0.append(chunk) }
                }
                guard (200..<300).contains(head.status) else { throw .other(code: head.status) }
                return .success(Fetched(data: buffer.withLock { $0 }, contentType: head.headers["content-type"]))
            } catch .redirected(let status, let location) {
                hop += 1
                guard hop <= Self.maxRedirects, let location else {
                    return .failure(.redirected(status: status, location: nil))
                }
                url = location
            } catch {
                return .failure(error)
            }
        }
    }

    private func validate(_ url: URL) async throws(TransportError) {
        let host = try Self.validateSyntax(url, allowedHosts: allowedHosts)
        guard let resolver else { return }
        switch await Self.resolve(host, using: resolver, timeout: deadline) {
        case .addresses(let addresses):
            guard !addresses.isEmpty else { throw .offline }
            guard addresses.allSatisfy(Self.isPublicAddress) else { throw .hostNotAllowed }
        case .failed: throw .offline
        case .timedOut: throw .timedOut
        case .cancelled: throw .cancelled
        }
    }

    enum Resolution: Sendable {
        case addresses([[UInt8]])
        case failed
        case timedOut
        case cancelled
    }

    /// Runs `resolver` on a dedicated thread and returns at the first of: its answer, `timeout`, or cancellation.
    /// Lookups beyond `maxResolverThreads` wait their turn within `timeout`. On timeout or cancellation the thread is
    /// abandoned and keeps its slot until it finishes, so stuck lookups can't pile up threads.
    static func resolve(
        _ host: String, using resolver: @escaping Resolver, timeout: Duration, slots: MemoryBudget = lookupSlots
    ) async -> Resolution {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let slot: Reservation
        do {
            slot = try await slots.reserve(1, timeout: timeout)
        } catch {
            return Task.isCancelled || error is CancellationError ? .cancelled : .timedOut
        }
        // A grant can race with cancellation or arrive at the deadline; dropping `slot` returns it.
        guard !Task.isCancelled else { return .cancelled }
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return .timedOut }
        let latch = Latch<Resolution>()
        let thread = Thread {
            let result = try? resolver(host)
            slot.release()
            latch.set(result.map { .addresses($0) } ?? .failed)
        }
        thread.stackSize = 512 * 1024
        thread.start()
        let timer = Task {
            do { try await Task.sleep(for: remaining) } catch { return }
            latch.set(.timedOut)
        }
        let outcome = await withTaskCancellationHandler {
            await latch.value()
        } onCancel: {
            latch.set(.cancelled)
        }
        timer.cancel()
        return outcome
    }

    /// True when `url` passes every check that doesn't need the network.
    public static func passesSyntax(_ url: URL, allowedHosts: Set<String>) -> Bool {
        (try? validateSyntax(url, allowedHosts: allowedHosts)) != nil
    }

    /// Everything that can be decided without the network. Returns the lowercased host.
    static func validateSyntax(_ url: URL, allowedHosts: Set<String>) throws(TransportError) -> String {
        guard url.scheme?.lowercased() == "https" else { throw .insecureScheme }
        guard url.user() == nil, url.password() == nil, url.port == nil || url.port == 443,
            let host = url.host()?.lowercased(), !host.isEmpty,
            !isIPLiteral(host), !isLocalName(host), allowedHosts.contains(host)
        else { throw .hostNotAllowed }
        return host
    }

    /// Also catches the legacy forms `inet_aton` accepts, such as `127.1`, `0x7f.1` and `2130706433`.
    static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        let unbracketed = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let withoutZone = unbracketed.split(separator: "%", maxSplits: 1).first.map(String.init) ?? unbracketed
        return inet_aton(withoutZone, &v4) != 0 || inet_pton(AF_INET6, withoutZone, &v6) == 1
            || withoutZone.contains(":")
    }

    static func isLocalName(_ host: String) -> Bool {
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        if name == "localhost" || !name.contains(".") { return true }
        return [".localhost", ".local", ".localdomain", ".internal", ".home.arpa", ".lan"].contains {
            name.hasSuffix($0)
        }
    }

    /// `bytes` is a 4-byte IPv4 or 16-byte IPv6 address.
    static func isPublicAddress(_ bytes: [UInt8]) -> Bool {
        switch bytes.count {
        case 4:
            return isPublicV4(bytes[0], bytes[1], bytes[2], bytes[3])
        case 16:
            if bytes.dropLast().allSatisfy({ $0 == 0 }) { return false }
            let first80Zero = bytes[0..<10].allSatisfy { $0 == 0 }
            if first80Zero, bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isPublicV4(bytes[12], bytes[13], bytes[14], bytes[15])
            }
            if first80Zero { return false }
            if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xFF, bytes[3] == 0x9B,
                bytes[4..<12].allSatisfy({ $0 == 0 })
            {
                return isPublicV4(bytes[12], bytes[13], bytes[14], bytes[15])
            }
            if bytes[0] == 0x20, bytes[1] == 0x02 { return isPublicV4(bytes[2], bytes[3], bytes[4], bytes[5]) }
            if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] == 0x00 { return false }
            if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return false }
            if bytes[0] == 0x01, bytes[1] == 0x00, bytes[2..<8].allSatisfy({ $0 == 0 }) { return false }
            if bytes[0] & 0xFE == 0xFC { return false }
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false }
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return false }
            if bytes[0] == 0xFF { return false }
            return true
        default:
            return false
        }
    }

    private static func isPublicV4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Bool {
        switch (a, b, c) {
        case (0, _, _), (10, _, _), (127, _, _): false
        case (100, 64...127, _): false
        case (169, 254, _): false
        case (172, 16...31, _): false
        case (192, 0, 0), (192, 0, 2), (192, 88, 99), (192, 168, _): false
        case (198, 18...19, _), (198, 51, 100), (203, 0, 113): false
        case (224..., _, _): false
        default: true
        }
    }

    static let systemResolver: Resolver = { host in
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else {
            throw TransportError.offline
        }
        defer { freeaddrinfo(first) }
        var addresses: [[UInt8]] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if let address = current.pointee.ai_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        addresses.append(withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) })
                    }
                case AF_INET6:
                    address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        addresses.append(withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) })
                    }
                default:
                    break
                }
            }
            node = current.pointee.ai_next
        }
        return addresses
    }
}

/// A value that is set once, by whoever gets there first, and can be awaited before or after it is set.
final class Latch<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiter: CheckedContinuation<Value, Never>?
    }

    private let state = Mutex(State())

    func set(_ value: Value) {
        let waiter: CheckedContinuation<Value, Never>? = state.withLock { state in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: value)
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            let ready: Value? = state.withLock { state in
                if let value = state.value { return value }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
