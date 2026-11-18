import ChatModel
import Foundation
import Synchronization

struct MediaRecord: Sendable {
    enum Storage: Sendable {
        case memory(Data)
        case file(URL)
    }

    static let fileThresholdBytes = 8 * 1024 * 1024

    var resource: MediaResourceName
    var filename: String
    var contentType: String
    var size: Int
    var storage: Storage
    /// Spaces whose members may download it: the upload space, plus any space a message attached it in.
    var spaces: Set<SpaceName> = []
    var redirectToken: String

    func bytes(_ range: Range<Int>) -> Data {
        switch storage {
        case .memory(let data):
            return data.subdata(in: range)
        case .file(let url):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(range.lowerBound))
            return (try? handle.read(upToCount: range.count)) ?? Data()
        }
    }
}

struct UploadToken: Sendable {
    var resource: String
    var space: SpaceName
}

extension State {
    mutating func addMedia(
        _ data: Data, contentType: String, filename: String, space: SpaceName?
    ) -> MediaResourceName {
        let resource = MediaResourceName("fake-media/\(newID())")!
        let storage: MediaRecord.Storage
        if data.count > MediaRecord.fileThresholdBytes {
            let directory =
                mediaDirectory
                ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("gchat-fake-media-\(UUID().uuidString)", isDirectory: true)
            mediaDirectory = directory
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(UUID().uuidString)
            if FileManager.default.createFile(
                atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
            {
                storage = .file(url)
            } else {
                storage = .memory(data)
            }
        } else {
            storage = .memory(data)
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        media[resource.rawValue] = MediaRecord(
            resource: resource, filename: filename, contentType: contentType, size: data.count, storage: storage,
            spaces: space.map { [$0] } ?? [], redirectToken: token)
        mediaByRedirectToken[token] = resource.rawValue
        return resource
    }

    mutating func uploadAttachment(
        _ name: SpaceName, _ incoming: IncomingRequest, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        _ = try requireSpace(name, account)
        guard incoming.value("uploadType") == "multipart" else {
            throw .invalidArgument("Only uploadType=multipart is supported")
        }
        guard let contentType = incoming.header("content-type"), let boundary = Multipart.boundary(from: contentType)
        else { throw .invalidArgument("Content-Type must be multipart/related with a boundary") }
        guard let body = incoming.body, let parts = Multipart.parse(body, boundary: boundary), parts.count == 2 else {
            throw .invalidArgument("Malformed multipart body: expected a metadata part and a media part")
        }
        let metadata = body.subdata(in: parts[0].range)
        guard let json = (try? JSONSerialization.jsonObject(with: metadata)) as? JSON,
            let filename = json["filename"] as? String, !filename.isEmpty
        else { throw .invalidArgument("The metadata part must be JSON with a filename") }
        guard parts[1].range.count <= maxUploadBytes else {
            throw .invalidArgument("Attachment exceeds the \(maxUploadBytes) byte limit")
        }
        let mediaType = parts[1].headers["content-type"] ?? "application/octet-stream"
        let resource = addMedia(
            body.subdata(in: parts[1].range), contentType: mediaType, filename: filename, space: name)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        uploadTokens[token] = UploadToken(resource: resource.rawValue, space: name)
        return .json([
            "attachmentDataRef": ["resourceName": resource.rawValue, "attachmentUploadToken": token] as JSON
        ])
    }

    func downloadMedia(
        _ resource: MediaResourceName, _ incoming: IncomingRequest, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        guard let record = media[resource.rawValue] else { throw .notFound("Media not found: \(resource)") }
        guard record.spaces.contains(where: { spaces[$0]?.isMember(account.user.name) == true }) else {
            throw .permissionDenied("The caller does not have permission")
        }
        guard incoming.value("alt") == "media" else { return .json(["resourceName": resource.rawValue]) }
        if let host = mediaRedirectHost {
            return Reply(
                status: 302, headers: ["Location": "https://\(host)/\(record.redirectToken)"], body: Data())
        }
        return Self.mediaReply(record, range: incoming.header("range"))
    }

    mutating func serveMediaHost(token: String, _ incoming: IncomingRequest) -> Reply {
        let hadCredentials = incoming.header("authorization") != nil || incoming.header("cookie") != nil
        let record = mediaByRedirectToken[token].flatMap { media[$0] }
        let reply =
            record.map { Self.mediaReply($0, range: incoming.header("range")) }
            ?? Reply(status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not found".utf8))
        mediaHostRequests.append(
            MediaHostRequest(
                host: incoming.host, path: incoming.path, hadCredentials: hadCredentials,
                range: incoming.header("range"),
                status: reply.status))
        return reply
    }

    static func mediaReply(_ record: MediaRecord, range header: String?) -> Reply {
        var headers = ["Content-Type": record.contentType, "Accept-Ranges": "bytes"]
        guard let header, let spec = ByteRange.parse(header) else {
            return Reply(status: 200, headers: headers, body: record.bytes(0..<record.size))
        }
        guard let range = spec.resolve(size: record.size) else {
            headers["Content-Range"] = "bytes */\(record.size)"
            return Reply(status: 416, headers: headers, body: Data())
        }
        headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(record.size)"
        return Reply(status: 206, headers: headers, body: record.bytes(range))
    }
}

/// A single `bytes=` range. Multi-range and malformed headers are ignored, like a server that doesn't support them.
struct ByteRange {
    var first: Int?
    var last: Int?

    static func parse(_ header: String) -> ByteRange? {
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes="), !text.contains(",") else { return nil }
        let pair = text.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        let first = pair[0].isEmpty ? nil : Int(pair[0])
        let last = pair[1].isEmpty ? nil : Int(pair[1])
        guard first != nil || last != nil, pair[0].isEmpty == (first == nil), pair[1].isEmpty == (last == nil),
            (first ?? 0) >= 0, (last ?? 0) >= 0
        else { return nil }
        return ByteRange(first: first, last: last)
    }

    /// Nil when unsatisfiable.
    func resolve(size: Int) -> Range<Int>? {
        switch (first, last) {
        case (let first?, let last?):
            guard first <= last, first < size else { return nil }
            return first..<min(last + 1, size)
        case (let first?, nil):
            return first < size ? first..<size : nil
        case (nil, let suffix?):
            guard suffix > 0, size > 0 else { return nil }
            return max(size - suffix, 0)..<size
        case (nil, nil):
            return nil
        }
    }
}

/// Finds the live server that issued a redirect token. Tokens are random, so they identify one server.
enum ServerList {
    struct Entry: Sendable {
        weak let server: FakeChatServer?
    }

    private static let entries = Mutex<[Entry]>([])

    static func add(_ server: FakeChatServer) {
        entries.withLock { entries in
            entries.removeAll { $0.server == nil }
            entries.append(Entry(server: server))
        }
    }

    static var live: [FakeChatServer] {
        entries.withLock { $0.compactMap(\.server) }
    }
}

/// Serves the redirect targets handed out when `mediaRedirectHost` is set: `https://<host>/<token>`, no auth.
public final class FakeMediaHost: URLProtocol, @unchecked Sendable {
    public override class func canInit(with request: URLRequest) -> Bool { true }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let incoming = IncomingRequest(
            method: request.httpMethod ?? "GET", host: url.host()?.lowercased() ?? "", path: url.path,
            query: [], headers: request.allHTTPHeaderFields ?? [:], body: nil)
        let token = String(url.path.dropFirst())
        let reply = incoming.method == "GET" ? FakeChatServer.serveMediaHost(token: token, incoming) : nil
        guard let reply else {
            let response = HTTPURLResponse(
                url: url, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var headers = reply.headers
        headers["Content-Length"] = String(reply.body.count)
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    public override func stopLoading() {}
}
