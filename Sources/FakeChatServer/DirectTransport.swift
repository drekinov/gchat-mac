import ChatNet
import Foundation

/// Serves each request on the caller's own thread, with no URL loading system between the client and the fake, so
/// requests are answered in the order they are issued.
package struct DirectTransport: HTTPTransport {
    let allowedHosts: Set<String>

    package func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse {
        guard request.url.scheme?.lowercased() == "https" else { throw .insecureScheme }
        guard let host = request.url.host()?.lowercased(), allowedHosts.contains(host), request.url.user == nil,
            request.url.password == nil
        else { throw .hostNotAllowed }
        precondition(request.bodyFile == nil, "DirectTransport carries no file bodies")
        // A request is a suspension point for its caller, as it is over the network.
        await Task.yield()
        guard !Task.isCancelled else { throw .cancelled }
        let incoming = IncomingRequest(
            method: request.method.rawValue, host: host, path: request.url.path,
            query: URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [],
            headers: request.headers, body: request.body)
        switch FakeChatServer.serve(incoming) {
        case .reply(let reply):
            if (300..<400).contains(reply.status) {
                let location = reply.headers.first { $0.key.lowercased() == "location" }?.value
                throw .redirected(status: reply.status, location: location.flatMap { URL(string: $0) })
            }
            guard reply.body.count <= request.maxResponseBytes else { throw .responseTooLarge }
            return HTTPResponse(status: reply.status, headers: reply.headers, body: reply.body)
        case .networkError(let code):
            throw TransportError(URLError(code))
        }
    }
}

extension FakeChatServer {
    /// The same hosts as `makeTransport()`, answered without URLSession.
    package func makeDirectTransport() -> DirectTransport {
        DirectTransport(allowedHosts: [
            "chat.googleapis.com", Endpoint.directoryHost, Endpoint.workspaceEventsHost, Endpoint.pubSubHost,
        ])
    }
}
