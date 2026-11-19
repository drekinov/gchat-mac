import AppKit
import ChatAuth
import ChatKeychain
import ChatModel
import ChatNet
import ChatStore
import ChatSync
import Foundation
import GoogleChat
import Synchronization

struct WorkspaceBrowser: BrowserOpener {
    func open(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}

enum LiveAccountError: Error, Equatable {
    case alreadyAdded(String)
    case credentialsMissing
    case storeShredded
}

/// Builds one real session per account: keychain credentials, a token provider, the Google client and an
/// encrypted store and media cache under `root`.
final class LiveSessionMaker: Sendable {
    let root: URL
    let vault: CredentialVault
    let keys: StoreKeyLifecycle
    let runner: LogoutRunner
    let transport = AuthTransport()
    let notifications: NotificationCenterPoster
    private let pipeline = ImagePipeline(budget: MemoryBudget(capacity: 48 << 20))
    private let fetcher = SafeFetcher()
    /// The token from a fresh sign-in, handed to that account's provider so it skips one refresh.
    private let pendingGrants = Mutex<[AccountID: TokenGrant]>([:])

    init(
        root: URL, vault: CredentialVault, keys: StoreKeyLifecycle, runner: LogoutRunner,
        notifications: NotificationCenterPoster
    ) {
        self.root = root
        self.vault = vault
        self.keys = keys
        self.runner = runner
        self.notifications = notifications
    }

    func prime(_ account: AccountID, with grant: TokenGrant?) {
        pendingGrants.withLock { $0[account] = grant }
    }

    func make(_ record: AccountRecord) async throws -> AccountSession {
        guard let credentials = try vault.load(record.id) else { throw LiveAccountError.credentialsMissing }
        let gate = SessionGate()
        let endpoints = OAuthEndpoints(transport: transport, client: credentials.client)
        let tokens = OAuthTokenProvider(
            account: record.id, credentials: credentials, endpoints: endpoints, vault: vault, gate: gate)
        if let grant = pendingGrants.withLock({ $0.removeValue(forKey: record.id) }) { await tokens.prime(grant) }
        let client = GoogleChatClient(transport: transport, tokens: tokens)
        let events = WorkspaceEventsClient(transport: transport, tokens: tokens)

        let directory = AccountDirectory(root: root, account: record.id)
        let (key, state) = try keys.open(for: record.id, storeExists: directory.storeExists())
        guard let key, state == .ready else { throw LiveAccountError.storeShredded }
        try directory.create()
        let store = try SQLiteAccountStore.open(directory: directory, key: key)
        if let outbox = try? store.outbox() {
            let bookmarks = Set(outbox.flatMap { $0.payload.attachments.map(\.bookmark) })
            AttachmentStaging.prune(in: AttachmentStaging.directory(record.id), keeping: bookmarks)
        }
        let loader = try MediaLoader(
            media: client, cache: MediaCache(directory: directory, key: key),
            exports: ExportDirectory(directory: directory), pipeline: pipeline, fetcher: fetcher, gate: gate)
        return AccountSession(
            account: record.id, me: record.me, api: client, store: store, clock: SystemClock(), logoutRunner: runner,
            revoker: endpoints, directory: client, gate: gate, notifications: notifications, media: client,
            files: LiveFileAccess(account: record.id), mediaLoader: loader,
            events: EventServices(
                events: events, pubsub: events, hasScope: OAuthScopes.hasPubSub(credentials.grantedScope)))
    }
}

/// Real Google accounts: the OAuth client and secrets in the keychain, per-account stores under Application
/// Support, and one `AccountManager` that restores sessions at launch and adds new ones after sign-in.
final class LiveAccounts: Sendable {
    static let clientSecretID = SecretID(service: "io.github.drekinov.gchat-mac.oauth-client", account: "default")

    let secrets: any SecretStore
    let vault: CredentialVault
    let registry: AccountRegistry
    let maker: LiveSessionMaker
    let manager: AccountManager

    init(root: URL, secrets: any SecretStore = Keychain(), notifications: NotificationCenterPoster) {
        self.secrets = secrets
        let vault = CredentialVault(secrets: secrets)
        let registry = AccountRegistry(secrets: secrets)
        let tombstones = LogoutTombstones(root: root)
        let eraser = LocalAccountEraser(
            root: root, secrets: secrets, registry: registry, credentialID: CredentialVault.secretID(for:),
            stagedFilesRoot: AttachmentStaging.accountsRoot,
            notificationRemover: { await notifications.remove(account: $0) })
        let runner = LogoutRunner(eraser: eraser, tombstones: tombstones)
        let maker = LiveSessionMaker(
            root: root, vault: vault, keys: StoreKeyLifecycle(secrets: secrets), runner: runner,
            notifications: notifications)
        self.vault = vault
        self.registry = registry
        self.maker = maker
        manager = AccountManager(
            registry: registry, recovery: LogoutRecovery(runner: runner), tombstones: tombstones,
            factory: { try await maker.make($0) })
    }

    static func defaultRoot() -> URL {
        URL.applicationSupportDirectory.appending(path: "Accounts", directoryHint: .isDirectory)
    }

    var storedClient: OAuthClientConfig? {
        guard let data = try? secrets.read(Self.clientSecretID) else { return nil }
        return try? JSONDecoder().decode(OAuthClientConfig.self, from: data)
    }

    func importClient(_ json: Data) throws -> OAuthClientConfig {
        let client = try OAuthClientConfig(json: json)
        try secrets.write(try JSONEncoder().encode(client), for: Self.clientSecretID)
        return client
    }

    /// Runs the browser sign-in and registers the account. Signing in to an account that's already here fails.
    func signIn(client: OAuthClientConfig) async throws -> (AccountRecord, AccountSession) {
        let flow = SignInFlow(
            endpoints: OAuthEndpoints(transport: maker.transport, client: client), browser: WorkspaceBrowser())
        let result = try await flow.run()
        try Task.checkCancellation()
        let identity = result.credentials.identity
        guard let me = UserName("users/\(identity.subject)") else { throw AuthError.malformedResponse("subject") }
        if try registry.load().contains(where: { $0.me == me }) { throw LiveAccountError.alreadyAdded(identity.email) }

        let record = AccountRecord(email: identity.email, displayName: identity.name ?? identity.email, me: me)
        try vault.saveInitial(result.credentials, for: record.id)
        maker.prime(record.id, with: result.grant)
        do {
            return (record, try await manager.add(record))
        } catch {
            maker.prime(record.id, with: nil)
            try? vault.delete(record.id)
            throw error
        }
    }

    /// With `liveNotifications`, a fresh consent that must also grant Pub/Sub for this same account; anything
    /// less leaves the stored credentials and the running session as they are.
    func reconnect(
        _ info: AccountInfo, client: OAuthClientConfig, liveNotifications: Bool = false
    ) async throws -> AccountSession {
        let flow = SignInFlow(
            endpoints: OAuthEndpoints(transport: maker.transport, client: client), browser: WorkspaceBrowser())
        let result =
            liveNotifications
            ? try await flow.grantLiveNotifications(account: info.me, loginHint: info.email)
            : try await flow.run(loginHint: info.email, reconnecting: info.me)
        try Task.checkCancellation()
        defer { maker.prime(info.id, with: nil) }
        return try await manager.reconnect(info.id) { [vault, maker] in
            try vault.saveInitial(result.credentials, for: info.id)
            maker.prime(info.id, with: result.grant)
        }
    }
}
