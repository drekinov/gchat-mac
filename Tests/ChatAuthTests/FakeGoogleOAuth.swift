import ChatModel
import ChatNet
import CryptoKit
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatAuth

@Suite(.serialized) enum OAuthNetworkTests {}

final class TestClock: Sendable {
    static let start = Timestamp(seconds: 1_800_000_000)

    private let current = Mutex(TestClock.start)

    var now: Timestamp { current.withLock { $0 } }

    func advance(seconds: Int) {
        current.withLock { $0 = $0.adding(.seconds(seconds)) }
    }

    var reader: @Sendable () -> Timestamp { { self.now } }
}

func percentDecodedForm(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let decode = { (raw: Substring) in
            raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(raw)
        }
        result[decode(parts[0])] = parts.count > 1 ? decode(parts[1]) : ""
    }
    return result
}

/// Emulates Google's token, revoke and userinfo endpoints behind a URLProtocol. One instance is active at a time,
/// so suites that use it run serialized.
final class FakeGoogleOAuth: Sendable {
    static let defaultClientID = "1234-fake.apps.googleusercontent.com"
    static let defaultClientSecret = "GOCSPX-fake-secret"
    static let allScopes = (OAuthScopes.required + OAuthScopes.optional).joined(separator: " ")
    static let active = Mutex<FakeGoogleOAuth?>(nil)

    enum Grant: String, Sendable {
        case authorizationCode = "authorization_code"
        case refreshToken = "refresh_token"
    }

    enum Reply: Sendable {
        case oauthError(status: Int = 400, code: String, description: String? = nil)
        case raw(status: Int, body: String)
        case redirect(status: Int = 302, location: String)
        case network(URLError.Code)
    }

    struct Settings: Sendable {
        var rotateRefreshTokens = false
        var scopeOverride: String?
        var omitScopeOnRefresh = false
        var expiresIn = 3600
        var subject = "112233445566778899001"
        var email = "ada@example.com"
        var emailVerified: Bool? = true
        var name: String? = "Ada Lovelace"
    }

    struct Seen: Sendable {
        var method: String
        var host: String
        var path: String
        var headers: [String: String]
        var form: [String: String]
    }

    struct Exchange: Sendable {
        var code: String
        var verifier: String
        var redirectURI: String
    }

    enum AuthorizationRejection: Error, Sendable, Equatable {
        case notGoogle
        case badParameter(String)
    }

    private struct Code {
        var challenge: String
        var redirectURI: String
        var scope: String
        var used = false
    }

    private struct RefreshRecord {
        var scope: String
        var revoked = false
    }

    private struct State {
        var settings = Settings()
        var codes: [String: Code] = [:]
        var refreshTokens: [String: RefreshRecord] = [:]
        var accessTokens: [String: Bool] = [:]
        var seen: [Seen] = []
        var exchanges: [Exchange] = []
        var authorizationURLs: [URL] = []
        var tokenScripts: [(grant: Grant?, reply: Reply)] = []
        var userinfoScripts: [Reply] = []
        var counter = 0
        var holding: Set<String> = []
        var parked: [String: [@Sendable () -> Void]] = [:]
    }

    let clientID: String
    let clientSecret: String
    private let state = Mutex(State())

    init(clientID: String = defaultClientID, clientSecret: String = defaultClientSecret) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        Self.active.withLock { $0 = self }
    }

    var client: OAuthClientConfig { OAuthClientConfig(clientID: clientID, clientSecret: clientSecret) }

    func configure(_ body: (inout Settings) -> Void) {
        state.withLock { body(&$0.settings) }
    }

    func script(_ reply: Reply, for grant: Grant? = nil, times: Int = 1) {
        state.withLock { state in
            for _ in 0..<times { state.tokenScripts.append((grant, reply)) }
        }
    }

    /// Parks responses to `path` until `release(path)`, so a test can act while a request is in flight.
    func hold(_ path: String) {
        state.withLock { _ = $0.holding.insert(path) }
    }

    /// Delivers every parked response to `path` and stops holding new ones.
    func release(_ path: String) {
        let parked = state.withLock { state in
            state.holding.remove(path)
            return state.parked.removeValue(forKey: path) ?? []
        }
        for deliver in parked { deliver() }
    }

    func parkedResponses(_ path: String) -> Int { state.withLock { $0.parked[path]?.count ?? 0 } }

    func holdTokens() { hold("/token") }
    func releaseTokens() { release("/token") }
    var parkedTokenResponses: Int { parkedResponses("/token") }

    func park(path: String, _ deliver: @escaping @Sendable () -> Void) -> Bool {
        state.withLock { state in
            guard state.holding.contains(path) else { return false }
            state.parked[path, default: []].append(deliver)
            return true
        }
    }

    func scriptUserinfo(_ reply: Reply) {
        state.withLock { $0.userinfoScripts.append(reply) }
    }

    @discardableResult
    func seedRefreshToken(_ token: String = "rt-seed", scope: String = FakeGoogleOAuth.allScopes) -> String {
        state.withLock { $0.refreshTokens[token] = RefreshRecord(scope: scope) }
        return token
    }

    func revokeRefreshToken(_ token: String) {
        state.withLock { $0.refreshTokens[token]?.revoked = true }
    }

    func isRevoked(_ token: String) -> Bool {
        state.withLock { $0.refreshTokens[token]?.revoked ?? false }
    }

    var refreshTokensIssued: [String] { state.withLock { Array($0.refreshTokens.keys).sorted() } }
    var seen: [Seen] { state.withLock { $0.seen } }
    var exchanges: [Exchange] { state.withLock { $0.exchanges } }
    var authorizationURLs: [URL] { state.withLock { $0.authorizationURLs } }

    func tokenRequests(_ grant: Grant? = nil) -> [Seen] {
        seen.filter { $0.path == "/token" && (grant == nil || $0.form["grant_type"] == grant?.rawValue) }
    }

    var revokeRequests: [Seen] { seen.filter { $0.path == "/revoke" } }
    var userinfoRequests: [Seen] { seen.filter { $0.path == "/v1/userinfo" } }

    func issueCode(for url: URL) -> Result<String, AuthorizationRejection> {
        guard url.scheme == "https", url.host() == "accounts.google.com", url.path == "/o/oauth2/v2/auth" else {
            return .failure(.notGoogle)
        }
        var params: [String: String] = [:]
        let rawQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        params = percentDecodedForm(rawQuery)
        for name in ["client_id", "redirect_uri", "response_type", "scope", "state", "code_challenge"] {
            guard let value = params[name], !value.isEmpty else { return .failure(.badParameter(name)) }
        }
        guard params["client_id"] == clientID else { return .failure(.badParameter("client_id")) }
        guard params["response_type"] == "code" else { return .failure(.badParameter("response_type")) }
        guard params["code_challenge_method"] == "S256" else { return .failure(.badParameter("code_challenge_method")) }
        guard let redirect = URL(string: params["redirect_uri"]!), redirect.scheme == "http",
            redirect.host() == "127.0.0.1", redirect.port != nil
        else { return .failure(.badParameter("redirect_uri")) }

        return .success(
            state.withLock { state in
                state.authorizationURLs.append(url)
                state.counter += 1
                let code = "code-\(state.counter)"
                state.codes[code] = Code(
                    challenge: params["code_challenge"]!, redirectURI: params["redirect_uri"]!,
                    scope: params["scope"]!)
                return code
            })
    }

    struct Planned: Sendable {
        enum Outcome: Sendable {
            case http(status: Int, headers: [String: String], body: Data)
            case failure(URLError.Code)
        }
        var outcome: Outcome
    }

    func handle(method: String, url: URL, headers: [String: String], body: Data) -> Planned {
        let form = percentDecodedForm(String(decoding: body, as: UTF8.self))
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        let host = url.host()?.lowercased() ?? ""
        return state.withLock { state in
            state.seen.append(Seen(method: method, host: host, path: url.path, headers: lowered, form: form))
            switch (method, host, url.path) {
            case ("POST", "oauth2.googleapis.com", "/token"):
                return Planned(outcome: Self.token(&state, form: form, clientID: clientID, secret: clientSecret))
            case ("POST", "oauth2.googleapis.com", "/revoke"):
                return Planned(outcome: Self.revoke(&state, form: form))
            case ("GET", "openidconnect.googleapis.com", "/v1/userinfo"):
                return Planned(outcome: Self.userinfo(&state, headers: lowered))
            default:
                return Planned(outcome: Self.json(404, ["error": "not_found"]))
            }
        }
    }

    private static func json(_ status: Int, _ object: [String: Any]) -> Planned.Outcome {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .http(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    private static func apply(_ reply: Reply) -> Planned.Outcome {
        switch reply {
        case .oauthError(let status, let code, let description):
            var object: [String: Any] = ["error": code]
            if let description { object["error_description"] = description }
            return json(status, object)
        case .raw(let status, let body):
            return .http(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        case .redirect(let status, let location):
            return .http(status: status, headers: ["Location": location], body: Data())
        case .network(let code):
            return .failure(code)
        }
    }

    private static func error(_ code: String, _ description: String, status: Int = 400) -> Planned.Outcome {
        json(status, ["error": code, "error_description": description])
    }

    private static func token(_ state: inout State, form: [String: String], clientID: String, secret: String)
        -> Planned.Outcome
    {
        let grant = form["grant_type"].flatMap(Grant.init(rawValue:))
        if let index = state.tokenScripts.firstIndex(where: { $0.grant == nil || $0.grant == grant }) {
            return apply(state.tokenScripts.remove(at: index).reply)
        }
        guard form["client_id"] == clientID, form["client_secret"] == secret else {
            return error("invalid_client", "The OAuth client was not found.", status: 401)
        }
        let settings = state.settings
        switch grant {
        case .authorizationCode:
            guard let code = form["code"], let record = state.codes[code], !record.used else {
                return error("invalid_grant", "Bad Request")
            }
            state.exchanges.append(
                Exchange(code: code, verifier: form["code_verifier"] ?? "", redirectURI: form["redirect_uri"] ?? ""))
            guard let verifier = form["code_verifier"],
                Self.challenge(for: verifier) == record.challenge
            else { return error("invalid_grant", "Invalid code verifier.") }
            guard form["redirect_uri"] == record.redirectURI else {
                return error("redirect_uri_mismatch", "Bad Request")
            }
            state.codes[code]?.used = true
            state.counter += 1
            let refresh = "rt-\(state.counter)"
            let access = "at-\(state.counter)"
            let scope = settings.scopeOverride ?? record.scope
            state.refreshTokens[refresh] = RefreshRecord(scope: scope)
            state.accessTokens[access] = true
            return json(
                200,
                [
                    "access_token": access, "expires_in": settings.expiresIn, "refresh_token": refresh,
                    "scope": scope, "token_type": "Bearer",
                ])
        case .refreshToken:
            guard let token = form["refresh_token"], let record = state.refreshTokens[token], !record.revoked else {
                return error("invalid_grant", "Token has been expired or revoked.")
            }
            state.counter += 1
            let access = "at-\(state.counter)"
            state.accessTokens[access] = true
            let scope = settings.scopeOverride ?? record.scope
            var object: [String: Any] = [
                "access_token": access, "expires_in": settings.expiresIn, "scope": scope, "token_type": "Bearer",
            ]
            if settings.omitScopeOnRefresh { object["scope"] = nil }
            if settings.rotateRefreshTokens {
                let rotated = "rt-\(state.counter)"
                state.refreshTokens[token]?.revoked = true
                state.refreshTokens[rotated] = RefreshRecord(scope: record.scope)
                object["refresh_token"] = rotated
            }
            return json(200, object)
        case nil:
            return error("unsupported_grant_type", "Invalid grant_type")
        }
    }

    private static func revoke(_ state: inout State, form: [String: String]) -> Planned.Outcome {
        guard let token = form["token"], state.refreshTokens[token] != nil || state.accessTokens[token] != nil else {
            return error("invalid_token", "Token expired or revoked")
        }
        if state.refreshTokens[token] != nil { state.refreshTokens[token]?.revoked = true }
        if state.accessTokens[token] != nil { state.accessTokens[token] = false }
        return json(200, [:])
    }

    private static func userinfo(_ state: inout State, headers: [String: String]) -> Planned.Outcome {
        if !state.userinfoScripts.isEmpty { return apply(state.userinfoScripts.removeFirst()) }
        guard let auth = headers["authorization"], auth.hasPrefix("Bearer "),
            state.accessTokens[String(auth.dropFirst(7))] == true
        else { return json(401, ["error": ["status": "UNAUTHENTICATED"]]) }
        let settings = state.settings
        var object: [String: Any] = ["sub": settings.subject, "email": settings.email]
        if let verified = settings.emailVerified { object["email_verified"] = verified }
        if let name = settings.name { object["name"] = name }
        return json(200, object)
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class FakeGoogleOAuthProtocol: URLProtocol, @unchecked Sendable {
    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fake = FakeGoogleOAuth.active.withLock({ $0 }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let plan = fake.handle(
            method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request))
        let deliver: @Sendable () -> Void = { [self] in
            guard !stopped.withLock({ $0 }) else { return }
            switch plan.outcome {
            case .failure(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            case .http(let status, let headers, let body):
                let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        if fake.park(path: url.path, deliver) { return }
        deliver()
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

struct OAuthHarness {
    let fake: FakeGoogleOAuth
    let clock: TestClock
    let transport: AuthTransport
    let endpoints: OAuthEndpoints

    init(fake: FakeGoogleOAuth = FakeGoogleOAuth(), clock: TestClock = TestClock()) {
        self.fake = fake
        self.clock = clock
        transport = AuthTransport(
            allowedHosts: AuthTransport.googleHosts, protocolClasses: [FakeGoogleOAuthProtocol.self])
        var endpoints = OAuthEndpoints(transport: transport, client: fake.client, clock: clock.reader)
        endpoints.sleep = Self.untilCancelled
        self.endpoints = endpoints
    }

    /// A revoke deadline that never arrives, so the fake's answer is the only thing that ends a revoke.
    static let untilCancelled: @Sendable (Duration) async throws -> Void = { _ in try await Gate().wait() }
}

final class TestBrowser: BrowserOpener {
    enum Behavior: Sendable {
        case approve
        case deny(String)
        case wrongState
        case missingCode
        case duplicateState
        case neverRedirect
        case redirectTwice
        case openFails
        /// A local attacker's forged callback (wrong state, then a forged denial) arrives before Google's real one.
        case forgedFirst
    }

    private struct State {
        var urls: [URL] = []
        var rejections: [FakeGoogleOAuth.AuthorizationRejection] = []
        var results: [Int?] = []
        var tasks: [Task<Void, Never>] = []
    }

    let fake: FakeGoogleOAuth
    let behavior: Behavior
    private let state = Mutex(State())
    private let session: URLSession

    init(fake: FakeGoogleOAuth, behavior: Behavior = .approve) {
        self.fake = fake
        self.behavior = behavior
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(hangGuard.components.seconds)
        session = URLSession(configuration: configuration)
    }

    var urls: [URL] { state.withLock { $0.urls } }
    var rejections: [FakeGoogleOAuth.AuthorizationRejection] { state.withLock { $0.rejections } }
    var redirectStatuses: [Int?] { state.withLock { $0.results } }

    func settle() async {
        let tasks = state.withLock { $0.tasks }
        for task in tasks { await task.value }
    }

    func open(_ url: URL) async -> Bool {
        state.withLock { $0.urls.append(url) }
        switch behavior {
        case .openFails: return false
        case .neverRedirect: return true
        default: break
        }
        let rawQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        let params = percentDecodedForm(rawQuery)
        guard let redirect = params["redirect_uri"], let state = params["state"] else { return true }

        var query: [String]
        let encode = { (value: String) in
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }
        if case .deny(let reason) = behavior {
            query = ["error=\(encode(reason))", "state=\(encode(state))"]
        } else {
            switch fake.issueCode(for: url) {
            case .failure(let rejection):
                self.state.withLock { $0.rejections.append(rejection) }
                return true
            case .success(let code):
                let sent: String
                if case .wrongState = behavior { sent = "forged-state" } else { sent = state }
                query = ["code=\(encode(code))", "state=\(encode(sent))"]
                if case .missingCode = behavior { query = ["state=\(encode(sent))"] }
                if case .duplicateState = behavior { query.append("state=\(encode(sent))") }
            }
        }
        guard let callback = URL(string: "\(redirect)?\(query.joined(separator: "&"))") else { return true }
        let repeats: Int
        if case .redirectTwice = behavior { repeats = 2 } else { repeats = 1 }
        let forged: [URL]
        if case .forgedFirst = behavior {
            forged = [
                URL(string: "\(redirect)?code=attacker&state=forged")!,
                URL(string: "\(redirect)?error=access_denied&state=forged")!,
                URL(string: "\(redirect)?error=access_denied")!,
            ]
        } else {
            forged = []
        }
        let task = Task { [session, self] in
            for url in forged {
                let status = try? await session.data(from: url).1 as? HTTPURLResponse
                self.state.withLock { $0.results.append(status?.statusCode) }
            }
            for _ in 0..<repeats {
                let status = try? await session.data(from: callback).1 as? HTTPURLResponse
                self.state.withLock { $0.results.append(status?.statusCode) }
            }
        }
        self.state.withLock { $0.tasks.append(task) }
        return true
    }
}

/// What `operation` returned or threw, from its own task. One that never ends is recorded as an issue and
/// reported as cancelled, so a flow that loses its callback fails its test instead of hanging it.
func settle<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws(AuthError) -> Value
) async -> Result<Value, AuthError> {
    let run = Recorded { () async -> Result<Value, AuthError> in
        do throws(AuthError) { return .success(try await operation()) } catch { return .failure(error) }
    }
    defer { run.cancel() }
    if let result = await run.settled() { return result }
    Issue.record("the operation never finished")
    return .failure(.cancelled)
}

func runSignIn(_ flow: SignInFlow, loginHint: String? = nil) async -> Result<SignInResult, AuthError> {
    await settle { () async throws(AuthError) in try await flow.run(loginHint: loginHint) }
}

func fetchToken(_ provider: OAuthTokenProvider) async -> Result<String, ChatAPIError> {
    do { return .success(try await provider.accessToken()) } catch { return .failure(error) }
}
