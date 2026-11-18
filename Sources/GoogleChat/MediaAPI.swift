import ChatModel
import Foundation

public struct UploadedAttachment: Hashable, Sendable {
    public var resourceName: MediaResourceName?
    /// Passed to `messages.create` in the same space.
    public var uploadToken: String

    public init(resourceName: MediaResourceName?, uploadToken: String) {
        self.resourceName = resourceName
        self.uploadToken = uploadToken
    }
}

public struct MediaDownload: Hashable, Sendable {
    public var contentType: String?
    /// Bytes delivered to `onChunk`; 0 when `redirect` is set.
    public var byteCount: Int
    /// Set instead of delivering bytes when the API answered with a redirect. It must only be fetched without
    /// credentials, and never logged or put in an error.
    public var redirect: URL?

    public init(contentType: String? = nil, byteCount: Int = 0, redirect: URL? = nil) {
        self.contentType = contentType
        self.byteCount = byteCount
        self.redirect = redirect
    }
}

/// Upload and download of attachment bytes, kept apart from `ChatAPI` so JSON-only fakes stay small.
public protocol ChatMediaAPI: Sendable {
    /// Streams `file` as a multipart upload without staging a copy. The file is opened once and every check and
    /// retry uses that descriptor; if it changes size or modification time mid-upload the call fails with
    /// `transport(.requestBodyUnavailable)`. Files over 200 MiB fail with `invalidArgument` (status
    /// `CLIENT_FILE_TOO_LARGE`) before anything is sent.
    func uploadAttachment(
        to space: SpaceName, file: URL, filename: String, contentType: String
    ) async throws(ChatAPIError) -> UploadedAttachment

    /// Streams the media in chunks of at most 1 MiB, failing with `transport(.responseTooLarge)` past `maxBytes`.
    /// `onChunk` is released before this returns; it must be safe to call from another thread.
    func downloadMedia(
        _ resource: MediaResourceName, maxBytes: Int, onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws(ChatAPIError) -> MediaDownload
}
