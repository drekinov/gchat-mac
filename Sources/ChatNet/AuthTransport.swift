import Foundation
import Synchronization

/// The only transport for requests that carry a bearer token or OAuth secrets. HTTPS to an exact host allowlist,
/// no redirects, no cookies, no URL cache, and a streamed response size cap.
public final class AuthTransport: StreamingTransport {
    public static let googleHosts: Set<String> = [
        "chat.googleapis.com", "oauth2.googleapis.com", "openidconnect.googleapis.com", "people.googleapis.com",
    ]

    private let allowedHosts: Set<String>
    private let session: TransferSession

    /// `protocolClasses` lets tests route requests to an in-process fake.
    public init(allowedHosts: Set<String> = AuthTransport.googleHosts, protocolClasses: [AnyClass]? = nil) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
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
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = TransferSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse {
        let buffer = Mutex(Data())
        let head = try await run(request, mode: .buffered) { chunk in buffer.withLock { $0.append(chunk) } }
        return HTTPResponse(status: head.status, headers: head.headers, body: buffer.withLock { $0 })
    }

    /// `onChunk` runs on the session's serial delegate queue, so a slow sink delays other transfers.
    public func stream(
        _ request: HTTPRequest, onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws(TransportError) -> HTTPResponseHead {
        try await run(request, mode: .streaming, sink: onChunk)
    }

    private func run(
        _ request: HTTPRequest, mode: Transfer.Mode, sink: @escaping @Sendable (Data) throws -> Void
    ) async throws(TransportError) -> HTTPResponseHead {
        guard request.url.scheme?.lowercased() == "https" else { throw .insecureScheme }
        guard let host = request.url.host()?.lowercased(), allowedHosts.contains(host),
            request.url.user == nil, request.url.password == nil
        else { throw .hostNotAllowed }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = Double(request.timeout.components.seconds)
        urlRequest.httpShouldHandleCookies = false
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }

        var fileBody: Transfer.FileSource?
        if let bodyFile = request.bodyFile {
            let opened: OpenedFile
            if let existing = bodyFile.opened {
                opened = existing
            } else {
                opened = try OpenedFile.open(bodyFile.file)
            }
            fileBody = Transfer.FileSource(
                prefix: bodyFile.prefix, suffix: bodyFile.suffix, file: opened, identity: opened.identity)
        } else {
            urlRequest.httpBody = request.body
        }

        return try await session.run(
            urlRequest, mode: mode, maxBytes: request.maxResponseBytes, fileSource: fileBody, sink: sink)
    }
}
