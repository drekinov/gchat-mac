import AppKit
import ChatModel
import ChatSync
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// One dropped item. Some drags are file promises: the screenshot and screen-recording thumbnails (and apps like
/// Photos) promise the image or movie, and a Safari bookmark promises a `.webloc`. Only the promised content type is
/// importable then, so importing a `URL` fails and the drop is discarded without ever reaching the app. Promised
/// images, movies and documents therefore arrive as copies and link files as the link they hold; files that already
/// exist on disk arrive as a URL, as before.
enum DroppedFile: Transferable {
    /// What the drag pointed at; not necessarily a file.
    case link(URL)
    /// Dragged text. The composer's text view takes text dropped on it, but SwiftUI's drop destinations register
    /// for any item, so text dropped beside the text view (its padding, the message list) arrives here.
    case text(String)
    /// A scratch copy under `AttachmentStaging.dropsRoot`, made when the drop was delivered.
    case copy(URL)
    /// A delivered file that was never copied: over the attachment size limit.
    case tooLarge(name: String)
    /// A delivered item that was never copied: not a regular file.
    case unusable(name: String)

    static var transferRepresentation: some TransferRepresentation {
        // Listed first so a promise is fulfilled. Opened in place, a Finder file is bookmarked rather than copied.
        FileRepresentation(importedContentType: .image, shouldAttemptToOpenInPlace: true) { try received($0) }
        FileRepresentation(importedContentType: .movie, shouldAttemptToOpenInPlace: true) { try received($0) }
        FileRepresentation(importedContentType: .internetLocation) { linkFile($0.file) }
        FileRepresentation(importedContentType: .internetShortcut) { linkFile($0.file) }
        ProxyRepresentation(importing: { (url: URL) in DroppedFile.link(url) })
        ProxyRepresentation(importing: { (text: String) in DroppedFile.text(text) })
        DataRepresentation(importedContentType: .rtf) { try await richText($0) }
        // Promised documents (a Mail attachment); after text so text drags never become files. Composite content
        // (PDF, Office, iWork) rather than `.content`, which also takes HTML.
        FileRepresentation(importedContentType: .compositeContent, shouldAttemptToOpenInPlace: true) {
            try received($0)
        }
        FileRepresentation(importedContentType: .audio, shouldAttemptToOpenInPlace: true) { try received($0) }
        FileRepresentation(importedContentType: .archive, shouldAttemptToOpenInPlace: true) { try received($0) }
    }

    struct EmptyText: Error {}

    /// Styled text offered without a plain-text form, typed in as plain text.
    static func richText(_ rtf: Data) async throws -> DroppedFile {
        guard let text = await plainText(fromRTF: rtf), !text.isEmpty else { throw EmptyText() }
        return .text(text)
    }

    @concurrent private static func plainText(fromRTF rtf: Data) async -> String? {
        NSAttributedString(rtf: rtf, documentAttributes: nil)?.string
    }

    /// The web link in a `.webloc` (a property list) or `.url` (`URL=` line) file. A link file can't name a file
    /// on disk to attach.
    static func linkFile(_ file: URL) -> DroppedFile {
        let unusable = DroppedFile.unusable(name: file.lastPathComponent)
        // Sized before reading: link files are tiny, and anything else is refused without being read.
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, size <= 64 * 1024,
            let data = try? Data(contentsOf: file)
        else { return unusable }
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let text = String(decoding: data, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("URL=") }
        guard let string = (plist?["URL"] as? String) ?? line.map({ String($0.dropFirst(4)) }),
            let url = URL(string: string.trimmingCharacters(in: .whitespaces)), url.scheme != nil, !url.isFileURL
        else { return unusable }
        return .link(url)
    }

    /// Checks the limits before copying, so nothing is written for a file that can't attach.
    static func received(_ received: ReceivedTransferredFile) throws -> DroppedFile {
        let file = received.file
        if received.isOriginalFile { return .link(file) }
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else {
            return .unusable(name: file.lastPathComponent)
        }
        guard size <= MediaLoader.maxFileBytes else { return .tooLarge(name: file.lastPathComponent) }
        return .copy(try AttachmentStaging.receive(file))
    }
}

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

    /// Where drops are copied before it's known which account they're for.
    static var dropsRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "dropped", directoryHint: .isDirectory)
    }

    /// Copies a file the drop delivered, which the system deletes once the import returns.
    static func receive(_ file: URL) throws -> URL {
        let folder = dropsRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let copy = folder.appending(path: file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: copy)
            return copy
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Moves a copy made by `receive(_:)` into the account's staging area. A copy that isn't a regular file is
    /// discarded, and its URL is returned anyway so `addFiles` names it in the error.
    static func adopt(_ dropped: URL, for account: AccountID) -> URL {
        guard let scratch = scratchFolder(of: dropped) else { return dropped }
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard (try? dropped.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
            let folder = newFolder(for: account)
        else { return dropped }
        let target = folder.appending(path: dropped.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: dropped, to: target)
            return target
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return dropped
        }
    }

    /// Deletes an adopted copy that wasn't attached after all; any path outside the account's area is left alone.
    static func removeStaged(_ staged: URL, for account: AccountID) {
        let folder = staged.deletingLastPathComponent()
        let parent = folder.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == directory(account).resolvingSymlinksInPath().path else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes a copy made by `receive(_:)` that won't be attached.
    static func discard(_ dropped: URL) {
        if let scratch = scratchFolder(of: dropped) { try? FileManager.default.removeItem(at: scratch) }
    }

    /// Copies left by a quit or crash mid-drop go at launch. A drop is adopted or discarded within seconds, so an
    /// hour-old folder is abandoned, while a second instance's drop in progress is left alone.
    static func clearDrops(olderThan age: TimeInterval = 3600, now: Date = Date()) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: dropsRoot, includingPropertiesForKeys: [.creationDateKey])
        else { return }
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            if now.timeIntervalSince(created) > age { try? fm.removeItem(at: folder) }
        }
    }

    /// The per-drop folder `receive(_:)` made for `dropped`; `nil` for any other path, which is never deleted.
    private static func scratchFolder(of dropped: URL) -> URL? {
        let scratch = dropped.deletingLastPathComponent()
        let parent = scratch.deletingLastPathComponent().resolvingSymlinksInPath().path
        return parent == dropsRoot.resolvingSymlinksInPath().path ? scratch : nil
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
