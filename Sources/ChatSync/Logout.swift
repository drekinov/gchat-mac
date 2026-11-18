import ChatModel
import Foundation

public enum LogoutStep: String, Sendable, Codable, CaseIterable {
    case wipeExports
    case removeNotifications
    /// Crypto-shred: the store key goes before the token and the files.
    case shredStoreKey
    case deleteCredentials
    case deleteAccountFiles
    /// Last, so the account stays known (and its tombstone pending) until every other step has succeeded.
    case unregister
}

/// The local side effects of logout. Every method is idempotent: "already gone" is success.
public protocol AccountEraser: Sendable {
    func wipeExports(_ account: AccountID) throws
    func removeNotifications(_ account: AccountID) async
    func shredStoreKey(_ account: AccountID) throws
    func deleteCredentials(_ account: AccountID) throws
    func deleteAccountFiles(_ account: AccountID) throws
    /// Removes the account from the registry.
    func unregister(_ account: AccountID) throws
}

public protocol TokenRevoker: Sendable {
    /// Best effort; must give up within its own timeout.
    func revoke(_ token: String) async
}

/// `logout-pending/<accountID>.json` beside (not inside) the account directories. It exists from the first logout
/// step until every local step has succeeded.
public struct LogoutTombstones: Sendable {
    public struct Tombstone: Codable, Sendable, Equatable {
        public var account: AccountID
        public var remaining: [LogoutStep]
    }

    let directory: URL

    public init(root: URL) {
        directory = root.appending(path: "logout-pending", directoryHint: .isDirectory)
    }

    func url(for account: AccountID) -> URL {
        directory.appending(path: "\(account.description).json", directoryHint: .notDirectory)
    }

    public func write(_ tombstone: Tombstone) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(tombstone)
        try data.write(to: url(for: tombstone.account), options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url(for: tombstone.account).path)
    }

    public func remove(_ account: AccountID) throws {
        do {
            try FileManager.default.removeItem(at: url(for: account))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    /// Fails closed: an unreadable directory throws, and a marker whose contents can't be read reruns every step.
    public func pending() throws -> [Tombstone] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Only a definite "doesn't exist" is empty; permission errors (including on ancestors) propagate.
            return []
        }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let uuid = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return nil }
            let account = AccountID(uuid)
            guard let data = try? Data(contentsOf: file),
                let tombstone = try? JSONDecoder().decode(Tombstone.self, from: data), tombstone.account == account
            else { return Tombstone(account: account, remaining: LogoutStep.allCases) }
            return tombstone
        }
    }

    public func isPending(_ account: AccountID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: account).path)
    }
}

/// Runs the local logout steps in order and records what's left in the tombstone.
public struct LogoutRunner: Sendable {
    let eraser: any AccountEraser
    let tombstones: LogoutTombstones

    public init(eraser: any AccountEraser, tombstones: LogoutTombstones) {
        self.eraser = eraser
        self.tombstones = tombstones
    }

    /// Returns the steps that failed. The tombstone is removed only when none did.
    @discardableResult
    public func run(_ account: AccountID, steps: [LogoutStep] = LogoutStep.allCases) async -> [LogoutStep] {
        var failed: [LogoutStep] = []
        for step in LogoutStep.allCases where steps.contains(step) {
            do {
                switch step {
                case .wipeExports: try eraser.wipeExports(account)
                case .removeNotifications: await eraser.removeNotifications(account)
                case .shredStoreKey: try eraser.shredStoreKey(account)
                case .deleteCredentials: try eraser.deleteCredentials(account)
                case .deleteAccountFiles: try eraser.deleteAccountFiles(account)
                case .unregister: try eraser.unregister(account)
                }
            } catch {
                failed.append(step)
            }
        }
        if failed.isEmpty {
            try? tombstones.remove(account)
        } else {
            try? tombstones.write(.init(account: account, remaining: failed))
        }
        return failed
    }
}

/// Runs before any session is restored: finishes every interrupted logout.
public struct LogoutRecovery: Sendable {
    let runner: LogoutRunner

    public init(runner: LogoutRunner) { self.runner = runner }

    /// Accounts whose logout is still incomplete; they must not be restored.
    public func recover() async throws -> Set<AccountID> {
        var incomplete: Set<AccountID> = []
        for tombstone in try runner.tombstones.pending() {
            // Every step runs again: a crash may have happened before the tombstone's list was updated.
            let failed = await runner.run(tombstone.account)
            if !failed.isEmpty { incomplete.insert(tombstone.account) }
        }
        return incomplete
    }
}
