import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case put = "PUT"
    case delete = "DELETE"
}

/// What identifies the bytes an upload promised to send. A file that changes any of these mid-upload fails the
/// request instead of sending a mixture of old and new content.
public struct FileIdentity: Sendable, Equatable {
    public var device: Int64
    public var inode: UInt64
    public var size: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    /// Status-change time, which a rewrite can't reset the way it can reset the modification time.
    public var changedSeconds: Int64
    public var changedNanoseconds: Int64

    public init(
        device: Int64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64,
        changedSeconds: Int64 = 0, changedNanoseconds: Int64 = 0
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds
        self.changedNanoseconds = changedNanoseconds
    }
}

/// A regular file opened once. Validation and streaming both use this descriptor, so replacing the path
/// afterwards can't change what is sent.
public final class OpenedFile: Sendable {
    public let url: URL
    public let identity: FileIdentity
    let descriptor: Int32

    private init(url: URL, descriptor: Int32, identity: FileIdentity) {
        self.url = url
        self.descriptor = descriptor
        self.identity = identity
    }

    deinit {
        close(descriptor)
    }

    /// Opens without blocking (so a FIFO can't hang the caller) and requires a regular file.
    public static func open(_ url: URL) throws(TransportError) -> OpenedFile {
        guard url.isFileURL else { throw .requestBodyUnavailable }
        let descriptor = Darwin.open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw .requestBodyUnavailable }
        guard let identity = Self.identity(of: descriptor) else {
            close(descriptor)
            throw .requestBodyUnavailable
        }
        return OpenedFile(url: url, descriptor: descriptor, identity: identity)
    }

    /// The descriptor's current state, or nil if it is no longer a regular file.
    func currentIdentity() -> FileIdentity? { Self.identity(of: descriptor) }

    private static func identity(of descriptor: Int32) -> FileIdentity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileIdentity(
            device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}

/// A request body of `prefix`, then the whole contents of a file, then `suffix`, streamed without buffering the
/// file. Pass `opened` to bind validation and sending to one descriptor; with only `file`, the transport opens
/// it once per send.
public struct FileBody: Sendable, Equatable {
    public var prefix: Data
    public var file: URL
    public var suffix: Data
    public var opened: OpenedFile?

    public init(prefix: Data = Data(), file: URL, suffix: Data = Data()) {
        self.prefix = prefix
        self.file = file
        self.suffix = suffix
    }

    public init(prefix: Data = Data(), opened: OpenedFile, suffix: Data = Data()) {
        self.prefix = prefix
        self.file = opened.url
        self.suffix = suffix
        self.opened = opened
    }

    public static func == (lhs: FileBody, rhs: FileBody) -> Bool {
        lhs.prefix == rhs.prefix && lhs.file == rhs.file && lhs.suffix == rhs.suffix && lhs.opened === rhs.opened
    }
}

/// Requests are plain values, so a retry is always rebuilt from typed inputs and never from a redirected request.
public struct HTTPRequest: Sendable, Equatable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// When set, this is sent instead of `body`.
    public var bodyFile: FileBody?
    public var timeout: Duration
    public var maxResponseBytes: Int

    public init(
        method: HTTPMethod = .get, url: URL, headers: [String: String] = [:], body: Data? = nil,
        timeout: Duration = .seconds(30), maxResponseBytes: Int = 16 * 1024 * 1024, bodyFile: FileBody? = nil
    ) {
        self.bodyFile = bodyFile
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.maxResponseBytes = maxResponseBytes
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Keys are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }
}

public enum TransportError: Error, Sendable, Equatable {
    case insecureScheme
    case hostNotAllowed
    /// The server answered with a redirect, which token-bearing requests never follow. `location` must only be
    /// handed to the credential-free fetcher and never logged.
    case redirected(status: Int, location: URL?)
    case responseTooLarge
    case timedOut
    case offline
    case connectionLost
    case cancelled
    case tls
    /// The streamed request body's file is missing, not a regular file, or changed while it was being sent.
    case requestBodyUnavailable
    /// The `onChunk` handler of a streamed download threw.
    case sinkFailed
    case other(code: Int)

    /// The request may have reached the server, so a write's outcome is unknown.
    public var mayHaveReachedServer: Bool {
        switch self {
        case .insecureScheme, .hostNotAllowed, .offline, .cancelled, .tls, .requestBodyUnavailable: false
        case .redirected, .responseTooLarge, .timedOut, .connectionLost, .sinkFailed, .other: true
        }
    }
}

extension TransportError {
    /// How a URL loading failure is reported to callers.
    package init(_ error: URLError) {
        self =
            switch error.code {
            case .timedOut: .timedOut
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost, .dnsLookupFailed,
                .cannotConnectToHost:
                .offline
            case .networkConnectionLost: .connectionLost
            case .cancelled: .cancelled
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
                .tls
            case .dataLengthExceedsMaximum: .responseTooLarge
            default: .other(code: error.code.rawValue)
            }
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse
}

/// Status line and headers of a streamed response.
public struct HTTPResponseHead: Sendable, Equatable {
    public static let maxErrorBodyBytes = 64 * 1024

    public var status: Int
    /// Keys are lowercased.
    public var headers: [String: String]
    /// Bytes handed to `onChunk`; always 0 for a non-2xx status.
    public var byteCount: Int
    /// The first `maxErrorBodyBytes` of a non-2xx body, for error mapping. Empty for 2xx.
    public var errorBody: Data

    public init(status: Int, headers: [String: String] = [:], byteCount: Int = 0, errorBody: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.byteCount = byteCount
        self.errorBody = errorBody
    }
}

public protocol StreamingTransport: HTTPTransport {
    /// Delivers a 2xx body in chunks of at most 1 MiB, enforcing `request.maxResponseBytes`, and never follows
    /// redirects (a 3xx throws `.redirected`). `onChunk` throwing cancels the transfer with `.sinkFailed`. The
    /// transport releases `onChunk` before returning, and on cancellation it may still be mid-call on another thread.
    func stream(
        _ request: HTTPRequest, onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws(TransportError) -> HTTPResponseHead
}
