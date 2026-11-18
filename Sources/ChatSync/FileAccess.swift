import Foundation

public enum FileAccessError: Error, Sendable, Equatable {
    /// The file moved, was deleted, or the bookmark went stale.
    case unavailable
}

/// Turns an attachment's bookmark back into a readable file for the duration of `body`.
public protocol FileAccess: Sendable {
    func withFile<T: Sendable>(
        _ bookmark: Data, _ body: (URL) async throws -> T
    ) async throws -> T
}

/// Security-scoped bookmarks, as the sandboxed app creates them for user-selected files.
public struct SecurityScopedFileAccess: FileAccess {
    public init() {}

    public static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
    }

    public func withFile<T: Sendable>(_ bookmark: Data, _ body: (URL) async throws -> T) async throws -> T {
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale),
            url.startAccessingSecurityScopedResource()
        else { throw FileAccessError.unavailable }
        defer { url.stopAccessingSecurityScopedResource() }
        return try await body(url)
    }
}

/// Plain file paths as "bookmarks", for tests and fake mode outside the sandbox scope rules.
public struct PathFileAccess: FileAccess {
    public init() {}

    public static func bookmark(for url: URL) -> Data { Data(url.path.utf8) }

    public func withFile<T: Sendable>(_ bookmark: Data, _ body: (URL) async throws -> T) async throws -> T {
        let url = URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self))
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw FileAccessError.unavailable }
        return try await body(url)
    }
}
