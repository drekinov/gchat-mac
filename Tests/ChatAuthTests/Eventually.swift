import Foundation
import Synchronization

/// How long a test waits before it fails instead of hanging. Nothing on a passing path comes near it.
let hangGuard: Duration = .seconds(60)

/// Waits until `condition` holds; false once `hangGuard` runs out. Only for conditions that stay true once reached,
/// so what the caller asserts next is the state it waited for.
func eventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: hangGuard)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { return false }
        do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
    }
    return true
}

/// The outcome of an operation run in its own task. It is set once and read without awaiting the task, so an
/// operation that never finishes fails the test instead of hanging it.
final class Recorded<Value: Sendable>: Sendable {
    private let value = Mutex<Value?>(nil)
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ body: @escaping @Sendable () async -> Value) {
        let started = Task {
            let result = await body()
            self.value.withLock { $0 = result }
        }
        task.withLock { $0 = started }
    }

    /// Records what a throwing operation returned or threw.
    convenience init<Success: Sendable>(
        catching body: @escaping @Sendable () async throws -> Success
    ) where Value == Result<Success, any Error> {
        self.init {
            do { return .success(try await body()) } catch { return .failure(error) }
        }
    }

    var current: Value? { value.withLock { $0 } }

    /// The outcome, or nil if `hangGuard` ran out first.
    func settled() async -> Value? {
        _ = await eventually { self.current != nil }
        return current
    }

    func cancel() { task.withLock { $0 }?.cancel() }
}

/// Opens once and stays open. Waiters park with no timer of their own; a test body asks `opened()` instead.
final class Gate: Sendable {
    private struct State {
        var open = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())

    var isOpen: Bool { state.withLock { $0.open } }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    /// True once the gate is open; false if `hangGuard` ran out first.
    func opened() async -> Bool { await eventually { self.isOpen } }

    /// Returns once the gate is open; throws if the waiting task is cancelled first.
    func wait() async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result: Result<Void, any Error>? = state.withLock { state in
                    if state.open { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    /// Returns once the gate is open, whatever happens to the waiting task.
    func waitThroughCancellation() async {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let ready = state.withLock { state in
                if !state.open { state.waiters[id] = continuation }
                return state.open
            }
            if ready { continuation.resume() }
        }
    }
}

/// Stands in for a timeout's sleep: records the duration asked for and ends only when the test fires it, or by
/// throwing when its task is cancelled.
final class ManualTimeout: Sendable {
    private let fired = Gate()
    private let durations = Mutex<[Duration]>([])

    /// The durations the code under test asked to wait, in order.
    var asked: [Duration] { durations.withLock { $0 } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { duration in
            self.durations.withLock { $0.append(duration) }
            try await self.fired.wait()
        }
    }

    func fire() { fired.open() }
}
