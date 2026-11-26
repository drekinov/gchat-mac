import ChatModel
import Foundation
import Synchronization
import Testing

@testable import ChatStore

/// Sets the modification time of `url` itself (a symlink's own, never its target's) `seconds` in the past.
func backdate(_ url: URL, by seconds: TimeInterval) throws {
    let then = Int(Date().addingTimeInterval(-seconds).timeIntervalSince1970)
    var times = [timespec(tv_sec: then, tv_nsec: 0), timespec(tv_sec: then, tv_nsec: 0)]
    guard utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// A copy last touched two days ago: its file first, then its folder, since writing the file bumps the folder.
func makeOld(_ url: URL) throws {
    try backdate(url, by: 2 * 86_400)
    try backdate(url.deletingLastPathComponent(), by: 2 * 86_400)
}

func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

func cutoff() -> Date { Date().addingTimeInterval(-ExportDirectory.maxAge) }

/// A value several threads write, read once they're done.
final class Locked<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ value: Value) { self.value = Mutex(value) }
    func update(_ body: (inout Value) -> Void) { value.withLock { body(&$0) } }
    var current: Value { value.withLock { $0 } }
}

struct EventsClosed: Error {}

/// What seams on other threads report, in order. A wait ends when its condition holds, when the log is closed, or,
/// for the test's own task, when the test is cancelled: no wait is bounded by time, the suite's time limit is.
final class Events<Event: Sendable>: Sendable {
    private struct Waiter {
        let id: Int
        let done: @Sendable ([Event]) -> Bool
        let resume: @Sendable (Bool) -> Void
    }

    private struct State {
        var log: [Event] = []
        var closed = false
        var waiters: [Waiter] = []
        var nextID = 0
    }

    private let state = Mutex(State())

    func record(_ event: Event) {
        let ready = state.withLock { state -> [Waiter] in
            state.log.append(event)
            let ready = state.waiters.filter { $0.done(state.log) }
            state.waiters.removeAll { $0.done(state.log) }
            return ready
        }
        for waiter in ready { waiter.resume(true) }
    }

    var all: [Event] { state.withLock { $0.log } }

    /// Lets every waiter go, now and from now on. A test closes its logs as it ends, so no thread it started stays
    /// blocked on one.
    func close() {
        let waiters = state.withLock { state -> [Waiter] in
            state.closed = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(false) }
    }

    /// Nil when the wait is over already; otherwise the waiter's ID.
    private func enlist(
        _ done: @escaping @Sendable ([Event]) -> Bool, cancelled: Bool = false,
        resume: @escaping @Sendable (Bool) -> Void
    ) -> Int? {
        let outcome = state.withLock { state -> (id: Int?, held: Bool) in
            if done(state.log) { return (nil, true) }
            if state.closed || cancelled { return (nil, false) }
            state.nextID += 1
            state.waiters.append(Waiter(id: state.nextID, done: done, resume: resume))
            return (state.nextID, false)
        }
        if outcome.id == nil { resume(outcome.held) }
        return outcome.id
    }

    private func dismiss(_ id: Int) {
        let waiter = state.withLock { state -> Waiter? in
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return state.waiters.remove(at: index)
        }
        waiter?.resume(false)
    }

    /// For the test's own task: returns once `done` holds, and throws if the log is closed or the test cancelled
    /// first.
    func wait(where done: @escaping @Sendable ([Event]) -> Bool) async throws {
        let id = Locked<Int?>(nil)
        let held = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // Under the handler's lock, so a cancellation either sees the waiter or is seen here.
                id.update { $0 = enlist(done, cancelled: Task.isCancelled) { continuation.resume(returning: $0) } }
            }
        } onCancel: {
            id.update { if let waiting = $0 { dismiss(waiting) } }
        }
        guard held else { throw Task.isCancelled ? CancellationError() : EventsClosed() }
    }

    /// For a seam on a thread of its own: blocks until `done` holds; false if the log was closed first.
    func block(until done: @escaping @Sendable ([Event]) -> Bool) -> Bool {
        let held = Locked(false)
        let woken = DispatchSemaphore(value: 0)
        _ = enlist(done) { outcome in
            held.update { $0 = outcome }
            woken.signal()
        }
        woken.wait()
        return held.current
    }
}

extension Events where Event: Equatable {
    func wait(for event: Event) async throws { try await wait { $0.contains(event) } }
    func count(of event: Event) -> Int { all.count(where: { $0 == event }) }
}

/// Blocking work on a thread of its own. Awaited through `value`, a call that never returns ends the test at its
/// time limit instead of hanging the run.
final class Background<Value: Sendable>: Sendable {
    private let result = Events<Value>()

    init(_ work: @escaping @Sendable () -> Value) {
        Thread.detachNewThread { [result] in result.record(work()) }
    }

    var isFinished: Bool { !result.all.isEmpty }

    var value: Value {
        get async throws {
            try await result.wait { !$0.isEmpty }
            return result.all[0]
        }
    }
}

/// Where a thread goes when the test it works for has ended without the signal it waits for.
func parkForGood() -> Never {
    while true { DispatchSemaphore(value: 0).wait() }
}

/// The lock's time in a test's hands: it passes only when a step waits, by exactly what the step asked for, and
/// nothing blocks.
final class LockTime: Sendable {
    private struct State {
        var now = Duration.zero
        var waits: [Duration] = []
    }

    private let state = Mutex(State())
    /// More waits than any step makes before its deadline; past it a step is looping, and is parked for good.
    private static let runaway = 100_000

    var now: Duration { state.withLock { $0.now } }
    /// Every wait asked for, in order.
    var waits: [Duration] { state.withLock { $0.waits } }

    func pass(_ duration: Duration) {
        let count = state.withLock { state -> Int in
            state.now += duration
            state.waits.append(duration)
            return state.waits.count
        }
        if count > Self.runaway { parkForGood() }
    }

    func install(in seams: inout ExportDirectory.Seams) {
        seams.now = { self.now }
        seams.wait = { _, limit in self.pass(limit) }
    }
}

extension ExportDirectory.Seams {
    /// For a step that has to wait its turn behind others in the test: its wait never runs out.
    static var patient: ExportDirectory.Seams {
        var seams = ExportDirectory.Seams()
        seams.lockWait = .seconds(1_000_000)
        return seams
    }
}

/// Runs blocking export work on a thread of its own and keeps how it ended.
func onThread<Value: Sendable>(
    _ work: @escaping @Sendable () throws -> Value
) -> Background<Result<Value, any Error>> {
    Background { Result { try work() } }
}

/// Holds a root's shared lock the way another process does: flock locks belong to the open file, so a second
/// descriptor conflicts within one process just as it does between two.
final class OtherProcess: Sendable {
    private let descriptor: Mutex<Int32?>

    init(holdingTheLockOf root: URL) throws {
        let fd = open(root.appendingPathComponent(ExportDirectory.lockName).path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = Mutex(fd)
    }

    /// Lets go of the lock; only the first call does anything.
    func release() {
        let fd = descriptor.withLock { held -> Int32? in
            defer { held = nil }
            return held
        }
        if let fd { close(fd) }
    }

    deinit { release() }
}

/// Whether the file is flock-ed through some other descriptor, in this process or another.
func isLockedElsewhere(_ url: URL) -> Bool {
    let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
}
