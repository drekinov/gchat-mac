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

    /// Returns nil if the task didn't finish within `seconds`.
    func finish(_ task: Task<TransportError?, Never>, within seconds: Double = 5) async -> TransportError?? {
        await withTaskGroup(of: TransportError??.self) { group in
            group.addTask { .some(await task.value) }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return .none
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    func send(stream: Bool) -> Task<TransportError?, Never> {
        Task { [transport, url] () -> TransportError? in
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
    func cancellingImmediatelyAlwaysCompletes(stream: Bool) async {
        for _ in 0..<300 {
            let task = send(stream: stream)
            task.cancel()
            let outcome = await finish(task)
            #expect(outcome != nil, "request never completed after cancel")
            if let error = outcome ?? nil { #expect(error == .cancelled) }
        }
    }

    @Test(arguments: [false, true])
    func cancellingAtRandomPointsAlwaysCompletes(stream: Bool) async {
        for round in 0..<300 {
            let task = send(stream: stream)
            for _ in 0..<(round % 7) { await Task.yield() }
            task.cancel()
            #expect(await finish(task) != nil, "request never completed after cancel")
        }
    }

    @Test func alreadyCancelledCallerNeverStartsARequest() async {
        let before = DownloadStubProtocol.seen.withLock { $0.count }
        let task = Task { () -> TransportError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(TransportError) {
                _ = try await transport.send(HTTPRequest(url: url))
                return nil
            } catch {
                return error
            }
        }
        #expect(await finish(task) == .some(.cancelled))
        #expect(DownloadStubProtocol.seen.withLock { $0.count } == before)
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
