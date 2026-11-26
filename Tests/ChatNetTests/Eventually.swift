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
