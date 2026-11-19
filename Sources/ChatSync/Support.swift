import ChatModel
import Foundation
import Synchronization

public protocol SyncClock: Sendable {
    func now() -> Timestamp
    func sleep(for duration: Duration) async throws
}

public struct SystemClock: SyncClock {
    public init() {}
    public func now() -> Timestamp { Timestamp(Date()) }
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// A single-slot channel: a slow consumer only ever sees the newest value.
public final class LatestValue<Value: Sendable>: Sendable {
    public let values: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation
    private let latest: Mutex<Value?>

    public init() {
        (values, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(1))
        latest = Mutex(nil)
    }

    public var current: Value? { latest.withLock { $0 } }

    public func send(_ value: Value) {
        latest.withLock { $0 = value }
        continuation.yield(value)
    }

    public func finish() { continuation.finish() }
}

/// Tasks owned by a session generation. Cancelled together on logout and awaited with a bound.
public final class WorkRegistry: Sendable {
    private struct State {
        var tasks: [UUID: Task<Void, Never>] = [:]
        var closed = false
    }

    private let state = Mutex(State())

    public init() {}

    /// Starts `body` as a registered task; returns `false` (and runs nothing) once the registry is closed.
    @discardableResult
    public func spawn(_ body: @escaping @Sendable () async -> Void) -> Bool {
        task(body) != nil
    }

    /// Like `spawn`, returning the task so its owner can cancel it alone.
    public func task(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        let id = UUID()
        return state.withLock { state in
            guard !state.closed else { return nil }
            let task = Task { [weak self] in
                await body()
                self?.remove(id)
            }
            state.tasks[id] = task
            return task
        }
    }

    private func remove(_ id: UUID) {
        _ = state.withLock { $0.tasks.removeValue(forKey: id) }
    }

    public var count: Int { state.withLock { $0.tasks.count } }

    /// Closes the registry, cancels everything, and waits up to `timeout` for tasks to finish.
    /// Returns `true` if all finished; stragglers can't commit anyway because their generation is retired.
    public func cancelAndDrain(timeout: Duration, clock: any SyncClock = SystemClock()) async -> Bool {
        let tasks = state.withLock { state in
            state.closed = true
            return Array(state.tasks.values)
        }
        for task in tasks { task.cancel() }
        // Unstructured on purpose: a structured group would wait for tasks that ignore cancellation.
        return await withCheckedContinuation { continuation in
            let once = Once()
            Task {
                for task in tasks { await task.value }
                if once.claim() { continuation.resume(returning: true) }
            }
            Task {
                try? await clock.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }

    /// Reopens after re-login.
    public func reopen() {
        state.withLock { $0.closed = false }
    }
}

/// Ensures at most one sync of a given key (space and stream) runs at a time.
final class InFlight<Key: Hashable & Sendable>: Sendable {
    private let keys = Mutex(Set<Key>())

    func tryBegin(_ key: Key) -> Bool { keys.withLock { $0.insert(key).inserted } }
    func end(_ key: Key) { _ = keys.withLock { $0.remove(key) } }
}

final class Once: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}
