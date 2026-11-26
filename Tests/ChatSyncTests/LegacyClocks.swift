import ChatModel
import FakeChatServer
import Foundation
import Synchronization

@testable import ChatSync

// Clocks tied to real time, kept only for rigs that have not moved to the simulated world yet.

/// `now()` is server time. A sleep parks until `tick()` finds the server past its deadline, or until `stop()`.
final class ServerTimeClock: SyncClock {
    private struct Waiter {
        let id: UUID
        let deadline: Timestamp
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var waiters: [Waiter] = []
        var stopped = false
    }

    let server: FakeChatServer
    private let state = Mutex(State())

    init(server: FakeChatServer) { self.server = server }

    func now() -> Timestamp { server.now }

    func sleep(for duration: Duration) async throws {
        let deadline = server.now.adding(duration)
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = server.now
                let resumeNow = state.withLock { state -> Bool in
                    if state.stopped || now >= deadline || Task.isCancelled { return true }
                    state.waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            resume { $0.id == id }
        }
        try Task.checkCancellation()
    }

    /// Wakes every sleeper whose deadline the server has reached and returns how many woke. It doesn't wait for
    /// the woken work: each test waits for its own signal.
    @discardableResult
    func tick() -> Int {
        let now = server.now
        return resume { $0.deadline <= now }
    }

    var sleepers: Int { state.withLock { $0.waiters.count } }

    /// True once a sleeper with exactly this deadline is parked; `timeout` is only a hang guard.
    func waitForSleeper(until deadline: Timestamp, timeout: Duration = .seconds(10)) async -> Bool {
        await poll(timeout: timeout) { self.state.withLock { $0.waiters.contains { $0.deadline == deadline } } }
    }

    var deadlines: [Timestamp] { state.withLock { $0.waiters.map(\.deadline) } }

    func hasSleeper(until deadline: Timestamp) -> Bool {
        state.withLock { $0.waiters.contains { $0.deadline == deadline } }
    }

    func stop() {
        state.withLock { $0.stopped = true }
        resume { _ in true }
    }

    @discardableResult
    private func resume(where match: (Waiter) -> Bool) -> Int {
        let due = state.withLock { state -> [Waiter] in
            let due = state.waiters.filter(match)
            state.waiters.removeAll(where: match)
            return due
        }
        for waiter in due { waiter.continuation.resume() }
        return due.count
    }
}

/// Server time plus virtual time that runs ahead by every sleep, so polling loops tick fast. While held, only
/// `advance` moves it, and sleeps still return.
final class SteppingClock: SyncClock {
    private struct State {
        var drift = Duration.zero
        var held = false
        var sleepsBegun = 0
    }

    let server: FakeChatServer
    private let state = Mutex(State())

    init(server: FakeChatServer) { self.server = server }

    func now() -> Timestamp { server.now.adding(state.withLock { $0.drift }) }

    func sleep(for duration: Duration) async throws {
        state.withLock { $0.sleepsBegun += 1 }
        try await Task.sleep(for: .milliseconds(1))
        state.withLock { if !$0.held { $0.drift += duration } }
    }

    var sleepsBegun: Int { state.withLock { $0.sleepsBegun } }
    func hold() { state.withLock { $0.held = true } }
    func release() { state.withLock { $0.held = false } }
    func advance(_ duration: Duration) { state.withLock { $0.drift += duration } }
}

/// Server time, with sleeps that really wait.
struct RealSleepClock: SyncClock {
    let server: FakeChatServer
    func now() -> Timestamp { server.now }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
