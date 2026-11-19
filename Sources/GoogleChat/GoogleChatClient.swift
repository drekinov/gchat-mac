import ChatModel
import ChatNet
import Foundation

/// The real REST client. In development it's pointed at `FakeChatServer` through the same transport type.
public struct GoogleChatClient: Sendable {
    public static let productionBaseURL = URL(string: "https://chat.googleapis.com")!

    let baseURL: URL
    let transport: any HTTPTransport
    let tokens: any TokenProvider

    public init(transport: any HTTPTransport, tokens: any TokenProvider, baseURL: URL = productionBaseURL) {
        self.transport = transport
        self.tokens = tokens
        self.baseURL = baseURL
    }

    /// Builds `baseURL` + `path` + query. `path` segments come from validated resource names only.
    func url(_ path: String, query: [URLQueryItem] = [], base: URL? = nil) -> URL {
        var components = URLComponents(url: base ?? baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if !query.isEmpty {
            components.percentEncodedQueryItems = query.map {
                URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: .queryValue))
            }
        }
        return components.url!
    }

    /// Sends with the bearer token, refreshing once on 401, and decodes `Response` from a 2xx body.
    func send<Response: Decodable>(
        _ method: HTTPMethod, _ url: URL, timeout: Duration? = nil, as _: Response.Type = Response.self
    ) async throws(ChatAPIError) -> Response {
        let response = try await authorized(method, url, body: nil, timeout: timeout)
        return try Self.decode(Response.self, from: response.body)
    }

    func send<Body: Encodable, Response: Decodable>(
        _ method: HTTPMethod, _ url: URL, body: Body, timeout: Duration? = nil, as _: Response.Type = Response.self
    ) async throws(ChatAPIError) -> Response {
        let encoded: Data
        do {
            encoded = try JSONEncoder.chat.encode(body)
        } catch {
            throw .decoding(path: "request")
        }
        let response = try await authorized(method, url, body: encoded, timeout: timeout)
        return try Self.decode(Response.self, from: response.body)
    }

    func authorized(
        _ method: HTTPMethod, _ url: URL, body: Data?, timeout: Duration? = nil
    ) async throws(ChatAPIError) -> HTTPResponse {
        var refreshed = false
        while true {
            let token = try await tokens.accessToken()
            var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
            if body != nil { headers["Content-Type"] = "application/json; charset=utf-8" }
            let response: HTTPResponse
            do {
                var request = HTTPRequest(method: method, url: url, headers: headers, body: body)
                if let timeout { request.timeout = timeout }
                response = try await transport.send(request)
            } catch .redirected(let status, _) {
                throw .transport(.redirected(status: status, location: nil))
            } catch {
                throw .transport(error)
            }
            if (200..<300).contains(response.status) { return response }
            if response.status == 401, !refreshed {
                refreshed = true
                await tokens.invalidate(token)
                continue
            }
            throw ChatAPIError(status: response.status, headers: response.headers, body: response.body)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(ChatAPIError) -> T {
        do {
            return try JSONDecoder.chat.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
        } catch let DecodingError.dataCorrupted(context),
            let DecodingError.keyNotFound(_, context),
            let DecodingError.typeMismatch(_, context),
            let DecodingError.valueNotFound(_, context)
        {
            throw .decoding(path: context.codingPath.map(\.stringValue).joined(separator: "."))
        } catch {
            throw .decoding(path: "")
        }
    }
}

struct Empty: Codable, Sendable {}

extension JSONDecoder {
    static let chat = JSONDecoder()
}

extension JSONEncoder {
    static let chat: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

extension CharacterSet {
    /// RFC 3986 unreserved characters; everything else in a query value is percent-encoded.
    static let queryValue = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
