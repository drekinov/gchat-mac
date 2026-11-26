import Foundation
import Network
import Synchronization

public enum LoopbackError: Error, Sendable, Equatable {
    case listenerFailed(String)
    case timedOut
    case cancelled
}

/// Single-use HTTP listener on 127.0.0.1 for the OAuth redirect. It never echoes request data in its responses.
public final class LoopbackListener: Sendable {
    public static let callbackPath = "/oauth2/callback"
    static let maxRequestBytes = 8 * 1024
    static let maxConnections = 16
    static let headerDeadline = DispatchTimeInterval.seconds(5)

    /// Arranges for `expire` to run once a connection has had `headerDeadline` to send its request.
    typealias HeaderTimer = @Sendable (_ expire: @escaping @Sendable () -> Void) -> Void

    public let redirectURI: URL
    private let listener: NWListener
    private let queue: DispatchQueue
    private let headerTimer: HeaderTimer
    private let state = Mutex(State())

    /// Only a callback carrying this `state` ends the wait; anything else is refused and waiting continues.
    let expectedState: String?

    private struct State {
        var result: Result<URLComponents, LoopbackError>?
        var waiter: CheckedContinuation<URLComponents, any Error>?
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var refused = 0
    }

    private init(
        listener: NWListener, port: UInt16, queue: DispatchQueue, expectedState: String?, headerTimer: HeaderTimer?
    ) {
        self.listener = listener
        self.queue = queue
        self.expectedState = expectedState
        self.headerTimer =
            headerTimer ?? { expire in queue.asyncAfter(deadline: .now() + Self.headerDeadline, execute: expire) }
        self.redirectURI = URL(string: "http://127.0.0.1:\(port)\(Self.callbackPath)")!
    }

    public static func start(expectedState: String? = nil) async throws(LoopbackError) -> LoopbackListener {
        try await start(expectedState: expectedState, headerTimer: nil)
    }

    /// A nil `headerTimer` closes each connection `headerDeadline` after it was accepted.
    static func start(
        expectedState: String?, headerTimer: HeaderTimer?
    ) async throws(LoopbackError) -> LoopbackListener {
        let queue = DispatchQueue(label: "io.github.drekinov.gchat-mac.loopback")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true

        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: parameters)
        } catch {
            throw .listenerFailed(String(describing: error))
        }

        let port: UInt16
        do {
            port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
                let once = OnceFlag()
                let resumeOnce: @Sendable (Result<UInt16, LoopbackError>) -> Void = { result in
                    guard once.claim() else { return }
                    continuation.resume(with: result.mapError { $0 as any Error })
                }
                nwListener.stateUpdateHandler = { [weak nwListener] newState in
                    switch newState {
                    case .ready:
                        if let port = nwListener?.port?.rawValue {
                            resumeOnce(.success(port))
                        } else {
                            resumeOnce(.failure(.listenerFailed("no port")))
                        }
                    case .failed(let error), .waiting(let error):
                        resumeOnce(.failure(.listenerFailed(String(describing: error))))
                    case .cancelled:
                        resumeOnce(.failure(.cancelled))
                    default:
                        break
                    }
                }
                // Connections arriving before `self` exists are refused; the browser can't know the port yet.
                nwListener.newConnectionHandler = { $0.cancel() }
                nwListener.start(queue: queue)
            }
        } catch {
            nwListener.cancel()
            throw (error as? LoopbackError) ?? .listenerFailed(String(describing: error))
        }

        let loopback = LoopbackListener(
            listener: nwListener, port: port, queue: queue, expectedState: expectedState, headerTimer: headerTimer)
        nwListener.stateUpdateHandler = { [weak loopback] newState in
            switch newState {
            case .failed(let error):
                loopback?.finish(.failure(.listenerFailed(String(describing: error))))
            case .cancelled:
                loopback?.finish(.failure(.cancelled))
            default:
                break
            }
        }
        nwListener.newConnectionHandler = { [weak loopback] connection in
            guard let loopback else { return connection.cancel() }
            loopback.handle(connection)
        }
        return loopback
    }

    /// Waits for the first request to `callbackPath`; other paths get a 404 and waiting continues.
    public func callback(timeout: Duration) async throws(LoopbackError) -> URLComponents {
        try await callback(timeout: timeout, sleep: { try await Task.sleep(for: $0) })
    }

    /// `sleep` waits out `timeout` and throws when its task is cancelled, which is how a callback ends the wait.
    func callback(
        timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws(LoopbackError) -> URLComponents {
        do {
            return try await withThrowingTaskGroup(of: URLComponents.self) { group in
                group.addTask { try await self.awaitResult() }
                group.addTask {
                    try await sleep(timeout)
                    throw LoopbackError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch let error as LoopbackError {
            if error == .timedOut { cancel() }
            throw error
        } catch {
            cancel()
            throw .cancelled
        }
    }

    var openConnections: Int { state.withLock { $0.connections.count } }
    var refusedConnections: Int { state.withLock { $0.refused } }
    var hasWaiter: Bool { state.withLock { $0.waiter != nil } }

    public func cancel() {
        finish(.failure(.cancelled))
    }

    private func awaitResult() async throws -> URLComponents {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLComponents, any Error>) in
                // Checked under the lock so a cancellation that ran before the waiter was stored isn't lost.
                let ready = state.withLock { state -> Result<URLComponents, LoopbackError>? in
                    if let result = state.result { return result }
                    if Task.isCancelled { return .failure(.cancelled) }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready.mapError { $0 as any Error }) }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Ends the listener and every open connection except `keeping`, which is still sending its response.
    private func finish(_ result: Result<URLComponents, LoopbackError>, keeping: NWConnection? = nil) {
        let (waiter, open) = state.withLock {
            state -> (CheckedContinuation<URLComponents, any Error>?, [NWConnection]) in
            guard state.result == nil else { return (nil, []) }
            state.result = result
            let open = Array(state.connections.values)
            state.connections = [:]
            defer { state.waiter = nil }
            return (state.waiter, open)
        }
        listener.cancel()
        for connection in open where connection !== keeping { connection.cancel() }
        waiter?.resume(with: result.mapError { $0 as any Error })
    }

    private func handle(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let accepted = state.withLock { state -> Bool in
            guard state.result == nil, state.connections.count < Self.maxConnections else {
                state.refused += 1
                return false
            }
            state.connections[id] = connection
            return true
        }
        guard accepted else { return connection.cancel() }
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .cancelled, .failed:
                _ = self?.state.withLock { $0.connections.removeValue(forKey: id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        headerTimer { connection.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) {
            [weak self] content, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let content { buffer.append(content) }

            if buffer.count > Self.maxRequestBytes {
                return self.respond(on: connection, status: "431 Request Header Fields Too Large")
            }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil { return connection.cancel() }
                return self.receive(on: connection, buffer: buffer)
            }
            self.route(buffer[..<headerEnd.lowerBound], on: connection)
        }
    }

    private func route(_ head: Data, on connection: NWConnection) {
        guard let components = Self.parseRequestLine(head) else {
            return respond(on: connection, status: "400 Bad Request")
        }
        guard components.path == Self.callbackPath else {
            return respond(on: connection, status: "404 Not Found")
        }
        guard Self.accepts(components, expectedState: expectedState) else {
            return respond(on: connection, status: "400 Bad Request")
        }
        respond(on: connection, status: "200 OK", body: Self.successPage)
        finish(.success(components), keeping: connection)
    }

    /// Every parameter single-valued, and `state` present and equal (in constant time) when one is expected.
    static func accepts(_ components: URLComponents, expectedState: String?) -> Bool {
        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { return false }
        guard let expectedState else { return true }
        guard let state = items.first(where: { $0.name == "state" })?.value else { return false }
        let a = Array(expectedState.utf8)
        let b = Array(state.utf8)
        return a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func parseRequestLine(_ head: Data) -> URLComponents? {
        guard let text = String(data: head, encoding: .utf8),
            let line = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first
        else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else {
            return nil
        }
        return URLComponents(string: String(parts[1]))
    }

    private static let successPage = """
        <!doctype html><meta charset="utf-8"><title>Thimble</title>\
        <p>Signed in. You can close this tab and return to Thimble.</p>
        """

    private func respond(on connection: NWConnection, status: String, body: String = "") {
        let bodyData = Data(body.utf8)
        let head = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class OnceFlag: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}
