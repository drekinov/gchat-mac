import ChatModel
import ChatNet
import Foundation
import Synchronization
import Testing

@testable import GoogleChat

final class StubStreamingTransport: StreamingTransport, Sendable {
    enum Script: Sendable {
        case chunks(status: Int, headers: [String: String], [Data])
        case error(status: Int, body: Data)
        case failure(TransportError)
    }

    private struct State {
        var requests: [HTTPRequest] = []
        var scripts: [Script]
    }

    private let state: Mutex<State>

    init(_ scripts: [Script]) { state = Mutex(State(scripts: scripts)) }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }

    func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse {
        throw .other(code: -1)
    }

    func stream(
        _ request: HTTPRequest, onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws(TransportError) -> HTTPResponseHead {
        let script = state.withLock { state -> Script in
            state.requests.append(request)
            return state.scripts.count > 1 ? state.scripts.removeFirst() : state.scripts[0]
        }
        switch script {
        case .failure(let error):
            throw error
        case .error(let status, let body):
            return HTTPResponseHead(status: status, errorBody: body)
        case .chunks(let status, let headers, let chunks):
            var total = 0
            for chunk in chunks {
                do { try onChunk(chunk) } catch { throw .sinkFailed }
                total += chunk.count
            }
            return HTTPResponseHead(status: status, headers: headers, byteCount: total)
        }
    }
}

func mediaClient(_ transport: any HTTPTransport, tokens: StubTokens = StubTokens()) -> GoogleChatClient {
    GoogleChatClient(transport: transport, tokens: tokens, baseURL: URL(string: "https://chat.test")!)
}

final class ChunkSink: Sendable {
    private let received = Mutex(Data())
    private let calls = Mutex(0)
    func add(_ chunk: Data) {
        received.withLock { $0.append(chunk) }
        calls.withLock { $0 += 1 }
    }
    var data: Data { received.withLock { $0 } }
    var callCount: Int { calls.withLock { $0 } }
}

@Suite struct MediaUploadTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func file(_ content: Data = Data("hello".utf8), name: String = "in.bin") throws -> URL {
        let url = directory.appending(path: name)
        try content.write(to: url)
        return url
    }

    func uploadOK(_ token: String = "tok-1", name: String? = "spaces/AAAA/attachments/x") -> Result<
        HTTPResponse, TransportError
    > {
        let resource = name.map { #""resourceName":"\#($0)","# } ?? ""
        return .success(
            HTTPResponse(
                status: 200,
                body: Data(#"{"attachmentDataRef":{\#(resource)"attachmentUploadToken":"\#(token)"}}"#.utf8)))
    }

    func boundary(of request: HTTPRequest) -> String? {
        request.headers["Content-Type"]?.components(separatedBy: "boundary=").last
    }

    @Test func sendsExactMultipartRelatedBody() async throws {
        let content = Data("RAW\r\nBYTES".utf8)
        let transport = StubTransport([uploadOK()])
        let result = try await mediaClient(transport).uploadAttachment(
            to: testSpace, file: try file(content), filename: "report.pdf", contentType: "application/pdf")
        #expect(result.uploadToken == "tok-1")
        #expect(result.resourceName?.rawValue == "spaces/AAAA/attachments/x")

        let request = try #require(transport.requests.first)
        let boundary = try #require(boundary(of: request))
        #expect(request.method == .post)
        #expect(
            request.url.absoluteString
                == "https://chat.test/upload/v1/spaces/AAAA/attachments:upload?uploadType=multipart")
        #expect(request.headers["Content-Type"] == "multipart/related; boundary=\(boundary)")
        #expect(request.headers["Authorization"] == "Bearer token-1")
        #expect(request.body == nil)
        let body = try #require(request.bodyFile)
        #expect(body.file.lastPathComponent == "in.bin")
        #expect(body.opened?.identity.size == Int64(content.count))
        let prefix = String(decoding: body.prefix, as: UTF8.self)
        #expect(
            prefix == "--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n"
                + #"{"filename":"report.pdf"}"# + "\r\n--\(boundary)\r\nContent-Type: application/pdf\r\n\r\n")
        #expect(String(decoding: body.suffix, as: UTF8.self) == "\r\n--\(boundary)--\r\n")
    }

    @Test func boundariesAreUniquePerRequestAndUnguessable() async throws {
        var seen = Set<String>()
        for _ in 0..<200 { seen.insert(GoogleChatClient.makeBoundary()) }
        #expect(seen.count == 200)
        #expect(seen.allSatisfy { $0.count == 38 && $0.hasPrefix("gchat-") })

        let transport = StubTransport([uploadOK()])
        let client = mediaClient(transport)
        let source = try file()
        for _ in 0..<2 {
            _ = try await client.uploadAttachment(to: testSpace, file: source, filename: "a", contentType: "text/plain")
        }
        let boundaries = transport.requests.compactMap(boundary(of:))
        #expect(boundaries.count == 2)
        #expect(boundaries[0] != boundaries[1])
    }

    @Test(arguments: [
        ("plain.txt", "plain.txt"),
        ("a\r\nb.txt", "a__b.txt"),
        ("say \"hi\".txt", "say _hi_.txt"),
        ("tab\there.txt", "tab_here.txt"),
        ("nul\u{0}.txt", "nul_.txt"),
        ("../../etc/passwd", ".._.._etc_passwd"),
        ("back\\slash.txt", "back_slash.txt"),
        ("evil\u{202E}fdp.exe", "evil_fdp.exe"),
        ("  padded.txt  ", "padded.txt"),
        ("", "file"),
        ("..", "file"),
        ("   ", "file"),
        ("снимка.png", "снимка.png"),
    ])
    func sanitizesFilenames(input: String, expected: String) {
        #expect(GoogleChatClient.sanitizedFilename(input) == expected)
    }

    @Test func longFilenamesKeepTheExtensionAndStayWithinBytes() {
        let long = String(repeating: "я", count: 300) + ".jpeg"
        let result = GoogleChatClient.sanitizedFilename(long)
        #expect(result.utf8.count <= 255)
        #expect(result.hasSuffix(".jpeg"))
        #expect(String(decoding: Array(result.utf8), as: UTF8.self) == result)
        let noExtension = GoogleChatClient.sanitizedFilename(String(repeating: "x", count: 1000))
        #expect(noExtension.utf8.count == 255)
    }

    @Test func sanitizedNameReachesTheJSONPart() async throws {
        let transport = StubTransport([uploadOK()])
        _ = try await mediaClient(transport).uploadAttachment(
            to: testSpace, file: try file(), filename: "x\r\n\"y\".txt", contentType: "text/plain")
        let prefix = String(decoding: try #require(transport.requests.first?.bodyFile).prefix, as: UTF8.self)
        #expect(prefix.contains(#"{"filename":"x___y_.txt"}"#))
        #expect(!prefix.contains("\"y\""))
    }

    @Test(arguments: [
        ("image/png", "image/png"), ("IMAGE/PNG", "image/png"), (" text/plain ", "text/plain"),
        ("application/vnd.api+json", "application/vnd.api+json"),
        ("", "application/octet-stream"), ("png", "application/octet-stream"),
        ("text/plain; charset=utf-8", "application/octet-stream"), ("a/b/c", "application/octet-stream"),
        ("text/pl\r\nain", "application/octet-stream"), ("text/", "application/octet-stream"),
        ("/png", "application/octet-stream"), ("te xt/plain", "application/octet-stream"),
        ("text/plain\r\nX: y", "application/octet-stream"),
    ])
    func validatesContentType(input: String, expected: String) {
        #expect(GoogleChatClient.validContentType(input) == expected)
    }

    @Test func invalidContentTypeIsWrittenAsOctetStream() async throws {
        let transport = StubTransport([uploadOK()])
        _ = try await mediaClient(transport).uploadAttachment(
            to: testSpace, file: try file(), filename: "a", contentType: "x\r\nInjected: 1")
        let prefix = String(decoding: try #require(transport.requests.first?.bodyFile).prefix, as: UTF8.self)
        #expect(prefix.hasSuffix("Content-Type: application/octet-stream\r\n\r\n"))
        #expect(!prefix.contains("Injected"))
    }

    @Test func oversizedFileIsRejectedBeforeAnythingIsSent() async throws {
        let url = directory.appending(path: "huge.bin")
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(200 * 1024 * 1024 + 1))
        try handle.close()
        let transport = StubTransport([uploadOK()])
        let tokens = StubTokens()
        let error = await thrownError {
            try await mediaClient(transport, tokens: tokens).uploadAttachment(
                to: testSpace, file: url, filename: "huge", contentType: "application/zip")
        }
        guard case .invalidArgument(let info) = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
        #expect(info.status == "CLIENT_FILE_TOO_LARGE")
        #expect(transport.requests.isEmpty)

        try FileHandle(forWritingTo: url).truncate(atOffset: UInt64(200 * 1024 * 1024))
        _ = try await mediaClient(transport).uploadAttachment(
            to: testSpace, file: url, filename: "edge", contentType: "application/zip")
        #expect(transport.requests.count == 1)
    }

    @Test func theUploadedFileIsOpenedOnceAndThatDescriptorTravelsWithTheRequest() async throws {
        let source = try file(Data("abc".utf8))
        let transport = StubTransport([
            .success(HTTPResponse(status: 401)), uploadOK(),
        ])
        _ = try await mediaClient(transport).uploadAttachment(
            to: testSpace, file: source, filename: "a", contentType: "text/plain")
        let bodies = transport.requests.compactMap(\.bodyFile)
        #expect(bodies.count == 2)
        #expect(bodies[0].opened != nil)
        #expect(bodies[0].opened === bodies[1].opened)
        let replacement = directory.appending(path: "other.bin")
        try Data("zzzzzz".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(source, withItemAt: replacement)
        #expect(bodies[0].opened?.identity.size == 3)
    }

    @Test func aFIFOIsRefusedWithoutBlocking() async {
        let fifo = directory.appending(path: "pipe")
        mkfifo(fifo.path(percentEncoded: false), 0o600)
        let transport = StubTransport([uploadOK()])
        let error = await thrownError {
            try await mediaClient(transport).uploadAttachment(
                to: testSpace, file: fifo, filename: "a", contentType: "text/plain")
        }
        #expect(error == .transport(.requestBodyUnavailable))
        #expect(transport.requests.isEmpty)
    }

    @Test func missingOrNonRegularFilesNeverReachTheNetwork() async {
        let transport = StubTransport([uploadOK()])
        for url in [directory.appending(path: "absent"), directory, URL(string: "https://evil.example/x")!] {
            let error = await thrownError {
                try await mediaClient(transport).uploadAttachment(
                    to: testSpace, file: url, filename: "a", contentType: "text/plain")
            }
            #expect(error == .transport(.requestBodyUnavailable))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func refreshesOnceOn401WithTheSameBody() async throws {
        let unauthorized = Result<HTTPResponse, TransportError>.success(HTTPResponse(status: 401))
        let transport = StubTransport([unauthorized, uploadOK()])
        let tokens = StubTokens()
        _ = try await mediaClient(transport, tokens: tokens).uploadAttachment(
            to: testSpace, file: try file(), filename: "a", contentType: "text/plain")
        #expect(tokens.invalidated == ["token-1"])
        #expect(transport.requests.map { $0.headers["Authorization"] } == ["Bearer token-1", "Bearer token-2"])
        #expect(transport.requests[0].bodyFile == transport.requests[1].bodyFile)
        #expect(boundary(of: transport.requests[0]) == boundary(of: transport.requests[1]))
    }

    @Test func secondUnauthorizedSurfaces() async throws {
        let unauthorized = Result<HTTPResponse, TransportError>.success(HTTPResponse(status: 401))
        let transport = StubTransport([unauthorized, unauthorized, uploadOK()])
        let source = try file()
        let error = await thrownError {
            try await mediaClient(transport).uploadAttachment(
                to: testSpace, file: source, filename: "a", contentType: "text/plain")
        }
        #expect(error == .unauthorized)
        #expect(transport.requests.count == 2)
    }

    @Test func mapsHTTPAndTransportErrors() async throws {
        let source = try file()
        func upload(_ result: Result<HTTPResponse, TransportError>) async -> ChatAPIError? {
            await thrownError {
                try await mediaClient(StubTransport([result])).uploadAttachment(
                    to: testSpace, file: source, filename: "a", contentType: "text/plain")
            }
        }
        let denied = HTTPResponse(status: 403, body: Data(#"{"error":{"status":"PERMISSION_DENIED"}}"#.utf8))
        guard case .permissionDenied(let info) = await upload(.success(denied)) else {
            Issue.record("403")
            return
        }
        #expect(info.status == "PERMISSION_DENIED")
        let limited = HTTPResponse(status: 429, headers: ["Retry-After": "7"])
        #expect(await upload(.success(limited)) == .rateLimited(retryAfter: .seconds(7)))
        guard case .server = await upload(.success(HTTPResponse(status: 503))) else {
            Issue.record("503")
            return
        }
        #expect(await upload(.failure(.timedOut)) == .transport(.timedOut))
        #expect(await upload(.failure(.connectionLost)) == .transport(.connectionLost))
        #expect(
            await upload(.failure(.redirected(status: 302, location: URL(string: "https://x.example/secret")!)))
                == .transport(.redirected(status: 302, location: nil)))
    }

    @Test func badSuccessBodiesAreDecodingErrors() async throws {
        let source = try file()
        func upload(_ body: String) async -> ChatAPIError? {
            await thrownError {
                try await mediaClient(StubTransport(status: 200, body: Data(body.utf8))).uploadAttachment(
                    to: testSpace, file: source, filename: "a", contentType: "text/plain")
            }
        }
        #expect(await upload("{}") == .decoding(path: ""))
        #expect(
            await upload(#"{"attachmentDataRef":{"resourceName":"x"}}"#) == .decoding(path: "attachmentDataRef"))
        #expect(
            await upload(#"{"attachmentDataRef":{"attachmentUploadToken":""}}"#)
                == .decoding(path: "attachmentDataRef.attachmentUploadToken"))
        let result = try await mediaClient(
            StubTransport(
                status: 200,
                body: Data(#"{"attachmentDataRef":{"resourceName":"bad name?","attachmentUploadToken":"t"}}"#.utf8))
        ).uploadAttachment(to: testSpace, file: source, filename: "a", contentType: "text/plain")
        #expect(result.resourceName == nil)
        #expect(result.uploadToken == "t")
    }
}

@Suite struct MediaDownloadTests {
    let media = MediaResourceName("abc/DEF-1")!

    @Test func encodesEachPathSegmentAndKeepsSlashes() async throws {
        let transport = StubStreamingTransport([.chunks(status: 200, headers: [:], [])])
        let name = try #require(MediaResourceName("a+b/c=d%/e:f.g_h~i"))
        _ = try await mediaClient(transport).downloadMedia(name, maxBytes: 1000) { _ in }
        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://chat.test/v1/media/a%2Bb/c%3Dd%25/e%3Af.g_h~i?alt=media")
        #expect(request.method == .get)
        #expect(request.headers["Authorization"] == "Bearer token-1")
        #expect(request.maxResponseBytes == 1000)
    }

    @Test func dotSegmentsAreRefused() async throws {
        let transport = StubStreamingTransport([.chunks(status: 200, headers: [:], [])])
        let name = try #require(MediaResourceName("abc/./def"))
        let error = await thrownError {
            try await mediaClient(transport).downloadMedia(name, maxBytes: 10) { _ in }
        }
        guard case .invalidArgument = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func streamsChunksAndReportsTypeAndCount() async throws {
        let transport = StubStreamingTransport([
            .chunks(status: 200, headers: ["content-type": "image/jpeg"], [Data("ab".utf8), Data("cde".utf8)])
        ])
        let sink = ChunkSink()
        let result = try await mediaClient(transport).downloadMedia(media, maxBytes: 100) { sink.add($0) }
        #expect(result == MediaDownload(contentType: "image/jpeg", byteCount: 5, redirect: nil))
        #expect(sink.data == Data("abcde".utf8))
        #expect(sink.callCount == 2)
    }

    @Test func fallsBackToBufferedTransportsAsOneChunk() async throws {
        let transport = StubTransport(status: 200, headers: ["content-type": "image/png"], body: Data("12345".utf8))
        let sink = ChunkSink()
        let result = try await mediaClient(transport).downloadMedia(media, maxBytes: 100) { sink.add($0) }
        #expect(result.byteCount == 5)
        #expect(result.contentType == "image/png")
        #expect(sink.callCount == 1)
        #expect(transport.requests.first?.maxResponseBytes == 100)
    }

    @Test func redirectIsHandedOffWithoutBytesOrError() async throws {
        let location = URL(string: "https://lh3.googleusercontent.com/token-in-url")!
        let streaming = StubStreamingTransport([.failure(.redirected(status: 302, location: location))])
        let sink = ChunkSink()
        let result = try await mediaClient(streaming).downloadMedia(media, maxBytes: 100) { sink.add($0) }
        #expect(result == MediaDownload(contentType: nil, byteCount: 0, redirect: location))
        #expect(sink.callCount == 0)
        #expect(streaming.requests.count == 1)

        let buffered = StubTransport([.failure(.redirected(status: 307, location: location))])
        let viaSend = try await mediaClient(buffered).downloadMedia(media, maxBytes: 100) { _ in }
        #expect(viaSend.redirect == location)
        #expect(buffered.requests.count == 1)
    }

    @Test func redirectWithoutLocationIsAnErrorThatCarriesNoURL() async {
        let transport = StubStreamingTransport([.failure(.redirected(status: 302, location: nil))])
        let error = await thrownError { try await mediaClient(transport).downloadMedia(media, maxBytes: 10) { _ in } }
        #expect(error == .transport(.redirected(status: 302, location: nil)))
    }

    @Test func refreshesOnceOn401() async throws {
        let transport = StubStreamingTransport([
            .error(status: 401, body: Data()), .chunks(status: 200, headers: [:], [Data("x".utf8)]),
        ])
        let tokens = StubTokens()
        let sink = ChunkSink()
        _ = try await mediaClient(transport, tokens: tokens).downloadMedia(media, maxBytes: 10) { sink.add($0) }
        #expect(tokens.invalidated == ["token-1"])
        #expect(transport.requests.map { $0.headers["Authorization"] } == ["Bearer token-1", "Bearer token-2"])
        #expect(sink.data == Data("x".utf8))
    }

    @Test func secondUnauthorizedSurfaces() async {
        let transport = StubStreamingTransport([.error(status: 401, body: Data())])
        let error = await thrownError { try await mediaClient(transport).downloadMedia(media, maxBytes: 10) { _ in } }
        #expect(error == .unauthorized)
        #expect(transport.requests.count == 2)
    }

    @Test func mapsErrorStatusesFromTheCappedBody() async {
        func download(_ script: StubStreamingTransport.Script) async -> ChatAPIError? {
            await thrownError {
                try await mediaClient(StubStreamingTransport([script])).downloadMedia(media, maxBytes: 10) { _ in }
            }
        }
        let notFound = Data(#"{"error":{"status":"NOT_FOUND","message":"CANARY"}}"#.utf8)
        guard case .notFound(let info) = await download(.error(status: 404, body: notFound)) else {
            Issue.record("404")
            return
        }
        #expect(info.status == "NOT_FOUND")
        guard case .permissionDenied = await download(.error(status: 403, body: Data())) else {
            Issue.record("403")
            return
        }
        #expect(await download(.failure(.responseTooLarge)) == .transport(.responseTooLarge))
        #expect(await download(.failure(.offline)) == .transport(.offline))
    }

    @Test func aThrowingSinkSurfacesAsSinkFailed() async {
        struct Boom: Error {}
        let transport = StubStreamingTransport([.chunks(status: 200, headers: [:], [Data("x".utf8)])])
        let error = await thrownError {
            try await mediaClient(transport).downloadMedia(media, maxBytes: 10) { _ in throw Boom() }
        }
        #expect(error == .transport(.sinkFailed))
        let buffered = StubTransport(status: 200, body: Data("x".utf8))
        let viaSend = await thrownError {
            try await mediaClient(buffered).downloadMedia(media, maxBytes: 10) { _ in throw Boom() }
        }
        #expect(viaSend == .transport(.sinkFailed))
    }
}
