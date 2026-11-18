import ChatModel
import Foundation

public struct FakeAccount: Hashable, Sendable {
    public let user: User
    public let token: String

    public init(user: User, token: String) {
        self.user = user
        self.token = token
    }
}

public enum FakeSender: Sendable {
    case account(FakeAccount)
    case bot(User)
    case user(User)

    var user: User {
        switch self {
        case .account(let account): account.user
        case .bot(let user), .user(let user): user
        }
    }
}

/// A request served by `FakeMediaHost`, the target of redirected media downloads.
public struct MediaHostRequest: Sendable {
    public var host: String
    public var path: String
    /// True if the request carried an `Authorization` or `Cookie` header.
    public var hadCredentials: Bool
    public var range: String?
    public var status: Int
}

public struct RecordedRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [URLQueryItem]
    /// Nil when the bearer token was missing, unknown or revoked.
    public var account: FakeAccount?
    /// Nil when the request ended in a simulated network error.
    public var status: Int?

    public func value(for name: String) -> String? {
        query.first { $0.name == name }?.value
    }
}
