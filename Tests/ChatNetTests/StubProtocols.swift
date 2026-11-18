import Foundation
import Synchronization

/// Per-suite copies of the canned-response stub, so suites that run in parallel don't see each other's requests.

final class DownloadStubProtocol: URLProtocol, @unchecked Sendable {
    static let routes = Mutex<[String: StubProtocol.Canned]>([:])
    static let seen = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.withLock { $0.append(request) }
        let canned = Self.routes.withLock { $0[request.url?.path ?? ""] } ?? StubProtocol.Canned(status: 404)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: canned.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class FetchStubProtocol: URLProtocol, @unchecked Sendable {
    static let routes = Mutex<[String: StubProtocol.Canned]>([:])
    static let seen = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.withLock { $0.append(request) }
        let canned = Self.routes.withLock { $0[request.url?.path ?? ""] } ?? StubProtocol.Canned(status: 404)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: canned.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AdmitStubProtocol: URLProtocol, @unchecked Sendable {
    static let routes = Mutex<[String: StubProtocol.Canned]>([:])
    static let seen = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.withLock { $0.append(request) }
        let canned = Self.routes.withLock { $0[request.url?.path ?? ""] } ?? StubProtocol.Canned(status: 404)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: canned.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
