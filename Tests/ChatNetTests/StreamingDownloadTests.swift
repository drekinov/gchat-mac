import Foundation
import Synchronization
import Testing

@testable import ChatNet

@Suite(.serialized) struct StreamingDownloadTests {
    let transport = AuthTransport(allowedHosts: ["chat.googleapis.com"], protocolClasses: [DownloadStubProtocol.self])

    func route(_ path: String, _ canned: StubProtocol.Canned) {
        DownloadStubProtocol.routes.withLock { $0[path] = canned }
    }

    func request(_ path: String, max: Int = 16 << 20) -> HTTPRequest {
        HTTPRequest(url: URL(string: "https://chat.googleapis.com\(path)")!, maxResponseBytes: max)
    }

    final class Collector: Sendable {
        let chunks = Mutex<[Int]>([])
        let bytes = Mutex(Data())
        func add(_ chunk: Data) {
            chunks.withLock { $0.append(chunk.count) }
            bytes.withLock { $0.append(chunk) }
        }
    }

    @Test func deliversBodyInChunksOfAtMostOneMebibyte() async throws {
        let body = Data((0..<(3 << 20) + 17).map { UInt8($0 % 253) })
        route("/dl/big", .init(status: 200, headers: ["Content-Type": "image/png"], body: body))
        let collector = Collector()
        let head = try await transport.stream(request("/dl/big")) { collector.add($0) }
        #expect(head.status == 200)
        #expect(head.headers["content-type"] == "image/png")
        #expect(head.byteCount == body.count)
        #expect(head.errorBody.isEmpty)
        #expect(collector.bytes.withLock { $0 } == body)
        #expect(collector.chunks.withLock { $0 }.allSatisfy { $0 <= 1 << 20 })
        #expect(collector.chunks.withLock { $0 }.count >= 4)
    }

    @Test func enforcesTheByteCapWhileStreaming() async {
        route("/dl/capped", .init(status: 200, body: Data(count: 100)))
        let collector = Collector()
        await #expect(throws: TransportError.responseTooLarge) {
            try await transport.stream(request("/dl/capped", max: 10)) { collector.add($0) }
        }
        #expect(collector.bytes.withLock { $0.count } == 0)
    }

    @Test func redirectThrowsWithLocationAndIsNotFollowed() async {
        route("/dl/moved", .init(status: 302, headers: ["Location": "https://lh3.googleusercontent.com/x"]))
        let collector = Collector()
        await #expect(
            throws: TransportError.redirected(status: 302, location: URL(string: "https://lh3.googleusercontent.com/x"))
        ) {
            try await transport.stream(request("/dl/moved")) { collector.add($0) }
        }
        #expect(!DownloadStubProtocol.seen.withLock { $0.contains { $0.url?.host == "lh3.googleusercontent.com" } })
        #expect(collector.bytes.withLock { $0.isEmpty })
    }

    @Test func nonSuccessBodyIsCappedAndNotDelivered() async throws {
        route("/dl/err", .init(status: 403, body: Data(repeating: 0x41, count: 200_000)))
        let collector = Collector()
        let head = try await transport.stream(request("/dl/err", max: 1000)) { collector.add($0) }
        #expect(head.status == 403)
        #expect(head.byteCount == 0)
        #expect(head.errorBody.count == HTTPResponseHead.maxErrorBodyBytes)
        #expect(collector.chunks.withLock { $0.isEmpty })
    }

    @Test func throwingSinkCancelsAndReportsSinkFailed() async {
        route("/dl/sink", .init(status: 200, body: Data(count: 3 << 20)))
        struct Boom: Error {}
        let calls = Mutex(0)
        await #expect(throws: TransportError.sinkFailed) {
            try await transport.stream(request("/dl/sink")) { _ in
                calls.withLock { $0 += 1 }
                throw Boom()
            }
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func rejectsHostsAndSchemesBeforeStreaming() async {
        await #expect(throws: TransportError.hostNotAllowed) {
            try await transport.stream(HTTPRequest(url: URL(string: "https://evil.example/x")!)) { _ in }
        }
        await #expect(throws: TransportError.insecureScheme) {
            try await transport.stream(HTTPRequest(url: URL(string: "http://chat.googleapis.com/x")!)) { _ in }
        }
    }

    @Test func cancellingTheCallerCancelsTheTransfer() async {
        route("/dl/cancel", .init(status: 200, body: Data(count: 10)))
        let task = Task { () -> TransportError? in
            do throws(TransportError) {
                _ = try await transport.stream(request("/dl/cancel")) { _ in }
                return nil
            } catch {
                return error
            }
        }
        task.cancel()
        let outcome = await task.value
        #expect(outcome == nil || outcome == .cancelled)
    }
}
