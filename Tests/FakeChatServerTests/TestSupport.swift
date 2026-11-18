import ChatModel
import ChatNet
import Foundation

@testable import FakeChatServer

struct Call {
    var status: Int
    var headers: [String: String]
    var body: Data

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    func items(_ key: String) -> [[String: Any]] {
        json[key] as? [[String: Any]] ?? []
    }

    func names(_ key: String) -> [String] {
        items(key).compactMap { $0["name"] as? String }
    }

    var nextPageToken: String? { json["nextPageToken"] as? String }
    var errorStatus: String? { (json["error"] as? [String: Any])?["status"] as? String }
}

func ts(_ text: String) -> Timestamp { Timestamp(rfc3339: text)! }

let created = "google.workspace.chat.message.v1.created"
let updated = "google.workspace.chat.message.v1.updated"
let deleted = "google.workspace.chat.message.v1.deleted"
let reactionCreated = "google.workspace.chat.reaction.v1.created"
let reactionDeleted = "google.workspace.chat.reaction.v1.deleted"

/// A fake with three accounts and one space shared by alice and bob. carol is never a member.
struct Harness {
    let server = FakeChatServer()
    let transport: AuthTransport
    let alice: FakeAccount
    let bob: FakeAccount
    let carol: FakeAccount
    let space: SpaceName

    init() {
        transport = server.makeTransport()
        alice = server.addAccount(displayName: "Alice")
        bob = server.addAccount(displayName: "Bob")
        carol = server.addAccount(displayName: "Carol")
        space = server.addSpace(.space, displayName: "Team", members: [alice, bob])
    }

    @discardableResult
    func call(
        _ method: HTTPMethod = .get, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil,
        as account: FakeAccount?, token: String? = nil
    ) async throws -> Call {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "chat.googleapis.com"
        components.path = "/v1/" + path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0, value: $1) }
        }
        var headers: [String: String] = [:]
        if let bearer = token ?? account?.token { headers["Authorization"] = "Bearer \(bearer)" }
        var data: Data?
        if let body {
            data = try JSONSerialization.data(withJSONObject: body)
            headers["Content-Type"] = "application/json"
        }
        let response = try await transport.send(
            HTTPRequest(method: method, url: components.url!, headers: headers, body: data))
        return Call(status: response.status, headers: response.headers, body: response.body)
    }

    @discardableResult
    func get(
        _ path: String, _ query: [String: String] = [:], as account: FakeAccount?, token: String? = nil
    ) async throws -> Call {
        try await call(.get, path, query: query, as: account, token: token)
    }

    @discardableResult
    func listMessages(_ query: [String: String] = [:], as account: FakeAccount? = nil) async throws -> Call {
        try await get("\(space.rawValue)/messages", query, as: account ?? alice)
    }

    func create(
        _ text: String, query: [String: String] = [:], thread: ThreadName? = nil, as account: FakeAccount? = nil
    ) async throws -> Call {
        var body: [String: Any] = ["text": text]
        if let thread { body["thread"] = ["name": thread.rawValue] }
        return try await call(.post, "\(space.rawValue)/messages", query: query, body: body, as: account ?? alice)
    }

    func eventsFilter(start: String? = nil, end: String? = nil, types: [String] = [created]) -> String {
        var clauses: [String] = []
        if let start { clauses.append("startTime=\"\(start)\"") }
        if let end { clauses.append("endTime=\"\(end)\"") }
        clauses.append("(" + types.map { "eventTypes:\"\($0)\"" }.joined(separator: " OR ") + ")")
        return clauses.joined(separator: " AND ")
    }

    func listEvents(
        _ filter: String? = nil, _ extra: [String: String] = [:], as account: FakeAccount? = nil
    ) async throws -> Call {
        var query = extra
        query["filter"] = filter ?? eventsFilter()
        return try await get("\(space.rawValue)/spaceEvents", query, as: account ?? alice)
    }

    @discardableResult
    func seed(_ count: Int, from sender: FakeAccount? = nil) -> [Message] {
        (1...count).map { server.post("m\($0)", in: space, from: .account(sender ?? alice)) }
    }
}
