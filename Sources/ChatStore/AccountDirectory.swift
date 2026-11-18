import ChatModel
import Foundation

/// On-disk layout of one account under `root`. Names use the local account UUID only.
public struct AccountDirectory: Sendable {
    public let root: URL
    public let account: AccountID

    public init(root: URL, account: AccountID) {
        self.root = root
        self.account = account
    }

    public static func defaultRoot() throws(StoreError) -> URL {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return base.appendingPathComponent("io.github.drekinov.gchat-mac", isDirectory: true)
        } catch {
            throw .io(code: (error as NSError).code)
        }
    }

    public var accountURL: URL {
        root.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(account.description, isDirectory: true)
    }

    public var storeURL: URL { accountURL.appendingPathComponent("store.sqlite", isDirectory: false) }
    public var mediaURL: URL { accountURL.appendingPathComponent("media", isDirectory: true) }

    public var exportsURL: URL {
        root.appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent(account.description, isDirectory: true)
    }

    public func storeExists() -> Bool {
        FileManager.default.fileExists(atPath: storeURL.path)
    }

    /// Creates the account and media directories, mode 0700.
    public func create() throws(StoreError) {
        let accounts = root.appendingPathComponent("accounts", isDirectory: true)
        for url in [root, accounts, accountURL, mediaURL] { try ensureDirectory(url) }
    }

    /// Creates `exports/<accountID>`, mode 0700.
    public func createExports() throws(StoreError) {
        for url in [root, exportsURL.deletingLastPathComponent(), exportsURL] { try ensureDirectory(url) }
    }

    /// Removes `accounts/<accountID>`, including the store, its WAL files and cached media.
    public func deleteAccountFiles() throws(StoreError) {
        try remove(accountURL)
    }

    /// Removes `exports/<accountID>` without following symlinks; see `ExportDirectory.wipe()`.
    public func wipeExports() throws(StoreError) {
        do throws(ExportError) {
            try ExportDirectory(directory: self).wipe()
        } catch {
            if case .io(let code) = error { throw .io(code: code) }
            throw .io(code: Int(EIO))
        }
    }

    func restrictFile(_ url: URL) throws(StoreError) {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw .io(code: (error as NSError).code)
        }
    }

    private func ensureDirectory(_ url: URL) throws(StoreError) {
        do {
            let manager = FileManager.default
            try manager.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw .io(code: (error as NSError).code)
        }
    }

    private func remove(_ url: URL) throws(StoreError) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        } catch {
            throw .io(code: (error as NSError).code)
        }
    }
}
