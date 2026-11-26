import Foundation
import Synchronization

/// How long a test on real threads waits before it fails instead of hanging. Nothing on a passing path comes near it.
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

/// An operation in its own task. Its result is set once and read without awaiting the task, so an operation that
/// never finishes fails the test instead of hanging it.
final class Running<Value: Sendable>: Sendable {
    private let value = Mutex<Value?>(nil)
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ body: @escaping @Sendable () async -> Value) {
        let started = Task {
            let result = await body()
            self.value.withLock { $0 = result }
        }
        task.withLock { $0 = started }
    }

    /// The result, or nil if `hangGuard` ran out first.
    func settled() async -> Value? {
        _ = await eventually { self.value.withLock { $0 != nil } }
        return value.withLock { $0 }
    }

    func cancel() { task.withLock { $0 }?.cancel() }
}

/// Parks every caller of `pass()` until the test opens it, whatever happens to the caller's task.
final class Hold: Sendable {
    private struct State {
        var open = false
        var arrived = 0
        var parked: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Callers that have reached `pass()`.
    var arrived: Int { state.withLock { $0.arrived } }

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = state.withLock { state in
                state.arrived += 1
                if !state.open { state.parked.append(continuation) }
                return state.open
            }
            if go { continuation.resume() }
        }
    }

    /// Lets every parked and later caller through.
    func open() {
        let parked = state.withLock { state in
            state.open = true
            defer { state.parked = [] }
            return state.parked
        }
        for continuation in parked { continuation.resume() }
    }
}

/// Stands in for a sleep. Each call records its duration and parks until the test fires it, or throws when its
/// task is cancelled.
final class Pauses: Sendable {
    enum Ending: Sendable, Equatable { case fired, cancelled }

    private struct Call {
        let duration: Duration
        var ending: Ending?
        var parked: CheckedContinuation<Void, any Error>?
    }

    private struct State {
        var calls: [Call] = []
        var fireOnArrival: Set<Int> = []
    }

    private let state = Mutex(State())

    /// The durations asked for, in call order.
    var asked: [Duration] { state.withLock { $0.calls.map(\.duration) } }
    /// How each call ended, nil while it is still parked.
    var endings: [Ending?] { state.withLock { $0.calls.map(\.ending) } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { duration in try await self.park(duration) }
    }

    /// Ends call `index` as if its time had passed; one that hasn't been made yet returns as soon as it is.
    func fire(_ index: Int) {
        let parked: CheckedContinuation<Void, any Error>? = state.withLock { state in
            guard index < state.calls.count else {
                state.fireOnArrival.insert(index)
                return nil
            }
            guard state.calls[index].ending == nil else { return nil }
            state.calls[index].ending = .fired
            defer { state.calls[index].parked = nil }
            return state.calls[index].parked
        }
        parked?.resume()
    }

    private func park(_ duration: Duration) async throws {
        let index = state.withLock { state in
            state.calls.append(Call(duration: duration))
            return state.calls.count - 1
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ending: Ending? = state.withLock { state in
                    if state.calls[index].ending == nil {
                        if state.fireOnArrival.remove(index) != nil {
                            state.calls[index].ending = .fired
                        } else if Task.isCancelled {
                            state.calls[index].ending = .cancelled
                        } else {
                            state.calls[index].parked = continuation
                        }
                    }
                    return state.calls[index].ending
                }
                switch ending {
                case .fired: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case nil: break
                }
            }
        } onCancel: {
            let parked: CheckedContinuation<Void, any Error>? = state.withLock { state in
                guard state.calls[index].ending == nil else { return nil }
                state.calls[index].ending = .cancelled
                defer { state.calls[index].parked = nil }
                return state.calls[index].parked
            }
            parked?.resume(throwing: CancellationError())
        }
    }
}
