import Foundation
import Testing

@testable import ChatAuth

struct LoopbackListenerTests {
    /// Waits for the callback in its own task, with a timeout that ends only if the test fires it.
    func callback(
        on listener: LoopbackListener, timeout: ManualTimeout = ManualTimeout()
    ) -> Recorded<Result<URLComponents, any Error>> {
        Recorded(catching: { try await listener.callback(timeout: Self.timeout, sleep: timeout.sleep) })
    }

    static let timeout: Duration = .seconds(300)

    /// A listener that never cuts a connection for being slow to send its request.
    func patientListener() async throws -> LoopbackListener {
        try await LoopbackListener.start(expectedState: nil, headerTimer: { _ in })
    }

    @Test func redirectURIIsLoopbackWithEphemeralPort() async throws {
        let listener = try await LoopbackListener.start()
        defer { listener.cancel() }
        let uri = listener.redirectURI
        #expect(uri.scheme == "http")
        #expect(uri.host == "127.0.0.1")
        #expect(uri.path == LoopbackListener.callbackPath)
        #expect((uri.port ?? 0) > 0)
    }

    @Test func deliversCallbackAfterIgnoringOtherPaths() async throws {
        let listener = try await patientListener()
        defer { listener.cancel() }
        let callback = callback(on: listener)
        defer { callback.cancel() }

        let base = try #require(URL(string: "http://127.0.0.1:\(listener.redirectURI.port!)"))
        let (_, stray) = try await Self.session.data(from: base.appending(path: "favicon.ico"))
        #expect((stray as? HTTPURLResponse)?.statusCode == 404)

        var callbackURL = URLComponents(url: listener.redirectURI, resolvingAgainstBaseURL: false)!
        callbackURL.queryItems = [URLQueryItem(name: "code", value: "c0de"), URLQueryItem(name: "state", value: "s")]
        let (body, ok) = try await Self.session.data(from: callbackURL.url!)
        #expect((ok as? HTTPURLResponse)?.statusCode == 200)
        #expect(!String(decoding: body, as: UTF8.self).contains("c0de"))

        let components = try #require(await callback.settled()).get()
        #expect(components.queryItems?.first { $0.name == "code" }?.value == "c0de")
    }

    @Test func singleUse() async throws {
        let listener = try await patientListener()
        defer { listener.cancel() }
        let callback = callback(on: listener)
        defer { callback.cancel() }
        _ = try await Self.session.data(from: listener.redirectURI)
        _ = try #require(await callback.settled()).get()
        await #expect(throws: (any Error).self) { _ = try await Self.session.data(from: listener.redirectURI) }
    }

    @Test func timesOut() async throws {
        let listener = try await LoopbackListener.start()
        defer { listener.cancel() }
        let timeout = ManualTimeout()
        let callback = callback(on: listener, timeout: timeout)
        defer { callback.cancel() }
        try #require(await eventually { listener.hasWaiter && timeout.asked == [Self.timeout] })
        timeout.fire()
        let ended = try #require(await callback.settled())
        #expect(throws: LoopbackError.timedOut) { try ended.get() }
    }

    @Test func cancelWakesWaiter() async throws {
        let listener = try await LoopbackListener.start()
        let callback = callback(on: listener)
        defer { callback.cancel() }
        try #require(await eventually { listener.hasWaiter })
        listener.cancel()
        let ended = try #require(await callback.settled())
        #expect(throws: LoopbackError.cancelled) { try ended.get() }
    }

    @Test func taskCancellationWakesWaiter() async throws {
        let listener = try await LoopbackListener.start()
        let callback = callback(on: listener)
        defer { listener.cancel() }
        try #require(await eventually { listener.hasWaiter })
        callback.cancel()
        let ended = try #require(await callback.settled())
        #expect(throws: LoopbackError.cancelled) { try ended.get() }
    }

    @Test(
        arguments: [
            ("GET /oauth2/callback?code=x HTTP/1.1", "/oauth2/callback"),
            ("POST /oauth2/callback HTTP/1.1", nil),
            ("GET http://evil/oauth2/callback HTTP/1.1", nil),
            ("GET /oauth2/callback", nil),
            ("garbage", nil),
        ] as [(String, String?)])
    func requestLineParsing(line: String, path: String?) {
        let head = Data((line + "\r\nHost: 127.0.0.1").utf8)
        #expect(LoopbackListener.parseRequestLine(head)?.path == path)
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(hangGuard.components.seconds)
        return URLSession(configuration: configuration)
    }()
}
