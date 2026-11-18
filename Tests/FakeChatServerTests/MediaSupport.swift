import ChatModel
import ChatNet
import Foundation
import Testing

@testable import FakeChatServer

extension Data {
    init(_ text: String) { self.init(text.utf8) }
}

func multipartBody(
    boundary: String = "xyzBOUNDARY", metadata: String = #"{"filename":"photo.png"}"#, mediaType: String? = "image/png",
    payload: Data
) -> Data {
    var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(metadata)\r\n")
    body.append(Data("--\(boundary)\r\n"))
    if let mediaType { body.append(Data("Content-Type: \(mediaType)\r\n")) }
    body.append(Data("\r\n"))
    body.append(payload)
    body.append(Data("\r\n--\(boundary)--\r\n"))
    return body
}

extension Harness {
    @discardableResult
    func raw(
        _ method: HTTPMethod, host: String = "chat.googleapis.com", path: String, query: [String: String] = [:],
        headers: [String: String] = [:], body: Data? = nil, as account: FakeAccount?
    ) async throws -> Call {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0, value: $1) }
        }
        var all = headers
        if let account { all["Authorization"] = "Bearer \(account.token)" }
        let response = try await transport.send(
            HTTPRequest(method: method, url: components.url!, headers: all, body: body, maxResponseBytes: 64 << 20))
        return Call(status: response.status, headers: response.headers, body: response.body)
    }

    func upload(
        _ payload: Data, filename: String = "photo.png", type: String? = "image/png", to space: SpaceName? = nil,
        as account: FakeAccount? = nil, boundary: String = "xyzBOUNDARY"
    ) async throws -> Call {
        let body = multipartBody(
            boundary: boundary, metadata: #"{"filename":"\#(filename)"}"#, mediaType: type, payload: payload)
        return try await raw(
            .post, path: "/upload/v1/\((space ?? self.space).rawValue)/attachments:upload",
            query: ["uploadType": "multipart"],
            headers: ["Content-Type": "multipart/related; boundary=\(boundary)"], body: body, as: account ?? alice)
    }

    func download(_ resource: String, range: String? = nil, as account: FakeAccount?) async throws -> Call {
        try await raw(
            .get, path: "/v1/media/\(resource)", query: ["alt": "media"],
            headers: range.map { ["Range": $0] } ?? [:], as: account)
    }

    func uploaded(_ payload: Data, as account: FakeAccount? = nil, to space: SpaceName? = nil) async throws
        -> (resource: String, token: String)
    {
        let call = try await upload(payload, to: space, as: account)
        let ref = try #require(call.json["attachmentDataRef"] as? [String: Any])
        return (try #require(ref["resourceName"] as? String), try #require(ref["attachmentUploadToken"] as? String))
    }

    func createWithAttachment(_ token: String, in space: SpaceName? = nil, as account: FakeAccount? = nil)
        async throws -> Call
    {
        try await call(
            .post, "\((space ?? self.space).rawValue)/messages",
            body: ["attachment": [["attachmentDataRef": ["attachmentUploadToken": token]]]], as: account ?? alice)
    }
}

func bytes(_ count: Int, seed: UInt8 = 1) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &+ ($0 >> 8)) })
}
