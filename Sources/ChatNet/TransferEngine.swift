import Foundation
import Synchronization

/// A URLSession plus per-task state; every transfer built on it blocks redirects and reports them as `.redirected`.
final class TransferSession: Sendable {
    private let session: URLSession
    private let delegate = TransferDelegate()

    static let maxChunkBytes = 1 << 20

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    static func map(_ error: URLError) -> TransportError { TransportError(error) }

    func run(
        _ urlRequest: URLRequest, mode: Transfer.Mode, maxBytes: Int, fileSource: Transfer.FileSource? = nil,
        sink: @escaping @Sendable (Data) throws -> Void
    ) async throws(TransportError) -> HTTPResponseHead {
        guard !Task.isCancelled else { throw .cancelled }
        var urlRequest = urlRequest
        let transfer = Transfer(
            mode: mode, maxBytes: maxBytes, requestURL: urlRequest.url!, fileSource: fileSource, sink: sink)
        if let fileSource {
            guard let stream = transfer.newBodyStream() else { throw .requestBodyUnavailable }
            urlRequest.setValue(String(fileSource.contentLength), forHTTPHeaderField: "Content-Length")
            urlRequest.httpBodyStream = stream
        }
        let task = session.dataTask(with: urlRequest)
        delegate.register(task, transfer)
        defer { delegate.unregister(task) }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Transfer.Outcome, Never>) in
                if transfer.install(continuation) {
                    task.resume()
                    if Task.isCancelled { task.cancel() }
                }
            }
        } onCancel: {
            transfer.cancel(task)
        }
        return try result.get()
    }
}

/// One in-flight request. Delegate callbacks arrive serially per task. The terminal outcome is stored under the
/// lock, so it is delivered exactly once whether it arrives before or after the caller installs its continuation.
final class Transfer: Sendable {
    typealias Outcome = Result<HTTPResponseHead, TransportError>
    typealias Sink = @Sendable (Data) throws -> Void

    enum Mode { case buffered, streaming }

    /// Retries rebuild the stream from this value and refuse a file that no longer matches `identity`.
    struct FileSource: Sendable {
        let prefix: Data
        let suffix: Data
        let file: OpenedFile
        let identity: FileIdentity

        var contentLength: Int { prefix.count + Int(identity.size) + suffix.count }
    }

    private struct State {
        var continuation: CheckedContinuation<Outcome, Never>?
        var outcome: Outcome?
        var sink: Sink?
        var status: Int?
        var headers: [String: String] = [:]
        var delivered = 0
        var received = 0
        var errorBody = Data()
        var failure: TransportError?
    }

    private let mode: Mode
    private let maxBytes: Int
    private let requestURL: URL
    private let fileSource: FileSource?
    private let state: Mutex<State>

    init(mode: Mode, maxBytes: Int, requestURL: URL, fileSource: FileSource?, sink: @escaping Sink) {
        self.mode = mode
        self.maxBytes = maxBytes
        self.requestURL = requestURL
        self.fileSource = fileSource
        state = Mutex(State(sink: sink))
    }

    /// Returns true when the caller should start the task; false when the outcome already exists, in which case
    /// the continuation has been resumed.
    func install(_ continuation: CheckedContinuation<Outcome, Never>) -> Bool {
        let ready: Outcome? = state.withLock { state in
            if let outcome = state.outcome { return outcome }
            state.continuation = continuation
            return nil
        }
        guard let ready else { return true }
        continuation.resume(returning: ready)
        return false
    }

    /// Before the continuation exists the cancellation becomes the outcome; afterwards URLSession reports it.
    func cancel(_ task: URLSessionTask) {
        state.withLock { state in
            if state.continuation == nil, state.outcome == nil {
                state.outcome = .failure(.cancelled)
                state.sink = nil
            }
        }
        task.cancel()
    }

    private func countsTowardLimit(_ status: Int) -> Bool {
        mode == .buffered || (200..<300).contains(status)
    }

    func received(_ response: HTTPURLResponse) -> URLSession.ResponseDisposition {
        state.withLock { state in
            guard state.outcome == nil else { return .cancel }
            var headers: [String: String] = [:]
            for case (let field as String, let value as String) in response.allHeaderFields {
                headers[field.lowercased()] = value
            }
            state.status = response.statusCode
            state.headers = headers
            if (300..<400).contains(response.statusCode) {
                let location = (response.value(forHTTPHeaderField: "Location")).flatMap {
                    URL(string: $0, relativeTo: requestURL)
                }
                state.failure = .redirected(status: response.statusCode, location: location?.absoluteURL)
                return .cancel
            }
            if countsTowardLimit(response.statusCode), response.expectedContentLength > Int64(maxBytes) {
                state.failure = .responseTooLarge
                return .cancel
            }
            return .allow
        }
    }

    /// Returns false when the transfer must be cancelled.
    func received(_ data: Data) -> Bool {
        let (counted, sink): (Bool?, Sink?) = state.withLock { state in
            guard state.outcome == nil, state.failure == nil, let status = state.status, let sink = state.sink
            else { return (nil, nil) }
            guard countsTowardLimit(status) else {
                let room = HTTPResponseHead.maxErrorBodyBytes - state.errorBody.count
                if room > 0 { state.errorBody.append(data.prefix(room)) }
                return (false, nil)
            }
            guard state.received + data.count <= maxBytes else {
                state.failure = .responseTooLarge
                return (nil, nil)
            }
            state.received += data.count
            return (true, sink)
        }
        guard let counted else { return false }
        guard counted, let sink else { return true }
        var start = 0
        while start < data.count {
            let end = min(start + TransferSession.maxChunkBytes, data.count)
            let chunk = start == 0 && end == data.count ? data : data.subdata(in: start..<end)
            do {
                try sink(chunk)
            } catch {
                state.withLock { $0.failure = $0.failure ?? .sinkFailed }
                return false
            }
            state.withLock { $0.delivered += chunk.count }
            start = end
        }
        return true
    }

    func newBodyStream() -> InputStream? {
        guard let fileSource else { return nil }
        guard fileSource.file.currentIdentity() == fileSource.identity else {
            state.withLock { $0.failure = $0.failure ?? .requestBodyUnavailable }
            return nil
        }
        return CompositeInputStream(
            prefix: fileSource.prefix, file: fileSource.file, identity: fileSource.identity,
            suffix: fileSource.suffix
        ) { [weak self] in
            self?.state.withLock { $0.failure = $0.failure ?? .requestBodyUnavailable }
        }
    }

    func complete(_ error: (any Error)?) {
        let resolved: (CheckedContinuation<Outcome, Never>?, Outcome)? = state.withLock { state in
            guard state.outcome == nil else { return nil }
            let outcome: Outcome
            if let failure = state.failure {
                outcome = .failure(failure)
            } else if let urlError = error as? URLError {
                outcome = .failure(TransferSession.map(urlError))
            } else if let error {
                outcome = .failure(.other(code: (error as NSError).code))
            } else if let fileSource, fileSource.file.currentIdentity() != fileSource.identity {
                outcome = .failure(.requestBodyUnavailable)
            } else if let status = state.status {
                outcome = .success(
                    HTTPResponseHead(
                        status: status, headers: state.headers, byteCount: state.delivered,
                        errorBody: state.errorBody))
            } else {
                outcome = .failure(.other(code: 0))
            }
            state.outcome = outcome
            state.sink = nil
            let continuation = state.continuation
            state.continuation = nil
            return (continuation, outcome)
        }
        if let (continuation, outcome) = resolved { continuation?.resume(returning: outcome) }
    }
}

/// Routes the session's callbacks to per-task state and blocks every redirect.
final class TransferDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private let transfers = Mutex<[Int: Transfer]>([:])

    func register(_ task: URLSessionTask, _ transfer: Transfer) {
        transfers.withLock { $0[task.taskIdentifier] = transfer }
    }

    func unregister(_ task: URLSessionTask) {
        transfers.withLock { $0[task.taskIdentifier] = nil }
    }

    private func transfer(for task: URLSessionTask) -> Transfer? {
        transfers.withLock { $0[task.taskIdentifier] }
    }

    // The async overloads of these delegate methods crash the Swift 6.4 compiler (SILGen thunk).
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        completionHandler(transfer(for: task)?.newBodyStream())
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let transfer = transfer(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(transfer.received(http))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask), transfer.received(data) else {
            dataTask.cancel()
            return
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        transfer(for: task)?.complete(error)
    }
}
