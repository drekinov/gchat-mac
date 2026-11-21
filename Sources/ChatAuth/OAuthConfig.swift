import CryptoKit
import Foundation

public enum AuthError: Error, Sendable, Equatable {
    case invalidClientConfig(String)
    case browserUnavailable
    case timedOut
    case cancelled
    /// The callback's `state` didn't match: a forged or replayed redirect.
    case stateMismatch
    /// Google returned `error=` on the redirect, e.g. `access_denied` or `admin_policy_enforced`.
    case authorizationDenied(String)
    case missingCode
    /// The token endpoint refused; `code` is the OAuth error identifier (e.g. `invalid_grant`), never a description.
    case tokenEndpoint(status: Int, code: String?)
    case insufficientScopes(missing: [String])
    case wrongAccount
    case malformedResponse(String)
    case transport(String)
    case vault(String)
    /// The session that started this was retired.
    case retired
}

/// A Google "Desktop app" OAuth client, imported from the JSON file downloaded from the Cloud console.
public struct OAuthClientConfig: Hashable, Sendable, Codable {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    public static let userinfoEndpoint = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!

    public var clientID: String
    /// Desktop clients ship this in the app by design; it's kept in the keychain anyway.
    public var clientSecret: String
    public var projectID: String?

    public init(clientID: String, clientSecret: String, projectID: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.projectID = projectID
    }

    /// Parses `{"installed": {...}}`. Endpoints in the file are checked but never used; the constants above are.
    public init(json: Data) throws(AuthError) {
        struct File: Decodable {
            struct Installed: Decodable {
                var clientId: String?
                var clientSecret: String?
                var projectId: String?
                var authUri: String?
                var tokenUri: String?
            }
            var installed: Installed?
            var web: Installed?
        }
        guard json.count < 64 * 1024, let file = try? OAuthEndpoints.decoder.decode(File.self, from: json) else {
            throw .invalidClientConfig("notJSON")
        }
        if file.installed == nil, file.web != nil { throw .invalidClientConfig("webClient") }
        guard let installed = file.installed else { throw .invalidClientConfig("notDesktopClient") }
        guard let id = installed.clientId, id.hasSuffix(".apps.googleusercontent.com"), id.count < 256,
            id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { throw .invalidClientConfig("clientID") }
        guard let secret = installed.clientSecret, !secret.isEmpty, secret.count < 256 else {
            throw .invalidClientConfig("clientSecret")
        }
        if let auth = installed.authUri, URL(string: auth)?.host() != "accounts.google.com" {
            throw .invalidClientConfig("authURI")
        }
        if let token = installed.tokenUri, URL(string: token)?.host() != "oauth2.googleapis.com" {
            throw .invalidClientConfig("tokenURI")
        }
        self.init(clientID: id, clientSecret: secret, projectID: installed.projectId)
    }
}

public enum OAuthScopes {
    static let prefix = "https://www.googleapis.com/auth/"

    /// Requested together at first login, so each org consents once.
    public static let required: [String] =
        ["openid", "email"]
        + [
            "chat.spaces.readonly", "chat.memberships.readonly", "chat.messages.readonly", "chat.messages.create",
            "chat.messages",
            "chat.messages.reactions", "chat.users.readstate", "chat.users.spacesettings", "chat.customemojis.readonly",
            "chat.spaces.create",
        ].map { prefix + $0 }

    /// Requested too, but a login without them still works; the features they enable turn off.
    public static let optional: [String] = ["directory.readonly"].map { prefix + $0 }

    public static func hasDirectory(_ granted: String) -> Bool {
        granted.split(separator: " ").contains { $0 == "https://www.googleapis.com/auth/directory.readonly" }
    }

    /// Google may return `email` as its full URL form; both count.
    static func normalize(_ scope: String) -> String {
        scope == "https://www.googleapis.com/auth/userinfo.email" ? "email" : scope
    }

    public static func missing(from granted: String) -> [String] {
        let have = Set(granted.split(separator: " ").map { normalize(String($0)) })
        return required.filter { !have.contains($0) }
    }
}

/// RFC 7636 S256 verifier and challenge, plus the anti-forgery `state`.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init() {
        self.init(verifier: Self.randomToken(bytes: 32), state: Self.randomToken(bytes: 24))
    }

    init(verifier: String, state: String) {
        self.verifier = verifier
        self.state = state
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomToken(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time comparison, so the state check doesn't leak a prefix match through timing.
    func matches(state candidate: String) -> Bool {
        let a = Array(state.utf8)
        let b = Array(candidate.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

extension OAuthClientConfig: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "OAuthClientConfig(\(clientID.prefix(12))…)" }
    public var debugDescription: String { description }
}
