import Foundation
import Synchronization

public enum MemoryBudgetError: Error, Sendable, Equatable {
    case exceedsCapacity(requested: Int, capacity: Int)
    case invalidSize
    /// A bounded wait ran out before enough memory was free.
    case timedOut
}

/// Process-wide admission control for media memory. Waiters are served strictly in arrival order, so a large
/// request at the head is never starved by smaller ones behind it.
///
/// The state lives in a lock-protected core rather than the actor so that `Reservation.release()` and `deinit`
/// can return bytes synchronously.
public actor MemoryBudget {
    public nonisolated let capacity: Int
    private let core: BudgetCore

    public init(capacity: Int) {
        self.capacity = max(capacity, 0)
        core = BudgetCore(capacity: max(capacity, 0))
    }

    public var available: Int { core.available }

    /// Waits until `bytes` are free. Throws `CancellationError` (leaving the queue) if the task is cancelled, and
    /// `MemoryBudgetError.exceedsCapacity` immediately if `bytes` could never fit.
    public func reserve(_ bytes: Int) async throws -> Reservation {
        try await core.reserve(bytes)
    }

    /// Like `reserve`, but gives up with `MemoryBudgetError.timedOut`. Use it whenever the caller already holds
    /// a reservation, because waiting on others while holding memory can deadlock.
    public func reserve(_ bytes: Int, timeout: Duration) async throws -> Reservation {
        try await core.reserve(bytes, timeout: timeout)
    }

    /// A non-nil `expiry` ends the wait when it returns, in place of sleeping for `timeout`. Its task starts only
    /// after the request has joined the queue; `onExpiryLaunch` reports, as the task is created, whether it had.
    func reserve(
        _ bytes: Int, timeout: Duration, expiry: (@Sendable () async throws -> Void)?,
        onExpiryLaunch: (@Sendable (_ queued: Bool) -> Void)? = nil
    ) async throws -> Reservation {
        try await core.reserve(bytes, timeout: timeout, expiry: expiry, onExpiryLaunch: onExpiryLaunch)
    }

    /// Requests currently queued.
    nonisolated var waiterCount: Int { core.waiterCount }

    /// Returns nil unless the bytes are free and nobody is queued ahead.
    public func tryReserve(_ bytes: Int) -> Reservation? {
        core.tryReserve(bytes)
    }
}

public final class Reservation: Sendable {
    private let core: BudgetCore
    private let held: Mutex<Int>

    fileprivate init(core: BudgetCore, bytes: Int) {
        self.core = core
        held = Mutex(bytes)
    }

    deinit {
        release()
    }

    /// Bytes still held; 0 after `release()`.
    public var bytes: Int { held.withLock { $0 } }

    /// Idempotent.
    public func release() {
        let returned = held.withLock { held -> Int in
            defer { held = 0 }
            return held
        }
        if returned > 0 { core.give(returned) }
    }

    /// Moves `bytes` out of this reservation into a new one, without touching the budget. Nil if fewer are held.
    public func split(_ bytes: Int) -> Reservation? {
        let taken = held.withLock { held -> Bool in
            guard bytes >= 0, bytes <= held else { return false }
            held -= bytes
            return true
        }
        return taken ? Reservation(core: core, bytes: bytes) : nil
    }

    /// Gives back the difference when `newBytes` is smaller than what's held; never grows a reservation.
    public func shrink(to newBytes: Int) {
        let returned = held.withLock { held -> Int in
            let target = min(max(newBytes, 0), held)
            defer { held = target }
            return held - target
        }
        if returned > 0 { core.give(returned) }
    }
}

private final class BudgetCore: Sendable {
    typealias Grant = (continuation: CheckedContinuation<Reservation, any Error>, reservation: Reservation)

    private struct Waiter {
        let id: UInt64
        let bytes: Int
        let continuation: CheckedContinuation<Reservation, any Error>
    }

    private struct State {
        var used = 0
        var nextID: UInt64 = 0
        var waiters: [Waiter] = []
    }

    private let capacity: Int
    private let state = Mutex(State())

    init(capacity: Int) {
        self.capacity = capacity
    }

    var available: Int { state.withLock { capacity - $0.used } }

    var waiterCount: Int { state.withLock { $0.waiters.count } }

    private func validate(_ bytes: Int) throws {
        guard bytes >= 0 else { throw MemoryBudgetError.invalidSize }
        guard bytes <= capacity else { throw MemoryBudgetError.exceedsCapacity(requested: bytes, capacity: capacity) }
    }

    func tryReserve(_ bytes: Int) -> Reservation? {
        guard (try? validate(bytes)) != nil else { return nil }
        return state.withLock { state in
            guard state.waiters.isEmpty, state.used + bytes <= capacity else { return nil }
            state.used += bytes
            return Reservation(core: self, bytes: bytes)
        }
    }

    func reserve(
        _ bytes: Int, timeout: Duration? = nil, expiry: (@Sendable () async throws -> Void)? = nil,
        onExpiryLaunch: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> Reservation {
        try validate(bytes)
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        let timer = ExpiryTimer()
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Reservation, any Error>) in
                let immediate: Result<Reservation, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if state.waiters.isEmpty, state.used + bytes <= capacity {
                        state.used += bytes
                        return .success(Reservation(core: self, bytes: bytes))
                    }
                    state.waiters.append(Waiter(id: id, bytes: bytes, continuation: continuation))
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                } else if let timeout {
                    timer.arm(launchExpiry(for: id, timeout: timeout, expiry: expiry, probe: onExpiryLaunch))
                }
            }
        } onCancel: {
            remove(id, with: CancellationError())
        }
    }

    private func launchExpiry(
        for id: UInt64, timeout: Duration, expiry: (@Sendable () async throws -> Void)?,
        probe: (@Sendable (Bool) -> Void)?
    ) -> Task<Void, Never> {
        probe?(state.withLock { $0.waiters.contains { $0.id == id } })
        return Task {
            do {
                if let expiry { try await expiry() } else { try await Task.sleep(for: timeout) }
            } catch { return }
            remove(id, with: MemoryBudgetError.timedOut)
        }
    }

    func give(_ bytes: Int) {
        let grants = state.withLock { state -> [Grant] in
            state.used -= bytes
            return grantLocked(&state)
        }
        for grant in grants { grant.continuation.resume(returning: grant.reservation) }
    }

    private func remove(_ id: UInt64, with error: any Error) {
        let (removed, grants) = state.withLock { state -> (CheckedContinuation<Reservation, any Error>?, [Grant]) in
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return (nil, []) }
            let waiter = state.waiters.remove(at: index)
            return (waiter.continuation, grantLocked(&state))
        }
        removed?.resume(throwing: error)
        for grant in grants { grant.continuation.resume(returning: grant.reservation) }
    }

    private func grantLocked(_ state: inout State) -> [Grant] {
        var grants: [Grant] = []
        while let first = state.waiters.first, state.used + first.bytes <= capacity {
            state.waiters.removeFirst()
            state.used += first.bytes
            grants.append((first.continuation, Reservation(core: self, bytes: first.bytes)))
        }
        return grants
    }
}

/// Holds the expiry task. It is armed only after the waiter is queued, so it can never fire for a waiter that
/// doesn't exist yet; arming after `cancel()` cancels the task immediately.
private final class ExpiryTimer: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var cancelled = false
    }

    private let state = Mutex(State())

    func arm(_ task: Task<Void, Never>) {
        let cancelNow = state.withLock { state -> Bool in
            if state.cancelled { return true }
            state.task = task
            return false
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}
