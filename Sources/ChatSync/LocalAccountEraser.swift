import ChatAuth
import ChatKeychain
import ChatModel
import ChatStore
import Foundation

/// The production eraser: account files under `root`, the store key and OAuth credentials in the keychain, the
/// registry entry, and delivered notifications.
public struct LocalAccountEraser: AccountEraser {
    let root: URL
    let secrets: any SecretStore
    let registry: AccountRegistry
    let credentialID: @Sendable (AccountID) -> SecretID
    let notificationRemover: @Sendable (AccountID) async -> Void
    let stagedFilesRoot: URL?

    public init(
        root: URL, secrets: any SecretStore, registry: AccountRegistry,
        credentialID: @escaping @Sendable (AccountID) -> SecretID,
        stagedFilesRoot: URL? = nil, notificationRemover: @escaping @Sendable (AccountID) async -> Void
    ) {
        self.root = root
        self.secrets = secrets
        self.registry = registry
        self.credentialID = credentialID
        self.notificationRemover = notificationRemover
        self.stagedFilesRoot = stagedFilesRoot
    }

    func directory(_ account: AccountID) -> AccountDirectory { AccountDirectory(root: root, account: account) }

    public func wipeExports(_ account: AccountID) throws { try directory(account).wipeExports() }

    public func removeNotifications(_ account: AccountID) async { await notificationRemover(account) }

    public func shredStoreKey(_ account: AccountID) throws {
        try StoreKeyLifecycle(secrets: secrets).shred(account)
    }

    public func deleteCredentials(_ account: AccountID) throws { try secrets.delete(credentialID(account)) }

    public func deleteAccountFiles(_ account: AccountID) throws {
        if let stagedFilesRoot {
            do {
                try FileManager.default.removeItem(at: stagedFilesRoot.appending(path: account.description))
            } catch CocoaError.fileNoSuchFile {}
        }
        try directory(account).deleteAccountFiles()
    }

    public func unregister(_ account: AccountID) throws { try registry.remove(account) }
}

/// Revocation for `AccountSession.logout` goes through the OAuth endpoints.
extension OAuthEndpoints: TokenRevoker {}
