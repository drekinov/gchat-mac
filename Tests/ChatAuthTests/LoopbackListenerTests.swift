import Foundation
import Testing

@testable import ChatAuth

struct LoopbackListenerTests {
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
        let listener = try await LoopbackListener.start()
        async let callback = listener.callback(timeout: .seconds(5))

        let base = try #require(URL(string: "http://127.0.0.1:\(listener.redirectURI.port!)"))
        let (_, stray) = try await Self.session.data(from: base.appending(path: "favicon.ico"))
        #expect((stray as? HTTPURLResponse)?.statusCode == 404)

        var callbackURL = URLComponents(url: listener.redirectURI, resolvingAgainstBaseURL: false)!
        callbackURL.queryItems = [URLQueryItem(name: "code", value: "c0de"), URLQueryItem(name: "state", value: "s")]
        let (body, ok) = try await Self.session.data(from: callbackURL.url!)
        #expect((ok as? HTTPURLResponse)?.statusCode == 200)
        #expect(!String(decoding: body, as: UTF8.self).contains("c0de"))

        let components = try await callback
        #expect(components.queryItems?.first { $0.name == "code" }?.value == "c0de")
    }

    @Test func singleUse() async throws {
        let listener = try await LoopbackListener.start()
        async let callback = listener.callback(timeout: .seconds(5))
        _ = try await Self.session.data(from: listener.redirectURI)
        _ = try await callback
        await #expect(throws: (any Error).self) { _ = try await Self.session.data(from: listener.redirectURI) }
    }

    @Test func timesOut() async throws {
        let listener = try await LoopbackListener.start()
        await #expect(throws: LoopbackError.timedOut) { try await listener.callback(timeout: .milliseconds(50)) }
    }

    @Test func cancelWakesWaiter() async throws {
        let listener = try await LoopbackListener.start()
        let callback = Task { try await listener.callback(timeout: .seconds(5)) }
        try #require(await eventually { listener.hasWaiter })
        listener.cancel()
        await #expect(throws: LoopbackError.cancelled) { try await callback.value }
    }

    @Test func taskCancellationWakesWaiter() async throws {
        let listener = try await LoopbackListener.start()
        let task = Task { try await listener.callback(timeout: .seconds(5)) }
        defer { listener.cancel() }
        try #require(await eventually { listener.hasWaiter })
        task.cancel()
        await #expect(throws: LoopbackError.cancelled) { try await task.value }
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
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()
}
