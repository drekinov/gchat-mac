import Foundation
import Network
import Synchronization
import Testing

@testable import ChatNet

/// Reads the request's body stream to the end, recording what it saw.
final class BodyCountingProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        var bytes = 0
        var captured = Data()
        var contentLength: String?
        var peakFootprint = 0
        var method: String?
    }

    static let seen = Mutex<[String: Seen]>([:])
    static let captureLimit = 1 << 20

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var record = Seen(
            contentLength: request.value(forHTTPHeaderField: "Content-Length"), method: request.httpMethod)
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var reads = 0
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                reads += 1
                record.bytes += count
                if record.captured.count < Self.captureLimit {
                    record.captured.append(
                        contentsOf: buffer[0..<min(count, Self.captureLimit - record.captured.count)])
                }
                if reads.isMultiple(of: 16) { record.peakFootprint = max(record.peakFootprint, physFootprint()) }
            }
            record.peakFootprint = max(record.peakFootprint, physFootprint())
            stream.close()
        }
        Self.seen.withLock { $0[request.url?.path ?? ""] = record }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class Counter: Sendable {
    private let value = Mutex(0)
    func bump() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

final class HookedBodyProtocol: URLProtocol, @unchecked Sendable {
    /// Runs once after the first 64 KiB of the body have been read.
    static let afterFirstRead = Mutex<(@Sendable () -> Void)?>(nil)
    static let finished = Mutex<[String: Int]>([:])
    /// Runs after the body has been fully read and before the response is delivered.
    static let beforeResponse = Mutex<(@Sendable () -> Void)?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stream = request.httpBodyStream else { return }
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total = 0
        var first = true
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                client?.urlProtocol(self, didFailWithError: stream.streamError ?? URLError(.networkConnectionLost))
                return
            }
            if count == 0 { break }
            total += count
            if first {
                first = false
                Self.afterFirstRead.withLock { $0 }?()
            }
        }
        Self.beforeResponse.withLock { $0 }?()
        Self.finished.withLock { $0[request.url?.path ?? ""] = total }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct CompositeInputStreamTests {
    let directory: URL

    init() throws { directory = try makeTempDirectory() }

    func write(_ data: Data, name: String = "f.bin") throws -> URL {
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    func stream(
        prefix: String = "", _ url: URL, suffix: String = "", violations: Counter? = nil
    ) throws -> (CompositeInputStream, OpenedFile) {
        let opened = try OpenedFile.open(url)
        let stream = CompositeInputStream(
            prefix: Data(prefix.utf8), file: opened, identity: opened.identity, suffix: Data(suffix.utf8)
        ) { violations?.bump() }
        return (stream, opened)
    }

    func drain(_ stream: InputStream, readSize: Int = 100_000) -> (data: Data, reads: [Int]) {
        stream.open()
        defer { stream.close() }
        var out = Data()
        var reads: [Int] = []
        var buffer = [UInt8](repeating: 0, count: readSize)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            reads.append(count)
            out.append(contentsOf: buffer[0..<count])
        }
        return (out, reads)
    }

    @Test func concatenatesPrefixFileAndSuffixInSmallReads() throws {
        let file = Data((0..<200_000).map { UInt8($0 % 251) })
        let (stream, _) = try stream(prefix: "head", try write(file), suffix: "tail")
        let (data, reads) = drain(stream)
        #expect(data == Data("head".utf8) + file + Data("tail".utf8))
        #expect(stream.totalLength == file.count + 8)
        #expect(reads.max()! <= 64 * 1024)
        #expect(stream.streamStatus == .closed)
    }

    @Test func emptyFileKeepsPrefixAndSuffix() throws {
        let (stream, _) = try stream(prefix: "a", try write(Data()), suffix: "b")
        #expect(drain(stream).data == Data("ab".utf8))
    }

    @Test func aFileTruncatedAfterOpenFailsTheStreamAndReportsIt() throws {
        let url = try write(Data(count: 100))
        let violations = Counter()
        let (stream, _) = try stream(url, violations: violations)
        try Data(count: 10).write(to: url)
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 64)
        #expect(stream.read(&buffer, maxLength: 64) == -1)
        #expect(stream.streamStatus == .error)
        #expect(stream.streamError != nil)
        #expect(violations.count == 1)
    }

    @Test func aFileModifiedInPlaceAfterOpenFailsEvenAtTheSameSize() throws {
        let url = try write(Data(repeating: 1, count: 100))
        let (stream, _) = try stream(url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 64)
        #expect(stream.read(&buffer, maxLength: 64) == -1)
    }

    @Test func aFileModifiedMidReadFailsTheNextRead() throws {
        let url = try write(Data(repeating: 1, count: 200_000))
        let (stream, _) = try stream(url)
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        #expect(stream.read(&buffer, maxLength: buffer.count) == 64 * 1024)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data([9]))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        #expect(stream.read(&buffer, maxLength: buffer.count) == -1)
    }

    @Test func replacingThePathAfterOpenFailsClosedBecauseTheStatusChangeTimeMoves() throws {
        let original = Data((0..<1000).map { UInt8($0 % 200) })
        let url = try write(original)
        let (stream, _) = try stream(url)
        let replacement = directory.appending(path: "other.bin")
        try Data(repeating: 0xEE, count: 1000).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 2000)
        #expect(stream.read(&buffer, maxLength: 2000) == -1)
    }

    @Test func streamsOverOneDescriptorReadIndependently() throws {
        let content = Data((0..<150_000).map { UInt8($0 % 251) })
        let url = try write(content)
        let opened = try OpenedFile.open(url)
        func make() -> CompositeInputStream {
            CompositeInputStream(prefix: Data(), file: opened, identity: opened.identity, suffix: Data())
        }
        let first = make()
        let second = make()
        first.open()
        second.open()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        _ = first.read(&buffer, maxLength: buffer.count)
        #expect(drain(second).data == content)
        var rest = Data()
        while true {
            let count = first.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            rest.append(contentsOf: buffer[0..<count])
        }
        #expect(rest == content.dropFirst(64 * 1024))
    }

    @Test func openingRejectsMissingDirectoriesAndNonFileURLs() {
        #expect(throws: TransportError.requestBodyUnavailable) {
            _ = try OpenedFile.open(directory.appending(path: "x"))
        }
        #expect(throws: TransportError.requestBodyUnavailable) { _ = try OpenedFile.open(directory) }
        #expect(throws: TransportError.requestBodyUnavailable) {
            _ = try OpenedFile.open(URL(string: "https://example.com/x")!)
        }
    }

    @Test func openingAFIFODoesNotBlock() throws {
        let fifo = directory.appending(path: "pipe")
        #expect(mkfifo(fifo.path(percentEncoded: false), 0o600) == 0)
        #expect(throws: TransportError.requestBodyUnavailable) { _ = try OpenedFile.open(fifo) }
    }
}

@Suite(.serialized) struct StreamedUploadTests {
    let directory: URL
    let transport = AuthTransport(allowedHosts: ["chat.googleapis.com"], protocolClasses: [BodyCountingProtocol.self])

    init() throws { directory = try makeTempDirectory() }

    func upload(path: String, body: FileBody) async throws -> HTTPResponse {
        try await transport.send(
            HTTPRequest(
                method: .post, url: URL(string: "https://chat.googleapis.com\(path)")!, bodyFile: body))
    }

    @Test func sendsPrefixFileSuffixWithExactContentLength() async throws {
        let file = directory.appending(path: "a.bin")
        let content = Data((0..<150_000).map { UInt8($0 % 241) })
        try content.write(to: file)
        let body = FileBody(prefix: Data("PRE".utf8), file: file, suffix: Data("SUF".utf8))
        _ = try await upload(path: "/up/exact", body: body)
        let seen = BodyCountingProtocol.seen.withLock { $0["/up/exact"] }!
        #expect(seen.captured == Data("PRE".utf8) + content + Data("SUF".utf8))
        #expect(seen.contentLength == String(content.count + 6))
        #expect(seen.method == "POST")
    }

    @Test func anOpenedFileBodyIsSentFromItsDescriptor() async throws {
        let file = directory.appending(path: "o.bin")
        let content = Data((0..<90_000).map { UInt8($0 % 233) })
        try content.write(to: file)
        let opened = try OpenedFile.open(file)
        _ = try await upload(path: "/up/opened", body: FileBody(opened: opened))
        #expect(BodyCountingProtocol.seen.withLock { $0["/up/opened"] }?.captured == content)
    }

    @Test func aPathReplacedAfterOpeningFailsClosedWithoutARequest() async throws {
        let file = directory.appending(path: "o3.bin")
        try Data(repeating: 1, count: 5000).write(to: file)
        let opened = try OpenedFile.open(file)
        let replacement = directory.appending(path: "o4.bin")
        try Data(repeating: 0xEE, count: 5000).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        await #expect(throws: TransportError.requestBodyUnavailable) {
            try await upload(path: "/up/replaced", body: FileBody(opened: opened))
        }
        #expect(BodyCountingProtocol.seen.withLock { $0["/up/replaced"] } == nil)
    }

    @Test func aFileChangedBeforeSendingFailsClosedWithoutARequest() async throws {
        let file = directory.appending(path: "p.bin")
        try Data(count: 5000).write(to: file)
        let opened = try OpenedFile.open(file)
        try Data(count: 4000).write(to: file)
        await #expect(throws: TransportError.requestBodyUnavailable) {
            try await upload(path: "/up/changed-before", body: FileBody(opened: opened))
        }
        #expect(BodyCountingProtocol.seen.withLock { $0["/up/changed-before"] } == nil)
    }

    @Test func aFileTruncatedMidUploadFailsWithRequestBodyUnavailable() async throws {
        let file = directory.appending(path: "m.bin")
        try Data(count: 300_000).write(to: file)
        HookedBodyProtocol.afterFirstRead.withLock {
            $0 = { try? Data(count: 10).write(to: file) }
        }
        defer { HookedBodyProtocol.afterFirstRead.withLock { $0 = nil } }
        let hooked = AuthTransport(allowedHosts: ["chat.googleapis.com"], protocolClasses: [HookedBodyProtocol.self])
        await #expect(throws: TransportError.requestBodyUnavailable) {
            try await hooked.send(
                HTTPRequest(
                    method: .post, url: URL(string: "https://chat.googleapis.com/up/mid-truncate")!,
                    bodyFile: FileBody(file: file)))
        }
        #expect(HookedBodyProtocol.finished.withLock { $0["/up/mid-truncate"] } == nil)
    }

    @Test func aFileModifiedMidUploadFailsWithRequestBodyUnavailable() async throws {
        let file = directory.appending(path: "mm.bin")
        try Data(count: 300_000).write(to: file)
        HookedBodyProtocol.afterFirstRead.withLock {
            $0 = {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: file.path)
            }
        }
        defer { HookedBodyProtocol.afterFirstRead.withLock { $0 = nil } }
        let hooked = AuthTransport(allowedHosts: ["chat.googleapis.com"], protocolClasses: [HookedBodyProtocol.self])
        await #expect(throws: TransportError.requestBodyUnavailable) {
            try await hooked.send(
                HTTPRequest(
                    method: .post, url: URL(string: "https://chat.googleapis.com/up/mid-touch")!,
                    bodyFile: FileBody(file: file)))
        }
    }

    @Test func bodyFileWinsOverBody() async throws {
        let file = directory.appending(path: "b.bin")
        try Data("file".utf8).write(to: file)
        let response = try await transport.send(
            HTTPRequest(
                method: .post, url: URL(string: "https://chat.googleapis.com/up/precedence")!, body: Data("body".utf8),
                bodyFile: FileBody(file: file)))
        #expect(response.status == 200)
        #expect(BodyCountingProtocol.seen.withLock { $0["/up/precedence"] }?.captured == Data("file".utf8))
    }

    @Test func missingFileFailsBeforeSending() async {
        let before = BodyCountingProtocol.seen.withLock { $0["/up/missing"] }
        await #expect(throws: TransportError.requestBodyUnavailable) {
            try await upload(path: "/up/missing", body: FileBody(file: directory.appending(path: "nope")))
        }
        #expect(BodyCountingProtocol.seen.withLock { $0["/up/missing"] }?.bytes == before?.bytes)
    }

    @Test func directoryIsNotAFileBody() async {
        await #expect(throws: TransportError.requestBodyUnavailable) {
            try await upload(path: "/up/dir", body: FileBody(file: directory))
        }
    }

    func transfer(for source: Transfer.FileSource?) -> Transfer {
        Transfer(
            mode: .buffered, maxBytes: 10, requestURL: URL(string: "https://chat.googleapis.com/")!,
            fileSource: source, sink: { _ in })
    }

    @Test func retryBuildsAFreshStreamFromTheValue() throws {
        let file = directory.appending(path: "r.bin")
        let content = Data(repeating: 9, count: 70_000)
        try content.write(to: file)
        let opened = try OpenedFile.open(file)
        let transfer = transfer(
            for: Transfer.FileSource(prefix: Data("p".utf8), suffix: Data(), file: opened, identity: opened.identity))
        for _ in 0..<2 {
            let stream = transfer.newBodyStream()
            #expect(stream != nil)
            stream?.open()
            var total = 0
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while let count = stream?.read(&buffer, maxLength: buffer.count), count > 0 { total += count }
            #expect(total == content.count + 1)
        }
    }

    @Test func retryFailsClosedWhenTheFileChanged() throws {
        let file = directory.appending(path: "c.bin")
        try Data(count: 100).write(to: file)
        let opened = try OpenedFile.open(file)
        let transfer = transfer(
            for: Transfer.FileSource(prefix: Data(), suffix: Data(), file: opened, identity: opened.identity))
        #expect(transfer.newBodyStream() != nil)
        try Data(count: 99).write(to: file)
        #expect(transfer.newBodyStream() == nil)
    }

    @Test func retryWithoutAFileBodyHasNoStream() {
        #expect(transfer(for: nil).newBodyStream() == nil)
    }
}

extension MemorySensitive {
    @Suite struct UploadFootprint {
        @Test func streaming64MegabytesKeepsTheFootprintFlat() async throws {
            let directory = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = try makeSparseFile(in: directory, megabytes: 64)
            let transport = AuthTransport(
                allowedHosts: ["chat.googleapis.com"], protocolClasses: [BodyCountingProtocol.self])
            let before = physFootprint()
            let response = try await transport.send(
                HTTPRequest(
                    method: .post, url: URL(string: "https://chat.googleapis.com/up/big")!,
                    bodyFile: FileBody(prefix: Data("--b\r\n".utf8), file: file, suffix: Data("\r\n--b--".utf8))))
            #expect(response.status == 200)
            let seen = BodyCountingProtocol.seen.withLock { $0["/up/big"] }!
            #expect(seen.bytes == (64 << 20) + 5 + 7)
            let growth = seen.peakFootprint - before
            print("upload footprint growth: \(growth / 1024) KiB over \(seen.bytes >> 20) MiB")
            #expect(growth < 16 << 20)
        }
    }
}

/// A minimal HTTP/1.1 sink on 127.0.0.1 that counts the request body.
final class LoopbackSink: @unchecked Sendable {
    struct Result: Sendable {
        var bodyBytes = 0
        var contentLength: Int?
        var chunked = false
    }

    let listener: NWListener
    let results = Mutex<[Result]>([])

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in handle(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Atomic<Bool>(false)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if !resumed.exchange(true, ordering: .acquiringAndReleasing) {
                        continuation.resume(returning: listener.port!.rawValue)
                    }
                case .failed(let error):
                    if !resumed.exchange(true, ordering: .acquiringAndReleasing) {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        let buffer = Mutex(Data())
        let state = Mutex(Result())
        let headerEnd = Data("\r\n\r\n".utf8)
        @Sendable func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let data {
                    buffer.withLock { $0.append(data) }
                }
                let snapshot = buffer.withLock { $0 }
                if let range = snapshot.range(of: headerEnd) {
                    let head = String(decoding: snapshot[..<range.lowerBound], as: UTF8.self).lowercased()
                    let length = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
                        .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
                    let chunked = head.contains("transfer-encoding: chunked")
                    let body = snapshot.count - range.upperBound
                    state.withLock {
                        $0.bodyBytes = body
                        $0.contentLength = length
                        $0.chunked = chunked
                    }
                    if let length, body >= length {
                        let result = state.withLock { $0 }
                        self.results.withLock { $0.append(result) }
                        let reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                        connection.send(
                            content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                }
                if error != nil || isComplete { connection.cancel() } else { receive() }
            }
        }
        receive()
    }
}

@Suite(.serialized) struct CFNetworkStreamTests {
    @Test func urlSessionAcceptsTheStreamOverRealTCP() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = Data((0..<300_000).map { UInt8($0 % 239) })
        let file = directory.appending(path: "t.bin")
        try content.write(to: file)

        let sink = try LoopbackSink()
        let port = try await sink.start()
        defer { sink.listener.cancel() }

        let opened = try OpenedFile.open(file)
        let stream = CompositeInputStream(
            prefix: Data("PRE".utf8), file: opened, identity: opened.identity, suffix: Data("SUF".utf8))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/upload")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue(String(stream.totalLength), forHTTPHeaderField: "Content-Length")
        request.httpBodyStream = stream
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let result = sink.results.withLock { $0.first }
        #expect(result?.bodyBytes == content.count + 6)
        #expect(result?.contentLength == content.count + 6)
        #expect(result?.chunked == false)
    }
}
