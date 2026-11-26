import Foundation
import Synchronization
import Testing

@testable import ChatNet

@Suite(.serialized) struct TransferCancellationTests {
    let transport = AuthTransport(allowedHosts: ["chat.googleapis.com"], protocolClasses: [DownloadStubProtocol.self])
    let url = URL(string: "https://chat.googleapis.com/cx/ok")!

    init() {
        DownloadStubProtocol.routes.withLock { $0["/cx/ok"] = .init(status: 200, body: Data("ok".utf8)) }
    }

    func send(stream: Bool) -> Recorded<TransportError?> {
        Recorded { [transport, url] () -> TransportError? in
            do throws(TransportError) {
                if stream {
                    _ = try await transport.stream(HTTPRequest(url: url)) { _ in }
                } else {
                    _ = try await transport.send(HTTPRequest(url: url))
                }
                return nil
            } catch {
                return error
            }
        }
    }

    @Test(arguments: [false, true])
    func cancellingImmediatelyAlwaysCompletes(stream: Bool) async throws {
        for _ in 0..<300 {
            let request = send(stream: stream)
            request.cancel()
            let outcome = try #require(await request.settled(), "request never completed after cancel")
            if let error = outcome { #expect(error == .cancelled) }
        }
    }

    @Test(arguments: [false, true])
    func cancellingAtRandomPointsAlwaysCompletes(stream: Bool) async throws {
        for round in 0..<300 {
            let request = send(stream: stream)
            for _ in 0..<(round % 7) { await Task.yield() }
            request.cancel()
            _ = try #require(await request.settled(), "request never completed after cancel")
        }
    }

    @Test func alreadyCancelledCallerNeverStartsARequest() async {
        DownloadStubProtocol.routes.withLock { $0["/cx/never"] = .init(status: 200, body: Data("ok".utf8)) }
        let never = URL(string: "https://chat.googleapis.com/cx/never")!
        let request = Recorded { [transport] () -> TransportError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(TransportError) {
                _ = try await transport.send(HTTPRequest(url: never))
                return nil
            } catch {
                return error
            }
        }
        #expect(await request.settled() == .some(.cancelled))
        #expect(!DownloadStubProtocol.seen.withLock { $0.contains { $0.url?.path == "/cx/never" } })
    }

    // MARK: Deterministic outcome delivery

    func makeTransfer(sink: @escaping Transfer.Sink = { _ in }) -> Transfer {
        Transfer(
            mode: .streaming, maxBytes: 1000, requestURL: URL(string: "https://chat.googleapis.com/")!,
            fileSource: nil, sink: sink)
    }

    func idleTask() -> URLSessionTask {
        URLSession(configuration: .ephemeral).dataTask(with: URL(string: "https://chat.googleapis.com/idle")!)
    }

    @Test func completionBeforeInstallIsDeliveredImmediatelyAndOnce() async {
        let transfer = makeTransfer()
        transfer.complete(URLError(.cancelled))
        transfer.complete(nil)
        let started = Counter()
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Transfer.Outcome, Never>) in
            if transfer.install(continuation) { started.bump() }
        }
        #expect(outcome == .failure(.cancelled))
        #expect(started.count == 0)
    }

    @Test func cancellingBeforeInstallBecomesTheOutcomeAndTheTaskIsNotStarted() async {
        let transfer = makeTransfer()
        let task = idleTask()
        transfer.cancel(task)
        transfer.complete(nil)
        let started = Counter()
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Transfer.Outcome, Never>) in
            if transfer.install(continuation) { started.bump() }
        }
        #expect(outcome == .failure(.cancelled))
        #expect(started.count == 0)
    }

    @Test func cancellingAfterInstallLeavesTheOutcomeToTheSession() async {
        let transfer = makeTransfer()
        let task = idleTask()
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Transfer.Outcome, Never>) in
            #expect(transfer.install(continuation))
            transfer.cancel(task)
            transfer.complete(URLError(.cancelled))
            transfer.complete(URLError(.timedOut))
        }
        #expect(outcome == .failure(.cancelled))
    }

    @Test func theSinkIsReleasedBeforeTheCompletionIsDelivered() async {
        final class Token: Sendable {}
        weak var weakToken: Token?
        let transfer: Transfer = {
            let token = Token()
            weakToken = token
            return makeTransfer(sink: { _ in _ = token })
        }()
        let aliveWhenResumed = Counter()
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Transfer.Outcome, Never>) in
            #expect(transfer.install(continuation))
            transfer.complete(nil)
        }
        if weakToken != nil { aliveWhenResumed.bump() }
        #expect(aliveWhenResumed.count == 0)
    }

    @Test func chunksAfterTheOutcomeAreNotDeliveredToTheSink() {
        let delivered = Counter()
        let transfer = makeTransfer(sink: { _ in delivered.bump() })
        transfer.complete(URLError(.cancelled))
        let response = HTTPURLResponse(
            url: URL(string: "https://chat.googleapis.com/")!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        #expect(transfer.received(response) == .cancel)
        #expect(!transfer.received(Data("late".utf8)))
        #expect(delivered.count == 0)
    }
}
