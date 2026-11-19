import ChatNet
import Foundation

/// Google's structured error, minus `message`, which may contain names or content and is never kept.
public struct GoogleErrorInfo: Hashable, Sendable {
    public var httpStatus: Int
    /// Canonical status, e.g. `PERMISSION_DENIED`.
    public var status: String?
    /// `google.rpc.ErrorInfo.reason`, e.g. `SERVICE_DISABLED`.
    public var reason: String?

    public init(httpStatus: Int, status: String? = nil, reason: String? = nil) {
        self.httpStatus = httpStatus
        self.status = status
        self.reason = reason
    }

    /// Parses `{"error":{"code","status","details":[{"@type":".../google.rpc.ErrorInfo","reason"}]}}`.
    public init(httpStatus: Int, body: Data) {
        struct Envelope: Decodable {
            struct Body: Decodable {
                struct Detail: Decodable {
                    var type: String?
                    var reason: String?
                    enum CodingKeys: String, CodingKey {
                        case type = "@type"
                        case reason
                    }
                }
                var status: String?
                var details: [Detail]?
            }
            var error: Body
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
        let reason = envelope?.error.details?.first { $0.type?.hasSuffix("google.rpc.ErrorInfo") == true }?.reason
        self.init(
            httpStatus: httpStatus, status: envelope?.error.status.map(Self.clamp), reason: reason.map(Self.clamp))
    }

    /// Status and reason are enum-like identifiers; any other character is dropped so they can't carry content.
    private static func clamp(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.unicodeScalars.prefix(64).filter {
                    ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
                }))
    }
}

public enum ChatAPIError: Error, Sendable, Equatable {
    /// 401 after one forced token refresh.
    case unauthorized
    case rateLimited(retryAfter: Duration?)
    case server(GoogleErrorInfo)
    case permissionDenied(GoogleErrorInfo)
    case notFound(GoogleErrorInfo)
    case failedPrecondition(GoogleErrorInfo)
    case invalidArgument(GoogleErrorInfo)
    case conflict(GoogleErrorInfo)
    case otherHTTP(GoogleErrorInfo)
    case transport(TransportError)
    /// The token provider couldn't produce a token (needs login, keychain inaccessible, account closing).
    case noCredentials
    /// The response didn't match the expected shape. Carries only the coding path, never values.
    case decoding(path: String)

    public init(status: Int, headers: [String: String], body: Data) {
        let info = GoogleErrorInfo(httpStatus: status, body: body)
        switch status {
        case 401: self = .unauthorized
        case 429: self = .rateLimited(retryAfter: Self.retryAfter(headers["retry-after"]))
        case 403 where info.status == "RESOURCE_EXHAUSTED" || info.reason == "RATE_LIMIT_EXCEEDED":
            self = .rateLimited(retryAfter: Self.retryAfter(headers["retry-after"]))
        case 403: self = .permissionDenied(info)
        case 404: self = .notFound(info)
        case 409: self = .conflict(info)
        case 400 where info.status == "FAILED_PRECONDITION": self = .failedPrecondition(info)
        case 400: self = .invalidArgument(info)
        case 500...599: self = .server(info)
        default: self = .otherHTTP(info)
        }
    }

    static func retryAfter(_ value: String?) -> Duration? {
        guard let value, let seconds = Int(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 else {
            return nil
        }
        return .seconds(min(seconds, 3600))
    }

    /// A create that found an equivalent resource already in place.
    public var isAlreadyExists: Bool {
        if case .conflict(let info) = self { return info.status == nil || info.status == "ALREADY_EXISTS" }
        return false
    }

    /// A long-running operation that was still running when polling stopped. The write may yet complete.
    public var isOperationPending: Bool {
        if case .server(let info) = self { return info.status == Self.operationPendingStatus }
        return false
    }

    static let operationPendingStatus = "OPERATION_PENDING"

    /// Worth retrying with backoff (reads, and writes that carry a `requestId`).
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server: true
        case .transport(let error):
            ![.insecureScheme, .hostNotAllowed, .cancelled, .requestBodyUnavailable, .sinkFailed].contains(error)
        default: false
        }
    }

    /// For a write: the server may have committed it, so the outcome is unknown rather than failed.
    public var writeOutcomeUnknown: Bool {
        switch self {
        case .server: true
        case .transport(let error): error.mayHaveReachedServer
        case .decoding: true
        default: false
        }
    }
}
