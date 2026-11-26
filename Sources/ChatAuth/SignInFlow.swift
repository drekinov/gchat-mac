import ChatModel
import Foundation

public protocol BrowserOpener: Sendable {
    /// Opens `url` in the user's default browser; `false` if nothing could open it.
    func open(_ url: URL) async -> Bool
}

public struct SignInResult: Sendable, Equatable {
    public var credentials: StoredCredentials
    public var grant: TokenGrant
}

/// The loopback + PKCE authorization-code flow for one Google account.
public struct SignInFlow: Sendable {
    public static let defaultTimeout = Duration.seconds(300)

    let endpoints: OAuthEndpoints
    let browser: any BrowserOpener
    let timeout: Duration
    /// Waits out `timeout`, throwing when cancelled; a test seam.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Replaces the listener's header deadline; a test seam.
    var headerTimer: LoopbackListener.HeaderTimer?

    public init(endpoints: OAuthEndpoints, browser: any BrowserOpener, timeout: Duration = defaultTimeout) {
        self.endpoints = endpoints
        self.browser = browser
        self.timeout = timeout
    }

    /// Opens the browser, waits for the single redirect, checks `state`, exchanges the code, verifies the granted
    /// scopes and fetches the user's identity. Cancelling the calling task cancels the flow. `extraScopes` are
    /// requested and required on top of the regular set.
    public func run(
        loginHint: String? = nil, reconnecting account: UserName? = nil, extraScopes: [String] = []
    ) async throws(AuthError) -> SignInResult {
        let pkce = PKCE()
        let listener: LoopbackListener
        do {
            listener = try await LoopbackListener.start(expectedState: pkce.state, headerTimer: headerTimer)
        } catch {
            throw .transport("loopback")
        }
        defer { listener.cancel() }

        let url = endpoints.authorizationURL(
            pkce: pkce, redirectURI: listener.redirectURI, loginHint: loginHint, extraScopes: extraScopes)
        guard await browser.open(url) else { throw .browserUnavailable }

        let components: URLComponents
        do {
            components = try await listener.callback(timeout: timeout, sleep: sleep)
        } catch .timedOut {
            throw .timedOut
        } catch {
            throw .cancelled
        }

        let query = try Self.singleValued(components.queryItems ?? [])
        // State first, so a forged callback can't even report a denial.
        guard let state = query["state"], pkce.matches(state: state) else { throw .stateMismatch }
        if let error = query["error"] { throw .authorizationDenied(OAuthEndpoints.errorCode(error)) }
        guard let code = query["code"], !code.isEmpty, code.utf8.count < 2048 else { throw .missingCode }

        let grant = try await endpoints.exchange(code: code, pkce: pkce, redirectURI: listener.redirectURI)
        let scope = grant.scope ?? ""
        let missing = OAuthScopes.missing(from: scope, also: extraScopes)
        guard missing.isEmpty else {
            if account == nil, let refresh = grant.refreshToken { await endpoints.revoke(refresh) }
            throw .insufficientScopes(missing: missing)
        }
        let identity = try await endpoints.userinfo(accessToken: grant.accessToken)
        if let account, identity.chatUser != account { throw .wrongAccount }
        let credentials = StoredCredentials(
            client: endpoints.client, refreshToken: grant.refreshToken!, grantedScope: scope,
            identity: .init(subject: identity.subject, email: identity.email, name: identity.name))
        return SignInResult(credentials: credentials, grant: grant)
    }

    /// A fresh consent for the existing `account` that adds the Pub/Sub scope. It returns credentials only when
    /// Google answered for that same account and granted every regular scope plus Pub/Sub; the caller's stored
    /// credentials are untouched otherwise.
    public func grantLiveNotifications(account: UserName, loginHint: String?) async throws(AuthError)
        -> SignInResult
    {
        let result = try await run(loginHint: loginHint, reconnecting: account, extraScopes: [OAuthScopes.pubsub])
        guard UserName("users/\(result.credentials.identity.subject)") == account else { throw .wrongAccount }
        guard OAuthScopes.hasPubSub(result.credentials.grantedScope) else {
            throw .insufficientScopes(missing: [OAuthScopes.pubsub])
        }
        return result
    }

    /// A parameter that appears twice is treated as tampering.
    static func singleValued(_ items: [URLQueryItem]) throws(AuthError) -> [String: String] {
        var result: [String: String] = [:]
        for item in items {
            guard result[item.name] == nil else { throw .stateMismatch }
            result[item.name] = item.value ?? ""
        }
        return result
    }
}

extension SignInResult: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "SignInResult(\(credentials), \(grant))" }
    public var debugDescription: String { description }
}
