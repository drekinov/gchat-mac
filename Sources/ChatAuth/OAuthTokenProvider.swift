import ChatModel
import ChatNet
import Foundation
import GoogleChat

/// Access tokens for one account session: cached in memory, refreshed at most once at a time, and dropped for good
/// once Google says the grant is gone (the account then needs a new login).
public actor OAuthTokenProvider: TokenProvider {
    let account: AccountID
    let endpoints: OAuthEndpoints
    let vault: CredentialVault
    let gate: SessionGate
    let generation: Generation?
    let clock: @Sendable () -> Timestamp

    var credentials: StoredCredentials
    var access: (token: String, expires: Timestamp)?
    /// The single in-flight refresh. Its result is applied exactly once, inside the task, before it is cleared.
    var refreshing: Task<String, any Error>?
    var revoked = false

    public init(
        account: AccountID, credentials: StoredCredentials, endpoints: OAuthEndpoints, vault: CredentialVault,
        gate: SessionGate, clock: @escaping @Sendable () -> Timestamp = { Timestamp(Date()) }
    ) {
        self.account = account
        self.credentials = credentials
        self.endpoints = endpoints
        self.vault = vault
        self.gate = gate
        generation = gate.current
        self.clock = clock
    }

    /// Seeds the cache with the token from a fresh login, saving one refresh.
    public func prime(_ grant: TokenGrant) {
        access = (grant.accessToken, grant.expiresAt)
    }

    public func accessToken() async throws(ChatAPIError) -> String {
        guard let generation, gate.isCurrent(generation), !revoked, !credentials.needsReconsent else {
            throw .noCredentials
        }
        if let access, access.expires > clock() { return access.token }
        let task = refreshing ?? startRefresh()
        do {
            return try await task.value
        } catch let error as ChatAPIError {
            throw error
        } catch {
            throw .transport(.connectionLost)
        }
    }

    func startRefresh() -> Task<String, any Error> {
        let endpoints = endpoints
        let refreshToken = credentials.refreshToken
        let task = Task { [self] () async throws -> String in
            let outcome: Result<TokenGrant, AuthError>
            do {
                outcome = .success(try await endpoints.refresh(refreshToken))
            } catch let error as AuthError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.transport("refresh"))
            }
            return try await apply(outcome)
        }
        refreshing = task
        return task
    }

    /// Runs once per refresh, so a slow waiter can't overwrite a newer refresh's tokens.
    func apply(_ outcome: Result<TokenGrant, AuthError>) throws(ChatAPIError) -> String {
        refreshing = nil
        guard let generation, gate.isCurrent(generation) else { throw .noCredentials }
        let grant: TokenGrant
        switch outcome {
        case .failure(.tokenEndpoint(let status, _)) where (400...401).contains(status):
            // Any 400/401 from the token endpoint is permanent (bad grant or client); retrying can't fix it.
            revoked = true
            throw .noCredentials
        case .failure:
            throw .transport(.connectionLost)
        case .success(let value):
            grant = value
        }

        var updated = credentials
        if let rotated = grant.refreshToken { updated.refreshToken = rotated }
        // Google omits `scope` on some refreshes; an explicit one, even empty, replaces the stored grant.
        if let scope = grant.scope { updated.grantedScope = scope }
        if updated != credentials {
            // A failed save keeps the new values in memory; the old refresh token stays valid until Google revokes it.
            _ = try? vault.save(updated, for: account, gate: gate, generation: generation)
            credentials = updated
        }
        guard !credentials.needsReconsent else {
            access = nil
            throw .noCredentials
        }
        access = (grant.accessToken, grant.expiresAt)
        return grant.accessToken
    }

    /// Required scopes are missing (after a refresh, or since an upgrade): the account needs a new login.
    public var needsReconsent: Bool { credentials.needsReconsent }

    public func invalidate(_ token: String) async {
        if access?.token == token { access = nil }
    }

    /// For logout: captured before the vault entry is deleted, so revocation can still run afterwards.
    public var refreshToken: String { credentials.refreshToken }

    public var isRevoked: Bool { revoked }
}
