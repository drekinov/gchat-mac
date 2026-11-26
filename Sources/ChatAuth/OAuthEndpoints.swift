import ChatModel
import ChatNet
import Foundation
import Synchronization

public struct TokenGrant: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Timestamp
    /// Present on the initial exchange; refreshes usually omit it, keeping the stored one.
    public var refreshToken: String?
    /// `nil` when the response omitted `scope`; an explicit empty string means no scopes were granted.
    public var scope: String?
}

public struct UserIdentity: Sendable, Equatable {
    /// The OpenID subject, which is also the Chat user ID (`users/{sub}`).
    public var subject: String
    public var email: String
    public var name: String?

    public var chatUser: UserName? { UserName("users/\(subject)") }
}

/// Google's OAuth endpoints over the redirect-refusing transport. Bodies are form-encoded; responses never end up
/// in errors beyond the OAuth error code.
public struct OAuthEndpoints: Sendable {
    let transport: any HTTPTransport
    let client: OAuthClientConfig
    let clock: @Sendable () -> Timestamp
    let revokeDeadline: Duration
    /// Waits out the revoke deadline; a test seam.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Reports which side ended a revoke; a test seam.
    var onRevokeOutcome: @Sendable (RevokeOutcome) -> Void = { _ in }

    enum RevokeOutcome: Sendable, Equatable {
        case response, deadline
    }

    public init(
        transport: any HTTPTransport, client: OAuthClientConfig,
        clock: @escaping @Sendable () -> Timestamp = { Timestamp(Date()) },
        revokeDeadline: Duration = OAuthEndpoints.revokeDeadline
    ) {
        self.transport = transport
        self.client = client
        self.clock = clock
        self.revokeDeadline = revokeDeadline
    }

    /// Always a fresh consent for the whole set (`include_granted_scopes=false`): desktop clients get no
    /// incremental authorization, so `extraScopes` are asked for alongside every regular scope.
    public func authorizationURL(pkce: PKCE, redirectURI: URL, loginHint: String?, extraScopes: [String] = []) -> URL {
        var components = URLComponents(url: OAuthClientConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(
                name: "scope", value: (OAuthScopes.required + OAuthScopes.optional + extraScopes).joined(separator: " ")
            ),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "include_granted_scopes", value: "false"),
        ]
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        // Encoded by hand: URLComponents leaves "+" bare, which Google decodes as a space.
        components.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        return components.url!
    }

    public func exchange(code: String, pkce: PKCE, redirectURI: URL) async throws(AuthError) -> TokenGrant {
        let grant = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "code_verifier": pkce.verifier,
            "redirect_uri": redirectURI.absoluteString, "client_id": client.clientID,
            "client_secret": client.clientSecret,
        ])
        guard grant.refreshToken != nil else { throw .malformedResponse("refresh_token") }
        return grant
    }

    public func refresh(_ refreshToken: String) async throws(AuthError) -> TokenGrant {
        try await tokenRequest([
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": client.clientID,
            "client_secret": client.clientSecret,
        ])
    }

    public static let revokeDeadline = Duration.seconds(5)

    /// Best effort within an absolute deadline (a trickling response can't stretch it); revocation never blocks
    /// local cleanup.
    public func revoke(_ token: String) async {
        let request = HTTPRequest(
            method: .post, url: OAuthClientConfig.revokeEndpoint,
            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Self.form(["token": token]),
            timeout: Self.revokeDeadline, maxResponseBytes: 64 * 1024)
        let transport = transport
        let deadline = revokeDeadline
        let sleep = sleep
        let report = onRevokeOutcome
        // Unstructured, so a transport that ignores cancellation can't hold revoke past the deadline.
        let send = Task { _ = try? await transport.send(request) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = RevokeOnce()
            // The timer claims the race the moment its sleep ends, with no hop in which a late response could win.
            let timer = Task {
                do { try await sleep(deadline) } catch { return }
                if once.claim() {
                    report(.deadline)
                    continuation.resume()
                }
            }
            Task {
                await send.value
                guard once.claim() else { return }
                timer.cancel()
                report(.response)
                continuation.resume()
            }
        }
        send.cancel()
    }

    public func userinfo(accessToken: String) async throws(AuthError) -> UserIdentity {
        struct Body: Decodable {
            var sub: String?
            var email: String?
            var emailVerified: Bool?
            var name: String?
        }
        let request = HTTPRequest(
            url: OAuthClientConfig.userinfoEndpoint,
            headers: ["Authorization": "Bearer \(accessToken)", "Accept": "application/json"], timeout: .seconds(15),
            maxResponseBytes: 64 * 1024)
        let response = try await send(request)
        guard response.status == 200 else { throw .tokenEndpoint(status: response.status, code: nil) }
        guard let body = try? Self.decoder.decode(Body.self, from: response.body), let sub = body.sub,
            !sub.isEmpty, sub.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            let email = body.email, body.emailVerified != false
        else { throw .malformedResponse("userinfo") }
        return UserIdentity(subject: sub, email: email, name: body.name)
    }

    func tokenRequest(_ fields: [String: String]) async throws(AuthError) -> TokenGrant {
        struct Body: Decodable {
            var accessToken: String?
            var expiresIn: Int?
            var refreshToken: String?
            var scope: String?
            var tokenType: String?
            var error: String?
        }
        let request = HTTPRequest(
            method: .post, url: OAuthClientConfig.tokenEndpoint,
            headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
            body: Self.form(fields), timeout: .seconds(20), maxResponseBytes: 64 * 1024)
        let started = clock()
        let response = try await send(request)
        let body = try? Self.decoder.decode(Body.self, from: response.body)
        guard response.status == 200 else {
            throw .tokenEndpoint(status: response.status, code: body?.error.map(Self.errorCode))
        }
        guard let body, let access = body.accessToken, !access.isEmpty, body.tokenType?.lowercased() == "bearer",
            let expiresIn = body.expiresIn, expiresIn > 0
        else { throw .malformedResponse("token") }
        // Expiry counts from when the request started, minus a margin, so a slow response can't extend it.
        let lifetime = max(0, expiresIn - 60)
        return TokenGrant(
            accessToken: access, expiresAt: started.adding(.seconds(lifetime)), refreshToken: body.refreshToken,
            scope: body.scope)
    }

    func send(_ request: HTTPRequest) async throws(AuthError) -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch .redirected(let status, _) {
            throw .transport("redirected\(status)")
        } catch {
            throw .transport(String(describing: error))
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func errorCode(_ raw: String) -> String {
        String(raw.unicodeScalars.prefix(40).filter { ("a"..."z").contains($0) || $0 == "_" }.map(Character.init))
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

extension TokenGrant: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "TokenGrant(expires: \(expiresAt), refresh: \(refreshToken != nil))" }
    public var debugDescription: String { description }
}

private final class RevokeOnce: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}
