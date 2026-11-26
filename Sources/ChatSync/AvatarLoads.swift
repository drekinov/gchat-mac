import ChatNet
import Foundation

/// Profile photo downloads shared by every row that shows the same URL. Each caller can leave at any time; the
/// download stops once nobody waits for it. Brief failures are retried, and only lasting ones are remembered.
public actor AvatarLoads {
    public static let shared = AvatarLoads()
    public typealias Fetch = @Sendable () async throws(MediaLoadError) -> DecodedImage

    enum Outcome: Equatable {
        case retry
        /// Never succeeds for this URL; it isn't fetched again this run.
        case permanent
        /// Gives up now without remembering, so the next appearance tries again.
        case stop
    }

    private struct Worker {
        let generation: UInt64
        var waiters: [UInt64: CheckedContinuation<DecodedImage?, Never>] = [:]
        var task: Task<Void, Never>?
    }

    let slots: MemoryBudget
    private let retryDelays: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void
    private var workers: [URL: Worker] = [:]
    private var permanent: Set<URL> = []
    private var nextID: UInt64 = 0

    init(
        concurrent: Int = 4, retryDelays: [Duration] = [.seconds(2), .seconds(8)],
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        slots = MemoryBudget(capacity: concurrent)
        self.retryDelays = retryDelays
        self.sleep = sleep
    }

    /// The decoded photo, or nil when it failed or the caller was cancelled.
    public func load(_ url: URL, fetch: @escaping Fetch) async -> DecodedImage? {
        guard !permanent.contains(url) else { return nil }
        nextID += 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: nil) }
                join(url, id: id, continuation: continuation, fetch: fetch)
            }
        } onCancel: {
            Task { await self.leave(url, id: id) }
        }
    }

    private func join(
        _ url: URL, id: UInt64, continuation: CheckedContinuation<DecodedImage?, Never>, fetch: @escaping Fetch
    ) {
        if workers[url] != nil {
            workers[url]?.waiters[id] = continuation
            return
        }
        nextID += 1
        let generation = nextID
        workers[url] = Worker(generation: generation, waiters: [id: continuation])
        workers[url]?.task = Task { await self.run(url, generation: generation, fetch: fetch) }
    }

    private func leave(_ url: URL, id: UInt64) {
        guard let continuation = workers[url]?.waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
        if workers[url]?.waiters.isEmpty == true {
            workers[url]?.task?.cancel()
            workers[url] = nil
        }
    }

    func waiterCount(_ url: URL) -> Int { workers[url]?.waiters.count ?? 0 }

    private func isWanted(_ url: URL, _ generation: UInt64) -> Bool {
        !Task.isCancelled && workers[url]?.generation == generation
    }

    private func run(_ url: URL, generation: UInt64, fetch: Fetch) async {
        var attempt = 0
        while isWanted(url, generation) {
            guard let slot = try? await slots.reserve(1) else { break }
            // A slot is held per attempt only, never across a backoff.
            guard isWanted(url, generation) else {
                slot.release()
                break
            }
            let result: Result<DecodedImage, MediaLoadError>
            do throws(MediaLoadError) {
                result = .success(try await fetch())
            } catch {
                result = .failure(error)
            }
            slot.release()
            switch result {
            case .success(let image):
                return finish(url, generation, image)
            case .failure(let error):
                switch Self.outcome(error) {
                case .permanent:
                    permanent.insert(url)
                    return finish(url, generation, nil)
                case .stop:
                    return finish(url, generation, nil)
                case .retry:
                    guard attempt < retryDelays.count, (try? await sleep(retryDelays[attempt])) != nil else {
                        return finish(url, generation, nil)
                    }
                    attempt += 1
                }
            }
        }
        finish(url, generation, nil)
    }

    private func finish(_ url: URL, _ generation: UInt64, _ image: DecodedImage?) {
        guard let worker = workers[url], worker.generation == generation else { return }
        workers[url] = nil
        for continuation in worker.waiters.values { continuation.resume(returning: image) }
    }

    static func outcome(_ error: MediaLoadError) -> Outcome {
        switch error {
        case .transport(let transport):
            switch transport {
            case .offline, .timedOut, .connectionLost: .retry
            case .other(let code): (400..<500).contains(code) && code != 408 && code != 429 ? .permanent : .retry
            case .insecureScheme, .hostNotAllowed, .redirected, .responseTooLarge: .permanent
            case .cancelled, .tls, .requestBodyUnavailable, .sinkFailed: .stop
            }
        case .image(let image):
            switch image {
            // A 256 KB avatar always fits the budget, so `.budget` means a wait that ran out.
            case .budget: .retry
            case .tooLarge, .tooManyFrames, .unsupported, .corrupt: .permanent
            case .cancelled: .stop
            }
        case .api, .cache, .export, .notUploadedContent, .retired: .stop
        }
    }
}
