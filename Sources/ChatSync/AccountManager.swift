import ChatKeychain
import ChatModel
import Foundation
import Synchronization

public struct AccountRecord: Hashable, Sendable, Codable, Identifiable {
    public var id: AccountID
    public var email: String
    public var displayName: String
    public var me: UserName
    /// Absent in records written before live notifications existed.
    public var events: EventSettings?

    public init(
        id: AccountID = AccountID(), email: String, displayName: String, me: UserName, events: EventSettings? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.me = me
        self.events = events
    }

    public var eventSettings: EventSettings { events ?? EventSettings() }
}

/// The account list lives in the keychain, so emails never sit in plaintext on disk. Edits are read-modify-write
/// under one lock shared by every copy of the registry.
public struct AccountRegistry: Sendable {
    public static let secretID = SecretID(service: "io.github.drekinov.gchat-mac.accounts", account: "registry")
    let secrets: any SecretStore
    private static let lock = RegistryLock()

    public init(secrets: any SecretStore) { self.secrets = secrets }

    public func load() throws(SecretStoreError) -> [AccountRecord] {
        try Self.lock.withLock { () throws(SecretStoreError) in try read() }
    }

    public func upsert(_ record: AccountRecord) throws(SecretStoreError) {
        try Self.lock.withLock { () throws(SecretStoreError) in
            var records = try read()
            records.removeAll { $0.id == record.id }
            records.append(record)
            try write(records)
        }
    }

    /// Replaces a known account's record in place; returns false if it isn't registered.
    @discardableResult
    public func update(_ record: AccountRecord) throws(SecretStoreError) -> Bool {
        try Self.lock.withLock { () throws(SecretStoreError) -> Bool in
            var records = try read()
            guard let index = records.firstIndex(where: { $0.id == record.id }) else { return false }
            records[index] = record
            try write(records)
            return true
        }
    }

    /// Removing an unknown account succeeds.
    public func remove(_ id: AccountID) throws(SecretStoreError) {
        try Self.lock.withLock { () throws(SecretStoreError) in
            var records = try read()
            guard records.contains(where: { $0.id == id }) else { return }
            records.removeAll { $0.id == id }
            try write(records)
        }
    }

    private func read() throws(SecretStoreError) -> [AccountRecord] {
        guard let data = try secrets.read(Self.secretID) else { return [] }
        guard let records = try? JSONDecoder().decode([AccountRecord].self, from: data) else {
            throw .unexpectedData
        }
        return records
    }

    private func write(_ records: [AccountRecord]) throws(SecretStoreError) {
        guard let data = try? JSONEncoder().encode(records) else { throw .unexpectedData }
        try secrets.write(data, for: Self.secretID)
    }
}

final class RegistryLock: Sendable {
    private let mutex = Mutex(())

    func withLock<T, E: Error>(_ body: () throws(E) -> T) throws(E) -> T {
        try mutex.withLock { (_: inout ()) throws(E) -> T in try body() }
    }
}

public enum AccountManagerError: Error, Sendable, Equatable {
    /// Another add or logout for this account is in progress, or the account already has a session.
    case busy
    case logoutAborted
}

public actor AccountManager {
    public typealias SessionFactory = @Sendable (AccountRecord) async throws -> AccountSession

    public struct StartupReport: Sendable, Equatable {
        public var restored: [AccountID]
        public var failed: [AccountID]
        /// Logouts that still have local steps left; retried on the next launch.
        public var incompleteLogouts: Set<AccountID>
    }

    let registry: AccountRegistry
    let recovery: LogoutRecovery
    let tombstones: LogoutTombstones
    let factory: SessionFactory

    public private(set) var records: [AccountRecord] = []
    public private(set) var sessions: [AccountID: AccountSession] = [:]
    /// Accounts with an add or logout in flight; lifecycle operations on one account never interleave.
    private var reserved: Set<AccountID> = []
    /// The latest path state, applied to every session including ones created later.
    public private(set) var connectivity: Connectivity = .reachable
    public nonisolated let accounts = LatestValue<[AccountRecord]>()

    public init(
        registry: AccountRegistry, recovery: LogoutRecovery, tombstones: LogoutTombstones,
        factory: @escaping SessionFactory
    ) {
        self.registry = registry
        self.recovery = recovery
        self.tombstones = tombstones
        self.factory = factory
    }

    /// Finishes interrupted logouts before restoring anything, then starts a session per remaining account.
    /// Fails if the tombstones can't be read, so an interrupted logout is never mistaken for a healthy account.
    public func startup() async throws -> StartupReport {
        let interrupted = Set(try tombstones.pending().map(\.account))
        let incomplete = try await recovery.recover()
        for id in interrupted { try registry.remove(id) }
        let loaded = try registry.load().filter { !interrupted.contains($0.id) }
        records = loaded

        var restored: [AccountID] = []
        var failed: [AccountID] = []
        for record in loaded where !reserved.contains(record.id) && sessions[record.id] == nil {
            reserved.insert(record.id)
            defer { reserved.remove(record.id) }
            do {
                let session = try await factory(record)
                sessions[record.id] = session
                await applyConnectivity(to: session)
                await session.configureEvents(record.eventSettings)
                await session.start()
                restored.append(record.id)
            } catch {
                failed.append(record.id)
            }
        }
        accounts.send(records)
        return StartupReport(restored: restored, failed: failed, incompleteLogouts: incomplete)
    }

    /// Registers a freshly logged-in account and starts its session.
    public func add(_ record: AccountRecord) async throws -> AccountSession {
        guard !reserved.contains(record.id), sessions[record.id] == nil, !tombstones.isPending(record.id) else {
            throw AccountManagerError.busy
        }
        reserved.insert(record.id)
        defer { reserved.remove(record.id) }
        let session = try await factory(record)
        do {
            try registry.upsert(record)
        } catch {
            _ = await session.logout(refreshToken: nil)
            throw error
        }
        sessions[record.id] = session
        records.removeAll { $0.id == record.id }
        records.append(record)
        await applyConnectivity(to: session)
        await session.configureEvents(record.eventSettings)
        await session.start()
        accounts.send(records)
        return session
    }

    /// Rebuild the session on the existing account ID after a successful sign-in.
    public func reconnect(
        _ id: AccountID, saveCredentials: @Sendable () throws -> Void
    ) async throws -> AccountSession {
        guard !reserved.contains(id), !tombstones.isPending(id),
            let record = records.first(where: { $0.id == id })
        else { throw AccountManagerError.busy }
        reserved.insert(id)
        defer { reserved.remove(id) }
        if let previous = sessions[id] {
            try await previous.retireForReconnect(after: saveCredentials)
            sessions[id] = nil
        } else {
            try saveCredentials()
        }
        let session = try await factory(record)
        sessions[id] = session
        await applyConnectivity(to: session)
        await session.configureEvents(record.eventSettings)
        await session.start()
        return session
    }

    /// Saves this Mac's live-notification settings for the account and applies them to its session.
    public func setEventSettings(_ id: AccountID, _ settings: EventSettings) async throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw AccountManagerError.busy }
        var record = records[index]
        record.events = settings
        guard try registry.update(record) else { throw AccountManagerError.busy }
        records[index] = record
        accounts.send(records)
        await sessions[id]?.configureEvents(settings)
    }

    /// The session writes its tombstone first, and unregistering is the last logout step, so a crash anywhere
    /// here is finished by `startup()`.
    public func logout(_ id: AccountID, refreshToken: String?) async throws -> AccountSession.LogoutReport {
        guard !reserved.contains(id), records.contains(where: { $0.id == id }) else {
            throw AccountManagerError.busy
        }
        reserved.insert(id)
        defer { reserved.remove(id) }
        let report: AccountSession.LogoutReport
        if let session = sessions[id] {
            report = await session.logout(refreshToken: refreshToken)
        } else {
            // The account failed to restore, or an earlier removal is pending.
            do {
                try tombstones.write(.init(account: id, remaining: LogoutStep.allCases))
            } catch {
                throw AccountManagerError.logoutAborted
            }
            let failed = await recovery.runner.run(id)
            report = .init(aborted: false, drained: true, failedSteps: failed)
        }
        guard !report.aborted else { throw AccountManagerError.logoutAborted }
        sessions[id] = nil
        if report.failedSteps.isEmpty { records.removeAll { $0.id == id } }
        accounts.send(records)
        return report
    }

    public func session(_ id: AccountID) -> AccountSession? { sessions[id] }

    public func setConnectivity(_ connectivity: Connectivity) async {
        self.connectivity = connectivity
        for session in sessions.values { await session.setConnectivity(connectivity) }
    }

    public func systemDidWake() async {
        for session in sessions.values { await session.systemDidWake() }
    }

    /// Repeats until the value it applied is still the latest, since a path change can land during the await.
    private func applyConnectivity(to session: AccountSession) async {
        var applied: Connectivity
        repeat {
            applied = connectivity
            await session.setConnectivity(applied)
        } while applied != connectivity
    }
}
