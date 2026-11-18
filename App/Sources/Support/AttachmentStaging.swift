import ChatModel
import ChatSync
import Foundation

/// Copies of files the sandbox won't bookmark (drops, pasted files and images), kept in the app's own container
/// until sent. Only paths inside `root` are ever read back by path.
enum AttachmentStaging {
    static let maxAge: TimeInterval = 7 * 86_400

    static var root: URL {
        FileManager.default.temporaryDirectory.appending(path: "attachments", directoryHint: .isDirectory)
    }

    static var accountsRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "account-attachments", directoryHint: .isDirectory)
    }

    static func directory(_ account: AccountID) -> URL {
        accountsRoot.appending(path: account.description, directoryHint: .isDirectory)
    }

    /// A fresh per-file folder, so equal file names never collide.
    static func newFolder(for account: AccountID) -> URL? {
        let folder = directory(account).appending(path: UUID().uuidString, directoryHint: .isDirectory)
        return (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) == nil
            ? nil : folder
    }

    static func stage(_ url: URL, for account: AccountID) -> URL? {
        guard let folder = newFolder(for: account) else { return nil }
        let copy = folder.appending(path: url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    static func contains(_ url: URL, for account: AccountID) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        // Old outbox rows can still reference the original per-file folders.
        return [directory(account), root].contains { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
    }

    /// Queued attachments survive relaunches, so only old copies go.
    static func prune(in directory: URL = root, keeping bookmarks: Set<Data> = [], now: Date = Date()) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        else { return }
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            guard now.timeIntervalSince(created) > maxAge,
                let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
                files.allSatisfy({ !bookmarks.contains(PathFileAccess.bookmark(for: $0)) })
            else { continue }
            try? fm.removeItem(at: folder)
        }
    }
}

/// Security-scoped bookmarks first; plain paths only for staged copies.
struct LiveFileAccess: FileAccess {
    let account: AccountID
    func withFile<T: Sendable>(_ bookmark: Data, _ body: (URL) async throws -> T) async throws -> T {
        do {
            return try await SecurityScopedFileAccess().withFile(bookmark, body)
        } catch FileAccessError.unavailable {
            let url = URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self))
            guard AttachmentStaging.contains(url, for: account) else { throw FileAccessError.unavailable }
            return try await PathFileAccess().withFile(bookmark, body)
        }
    }
}
