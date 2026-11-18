import ChatKeychain
import ChatModel
import Foundation

/// What survives a restart for one account. The access token is never persisted.
public struct StoredCredentials: Hashable, Sendable, Codable {
    public var client: OAuthClientConfig
    public var refreshToken: String
    public var grantedScope: String
    public var identity: Identity

    public struct Identity: Hashable, Sendable, Codable {
        public var subject: String
        public var email: String
        public var name: String?
    }

    public init(client: OAuthClientConfig, refreshToken: String, grantedScope: String, identity: Identity) {
        self.client = client
        self.refreshToken = refreshToken
        self.grantedScope = grantedScope
        self.identity = identity
    }

    /// Scopes changed since login (an app upgrade asking for more) mean the user must sign in again.
    public var needsReconsent: Bool { !OAuthScopes.missing(from: grantedScope).isEmpty }
}

/// One keychain item per account. Writes go through the session gate, so a retired session can't put back a
/// token that logout just deleted.
public struct CredentialVault: Sendable {
    let secrets: any SecretStore

    public init(secrets: any SecretStore) { self.secrets = secrets }

    public static func secretID(for account: AccountID) -> SecretID {
        SecretID(service: "io.github.drekinov.gchat-mac.credentials", account: account.description)
    }

    public func load(_ account: AccountID) throws(AuthError) -> StoredCredentials? {
        let data: Data?
        do { data = try secrets.read(Self.secretID(for: account)) } catch { throw .vault(String(describing: error)) }
        guard let data else { return nil }
        guard let credentials = try? JSONDecoder().decode(StoredCredentials.self, from: data) else {
            throw .vault("corrupt")
        }
        return credentials
    }

    public func save(
        _ credentials: StoredCredentials, for account: AccountID, gate: SessionGate, generation: Generation
    ) throws(AuthError) {
        guard let data = try? JSONEncoder().encode(credentials) else { throw .vault("encode") }
        do {
            try gate.commit(generation) { () throws(SecretStoreError) in
                try secrets.write(data, for: Self.secretID(for: account))
            }
        } catch is GateClosed {
            throw .retired
        } catch {
            throw .vault(String(describing: error))
        }
    }

    /// Used only before a session exists (first login), where there's no gate to commit through yet.
    public func saveInitial(_ credentials: StoredCredentials, for account: AccountID) throws(AuthError) {
        guard let data = try? JSONEncoder().encode(credentials) else { throw .vault("encode") }
        do { try secrets.write(data, for: Self.secretID(for: account)) } catch {
            throw .vault(String(describing: error))
        }
    }

    public func delete(_ account: AccountID) throws(AuthError) {
        do { try secrets.delete(Self.secretID(for: account)) } catch { throw .vault(String(describing: error)) }
    }
}

extension StoredCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "StoredCredentials(scope: \(grantedScope.split(separator: " ").count) scopes)" }
    public var debugDescription: String { description }
}
