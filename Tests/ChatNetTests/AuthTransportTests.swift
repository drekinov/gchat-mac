import Foundation
import Synchronization
import Testing

@testable import ChatNet

/// Serves canned responses keyed by URL path and records every request it sees.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Canned: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
        var error: URLError.Code?
    }

    static let routes = Mutex<[String: Canned]>([:])
    static let seen = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.withLock { $0.append(request) }
        let canned = Self.routes.withLock { $0[request.url?.path ?? ""] } ?? Canned(status: 404)
        if let code = canned.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: canned.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct AuthTransportTests {
    let transport = AuthTransport(allowedHosts: ["chat.googleapis.com"], protocolClasses: [StubProtocol.self])

    func route(_ path: String, _ canned: StubProtocol.Canned) {
        StubProtocol.routes.withLock { $0[path] = canned }
    }

    @Test func returnsStatusLowercasedHeadersAndBody() async throws {
        route("/ok", .init(status: 200, headers: ["X-Thing": "1"], body: Data("hi".utf8)))
        let response = try await transport.send(HTTPRequest(url: URL(string: "https://chat.googleapis.com/ok")!))
        #expect(response.status == 200)
        #expect(response.headers["x-thing"] == "1")
        #expect(response.body == Data("hi".utf8))
    }

    @Test func passesErrorStatusesThrough() async throws {
        route("/denied", .init(status: 403, body: Data("{}".utf8)))
        let response = try await transport.send(HTTPRequest(url: URL(string: "https://chat.googleapis.com/denied")!))
        #expect(response.status == 403)
    }

    static var credentialedURL: String {
        var parts = URLComponents(string: "https://chat.googleapis.com/x")!
        parts.user = "sample"
        parts.password = UUID().uuidString
        return parts.url!.absoluteString
    }

    @Test(arguments: [
        "http://chat.googleapis.com/x", "https://evil.example/x", "https://chat.googleapis.com.evil.example/x",
        AuthTransportTests.credentialedURL,
    ])
    func rejectsBeforeAnyRequest(url: String) async {
        let before = StubProtocol.seen.withLock { $0.count }
        await #expect(throws: TransportError.self) {
            try await transport.send(HTTPRequest(url: URL(string: url)!))
        }
        #expect(StubProtocol.seen.withLock { $0.count } == before)
    }

    @Test func redirectIsAnErrorWithLocationAndNotFollowed() async throws {
        route("/media", .init(status: 302, headers: ["Location": "https://lh3.googleusercontent.com/abc"]))
        let request = HTTPRequest(
            url: URL(string: "https://chat.googleapis.com/media")!, headers: ["Authorization": "Bearer t"])
        await #expect(
            throws: TransportError.redirected(
                status: 302, location: URL(string: "https://lh3.googleusercontent.com/abc"))
        ) {
            try await transport.send(request)
        }
        let followed = StubProtocol.seen.withLock { $0.contains { $0.url?.host == "lh3.googleusercontent.com" } }
        #expect(!followed)
    }

    @Test func capsDeclaredLength() async {
        route("/big", .init(status: 200, headers: ["Content-Length": "100"], body: Data(count: 100)))
        await #expect(throws: TransportError.responseTooLarge) {
            try await transport.send(
                HTTPRequest(url: URL(string: "https://chat.googleapis.com/big")!, maxResponseBytes: 10))
        }
    }

    @Test func capsStreamedLength() async {
        route("/chunked", .init(status: 200, body: Data(count: 100)))
        await #expect(throws: TransportError.responseTooLarge) {
            try await transport.send(
                HTTPRequest(url: URL(string: "https://chat.googleapis.com/chunked")!, maxResponseBytes: 10))
        }
    }

    @Test func sendsNoCookies() async throws {
        route("/cookie", .init(status: 200, headers: ["Set-Cookie": "SID=1; Path=/"]))
        _ = try await transport.send(HTTPRequest(url: URL(string: "https://chat.googleapis.com/cookie")!))
        _ = try await transport.send(HTTPRequest(url: URL(string: "https://chat.googleapis.com/cookie")!))
        let cookies = StubProtocol.seen.withLock {
            $0.filter { $0.url?.path == "/cookie" }.map { $0.value(forHTTPHeaderField: "Cookie") }
        }
        #expect(cookies.allSatisfy { $0 == nil })
    }

    @Test(arguments: [
        (URLError.Code.timedOut, TransportError.timedOut),
        (.notConnectedToInternet, .offline),
        (.networkConnectionLost, .connectionLost),
        (.serverCertificateUntrusted, .tls),
    ])
    func mapsURLErrors(code: URLError.Code, expected: TransportError) async {
        route("/fail", .init(status: 0, error: code))
        await #expect(throws: expected) {
            try await transport.send(HTTPRequest(url: URL(string: "https://chat.googleapis.com/fail")!))
        }
    }

    @Test func unknownOutcomeClassification() {
        #expect(TransportError.timedOut.mayHaveReachedServer)
        #expect(TransportError.connectionLost.mayHaveReachedServer)
        #expect(!TransportError.offline.mayHaveReachedServer)
        #expect(!TransportError.hostNotAllowed.mayHaveReachedServer)
    }
}
