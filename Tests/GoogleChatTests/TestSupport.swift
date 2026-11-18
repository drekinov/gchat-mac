import ChatModel
import ChatNet
import Foundation
import Synchronization

@testable import GoogleChat

final class StubTransport: HTTPTransport, Sendable {
    private struct State {
        var requests: [HTTPRequest] = []
        var responses: [Result<HTTPResponse, TransportError>] = []
    }

    private let state = Mutex(State())

    init(_ responses: [Result<HTTPResponse, TransportError>]) {
        state.withLock { $0.responses = responses }
    }

    convenience init(status: Int = 200, headers: [String: String] = [:], body: Data = Data("{}".utf8)) {
        self.init([.success(HTTPResponse(status: status, headers: headers, body: body))])
    }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }

    func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse {
        let next = state.withLock { state -> Result<HTTPResponse, TransportError> in
            state.requests.append(request)
            return state.responses.count > 1
                ? state.responses.removeFirst() : (state.responses.first ?? .success(.init(status: 500)))
        }
        return try next.get()
    }
}

final class StubTokens: TokenProvider, Sendable {
    private struct State {
        var generation = 1
        var invalidated: [String] = []
    }

    private let state = Mutex(State())
    private let failing: Bool

    init(failing: Bool = false) { self.failing = failing }

    var invalidated: [String] { state.withLock { $0.invalidated } }

    func accessToken() async throws(ChatAPIError) -> String {
        if failing { throw .noCredentials }
        return state.withLock { "token-\($0.generation)" }
    }

    func invalidate(_ token: String) async {
        state.withLock {
            $0.invalidated.append(token)
            if token == "token-\($0.generation)" { $0.generation += 1 }
        }
    }
}

func fixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
}

func makeClient(
    _ transport: StubTransport, tokens: StubTokens = StubTokens()
) -> GoogleChatClient {
    GoogleChatClient(transport: transport, tokens: tokens, baseURL: URL(string: "https://chat.test")!)
}

func clientServing(_ fixtureName: String, status: Int = 200) -> (GoogleChatClient, StubTransport) {
    let transport = StubTransport(status: status, body: fixture(fixtureName))
    return (makeClient(transport), transport)
}

func queryItems(_ request: HTTPRequest) -> [String: String] {
    let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

func queryNames(_ request: HTTPRequest) -> [String] {
    (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
}

func bodyString(_ request: HTTPRequest) -> String? {
    request.body.flatMap { String(data: $0, encoding: .utf8) }
}

func thrownError<T>(_ body: () async throws -> T) async -> ChatAPIError? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error as? ChatAPIError
    }
}

func ts(_ text: String) -> Timestamp { Timestamp(rfc3339: text)! }
let testSpace = SpaceName(unchecked: "spaces/AAAA")
