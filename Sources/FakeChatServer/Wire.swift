import Foundation

struct IncomingRequest: Sendable {
    var method: String
    var host: String = "chat.googleapis.com"
    var path: String
    var query: [URLQueryItem]
    var headers: [String: String]
    var body: Data?

    var jsonBody: [String: Any]? {
        guard let body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    func value(_ name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name }?.value
    }

    var bearerToken: String? {
        guard let header = headers.first(where: { $0.key.lowercased() == "authorization" })?.value else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1])
    }
}

struct Reply: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(_ object: [String: Any], status: Int = 200) -> Reply {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return Reply(
            status: status, headers: ["Content-Type": "application/json; charset=UTF-8"], body: data)
    }
}

enum Outcome: Sendable {
    case reply(Reply)
    case networkError(URLError.Code)
}

struct WireError: Error, Sendable {
    var status: Int
    var googleStatus: String
    var message: String
    var reason: String?
    var retryAfter: Int?

    init(status: Int, googleStatus: String, message: String, reason: String? = nil, retryAfter: Int? = nil) {
        self.status = status
        self.googleStatus = googleStatus
        self.message = message
        self.reason = reason
        self.retryAfter = retryAfter
    }

    static func invalidArgument(_ message: String) -> WireError {
        WireError(status: 400, googleStatus: "INVALID_ARGUMENT", message: message)
    }

    static func notFound(_ message: String) -> WireError {
        WireError(status: 404, googleStatus: "NOT_FOUND", message: message)
    }

    static func alreadyExists(_ message: String) -> WireError {
        WireError(status: 409, googleStatus: "ALREADY_EXISTS", message: message)
    }

    static func permissionDenied(_ message: String) -> WireError {
        WireError(status: 403, googleStatus: "PERMISSION_DENIED", message: message)
    }

    static let unauthenticated = WireError(
        status: 401, googleStatus: "UNAUTHENTICATED",
        message: "Request had invalid authentication credentials.")

    var reply: Reply {
        var error: [String: Any] = ["code": status, "message": message, "status": googleStatus]
        if let reason {
            error["details"] = [
                [
                    "@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": reason,
                    "domain": "googleapis.com",
                ]
            ]
        }
        var reply = Reply.json(["error": error], status: status)
        if let retryAfter { reply.headers["Retry-After"] = String(retryAfter) }
        if status == 401 { reply.headers["WWW-Authenticate"] = "Bearer realm=\"https://accounts.google.com/\"" }
        return reply
    }
}
