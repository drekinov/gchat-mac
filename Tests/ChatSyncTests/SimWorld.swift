import ChatModel
import ChatNet
import FakeChatServer
import Foundation
import Synchronization
import Testing

@testable import ChatSync

/// Runs every job of one simulated world on a single dedicated thread, in arrival order.
final class SimExecutor: TaskExecutor, @unchecked Sendable {
    private enum Item {
        case job(UnownedJob)
        case control(@Sendable () -> Void)
    }

    private let condition = NSCondition()
    private var queue: [Item] = []
    private var head = 0
    private var stopped = false
    private var exited = false
    private var thread: Thread?
    /// Called on the simulation thread when the queue is empty; true means it produced more work.
    private var whenIdle: @Sendable () -> Bool = { false }

    func start(whenIdle: @escaping @Sendable () -> Bool) {
        self.whenIdle = whenIdle
        let thread = Thread { [self] in loop() }
        thread.name = "SimWorld"
        self.thread = thread
        thread.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        append(.job(UnownedJob(job)))
    }

    /// Runs `action` on the simulation thread, in order with the jobs.
    func post(_ action: @escaping @Sendable () -> Void) {
        append(.control(action))
    }

    private func append(_ item: Item) {
        condition.lock()
        queue.append(item)
        condition.signal()
        condition.unlock()
    }

    func asUnownedTaskExecutor() -> UnownedTaskExecutor { UnownedTaskExecutor(ordinary: self) }

    var onThread: Bool { Thread.current === thread }

    /// Ends the thread and returns once it has let go of the world.
    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        while !exited { condition.wait() }
        condition.unlock()
    }

    private func loop() {
        condition.lock()
        while !stopped {
            if head < queue.count {
                let item = queue[head]
                head += 1
                if head == queue.count {
                    queue.removeAll(keepingCapacity: true)
                    head = 0
                }
                condition.unlock()
                switch item {
                case .job(let job): job.runSynchronously(on: asUnownedTaskExecutor())
                case .control(let action): action()
                }
                condition.lock()
            } else {
                condition.unlock()
                let produced = whenIdle()
                condition.lock()
                if !produced, head == queue.count, !stopped { condition.wait() }
            }
        }
        whenIdle = { false }
        exited = true
        condition.broadcast()
        condition.unlock()
    }
}

enum SimError: Error, CustomStringConvertible {
    /// The operation can't finish: nothing is queued and no sleeper is left to wake.
    case stalled(String)
    /// The test body is suspended on something nothing in the world can resume.
    case deadlock(String)

    var description: String {
        switch self {
        case .stalled(let dump): "the operation can never finish\n\(dump)"
        case .deadlock(let dump): "the test body is waiting for something nothing can resume\n\(dump)"
        }
    }
}

/// A task that belongs to the world and runs on its thread.
final class SimTask<Value: Sendable>: Sendable {
    fileprivate final class Latch: Sendable {
        private let value = Mutex(false)
        var isSet: Bool { value.withLock { $0 } }
        func set() { value.withLock { $0 = true } }
    }

    let task: Task<Value, Never>
    private let done: Latch

    fileprivate init(task: Task<Value, Never>, done: Latch) {
        self.task = task
        self.done = done
    }

    var isFinished: Bool { done.isSet }
    var value: Value { get async { await task.value } }
    func cancel() { task.cancel() }
}

/// A closed, single-threaded simulation. The test body, every session task and the fake server's replies run on one
/// thread; virtual time is the fake server's clock and moves only through the driver calls below, each of which
/// returns once nothing is left to run.
final class SimWorld: Sendable {
    private struct Sleeper {
        let id: UInt64
        let clock: ObjectIdentifier
        var deadline: Timestamp
        let continuation: CheckedContinuation<Void, Never>
    }

    private enum Phase {
        case starting
        case running
        case aborted
        case over
    }

    private struct State {
        var sleepers: [Sleeper] = []
        var nextID: UInt64 = 0
        var settleWaiter: CheckedContinuation<Void, Never>?
        var phase = Phase.starting
        var failure: SimError?
        var completion: (@Sendable (SimError?) -> Void)?
        var cancels: [@Sendable () -> Void] = []
        var gates: [@Sendable () -> Void] = []
        var teardowns: [@Sendable () async -> Void] = []
    }

    let server: FakeChatServer
    let executor = SimExecutor()
    private let state = Mutex(State())

    private init(server: FakeChatServer) { self.server = server }

    // MARK: Running a test

    /// Runs `body` inside a new world and tears the world down afterwards. `watchdog` is real time: it ends the
    /// process if the body is still running then, which only a blocked thread or an endless loop can cause.
    static func run(
        server: FakeChatServer = FakeChatServer(), watchdog: Duration = .seconds(120),
        _ body: @escaping @Sendable (SimWorld) async throws -> Void
    ) async throws {
        let world = SimWorld(server: server)
        world.executor.start { [world] in world.whenIdle() }
        let guardian = Watchdog(limit: watchdog) { [weak world] in world?.dump() ?? "" }
        defer {
            guardian.disarm()
            world.executor.stop()
            world.forgetFixtures()
        }
        let outcome = Mutex<Result<Void, any Error>?>(nil)
        let root = Task(executorPreference: world.executor) {
            world.state.withLock { $0.phase = .running }
            let result: Result<Void, any Error>
            do {
                try await body(world)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await world.tearDown()
            outcome.withLock { $0 = result }
            world.finish(nil)
        }
        let failure: SimError? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let finishedAlready = world.state.withLock { state -> SimError?? in
                    if state.phase == .over { return .some(state.failure) }
                    state.completion = { continuation.resume(returning: $0) }
                    return nil
                }
                if let finishedAlready { continuation.resume(returning: finishedAlready) }
            }
        } onCancel: {
            root.cancel()
            world.executor.post { world.abort() }
        }
        if let failure {
            Issue.record("SimWorld: \(failure)")
            throw failure
        }
        if let diagnostic = world.state.withLock({ $0.failure }) { Issue.record("SimWorld: \(diagnostic)") }
        try outcome.withLock { $0 }?.get()
    }

    private func finish(_ failure: SimError?) {
        let completion = state.withLock { state -> (@Sendable (SimError?) -> Void)? in
            guard state.phase != .over else { return nil }
            state.phase = .over
            if let failure { state.failure = failure }
            defer { state.completion = nil }
            return state.completion
        }
        completion?(failure)
    }

    /// The queue is empty: wake what is due, then the settling test, and otherwise the body is stuck.
    private func whenIdle() -> Bool {
        let now = server.now
        let due = state.withLock { state -> [Sleeper] in
            let due = state.sleepers.filter { $0.deadline <= now }.sorted {
                ($0.deadline, $0.id) < ($1.deadline, $1.id)
            }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        if !due.isEmpty {
            for sleeper in due { sleeper.continuation.resume() }
            return true
        }
        if let waiter = state.withLock({ state -> CheckedContinuation<Void, Never>? in
            defer { state.settleWaiter = nil }
            return state.settleWaiter
        }) {
            waiter.resume()
            return true
        }
        switch state.withLock({ $0.phase }) {
        case .running:
            let dump = dump()
            state.withLock { $0.failure = .deadlock(dump) }
            abort()
            return true
        case .aborted:
            finish(.deadlock(dump()))
            return false
        case .starting, .over:
            return false
        }
    }

    /// Lets a stuck body move on: opens the gates and cancels the world's tasks.
    private func abort() {
        let (gates, cancels) = state.withLock { state -> ([@Sendable () -> Void], [@Sendable () -> Void]) in
            guard state.phase == .running else { return ([], []) }
            state.phase = .aborted
            return (state.gates, state.cancels)
        }
        for gate in gates { gate() }
        for cancel in cancels { cancel() }
    }

    /// Drops what the test registered, so a finished world keeps none of its sessions alive.
    private func forgetFixtures() {
        state.withLock { state in
            state.cancels = []
            state.gates = []
            state.teardowns = []
            state.completion = nil
        }
    }

    private func tearDown() async {
        let (gates, teardowns) = state.withLock { ($0.gates, $0.teardowns) }
        for gate in gates { gate() }
        for teardown in teardowns.reversed() { await teardown() }
        for cancel in state.withLock({ $0.cancels }) { cancel() }
        await settle()
    }

    /// Traps unless the caller is on this world's thread: work that escapes the simulation would race it.
    func requireThread(_ what: StaticString = #function) {
        precondition(executor.onThread, "\(what) ran off the simulation thread")
    }

    /// Opened when the world ends, so a task parked at a gate never outlives its test.
    func onTeardown(open gate: @escaping @Sendable () -> Void) {
        state.withLock { $0.gates.append(gate) }
    }

    /// Runs after the body, newest first. Each must end on its own; use `perform` and ignore a stall.
    func onTeardown(_ action: @escaping @Sendable () async -> Void) {
        state.withLock { $0.teardowns.append(action) }
    }

    // MARK: Tasks

    /// Starts `operation` as a task of this world. Every task a rig creates must come from here.
    @discardableResult
    func start<Value: Sendable>(_ operation: @escaping @Sendable () async -> Value) -> SimTask<Value> {
        let done = SimTask<Value>.Latch()
        let simTask = SimTask(
            task: Task(executorPreference: executor) {
                let value = await operation()
                done.set()
                return value
            }, done: done)
        state.withLock { $0.cancels.append { simTask.cancel() } }
        return simTask
    }

    /// Runs `operation` to its end, moving time as far as it needs within `limit` of virtual time. For anything
    /// that waits on the clock, such as a logout whose drain has a deadline.
    @discardableResult
    func perform<Value: Sendable>(
        upTo limit: Duration = .seconds(86_400), _ operation: @escaping @Sendable () async -> Value
    ) async throws -> Value {
        let task = start(operation)
        guard await run(upTo: limit, until: { task.isFinished }) else {
            task.cancel()
            throw SimError.stalled(dump())
        }
        return await task.value
    }

    // MARK: Time

    var now: Timestamp { server.now }

    func clock(offset: Duration = .zero) -> SimClock { SimClock(world: self, offset: offset) }

    /// A direct transport to this world's server that traps when used off the simulation thread.
    func transport() -> SimTransport { SimTransport(world: self, base: server.makeDirectTransport()) }

    /// A barrier that traps when reached off the simulation thread and opens when the world ends.
    func barrier() -> Barrier {
        let barrier = Barrier(onPass: { [executor] in
            precondition(executor.onThread, "a barrier was reached off the simulation thread")
        })
        onTeardown(open: { barrier.release() })
        return barrier
    }

    /// Brings every sleeper of `clock` nearer by `duration`: that clock alone moved forward.
    fileprivate func shift(_ clock: ObjectIdentifier, by duration: Duration) {
        state.withLock { state in
            for index in state.sleepers.indices where state.sleepers[index].clock == clock {
                state.sleepers[index].deadline = state.sleepers[index].deadline.adding(.zero - duration)
            }
        }
    }

    fileprivate func sleep(until deadline: Timestamp, on clock: ObjectIdentifier) async throws {
        requireThread()
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = server.now
                let resumeNow = state.withLock { state -> Bool in
                    if now >= deadline || Task.isCancelled { return true }
                    state.sleepers.append(
                        Sleeper(id: id, clock: clock, deadline: deadline, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume()
        }
        try Task.checkCancellation()
    }

    /// Deadlines of the tasks asleep on the clock, earliest first.
    var sleeperDeadlines: [Timestamp] { state.withLock { $0.sleepers.map(\.deadline).sorted() } }

    func hasSleeper(until deadline: Timestamp) -> Bool { sleeperDeadlines.contains(deadline) }

    // MARK: Driver

    /// Returns once nothing is queued and no sleeper is due at the current time.
    func settle() async {
        requireThread()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.withLock { state in
                precondition(state.settleWaiter == nil, "two callers are settling the same world")
                state.settleWaiter = continuation
            }
        }
    }

    /// Finishes what is runnable now, then moves time in one step and runs everything that became due. Earlier
    /// times leave the clock alone.
    func jump(to time: Timestamp) async {
        await settle()
        let now = server.now
        if time > now { server.advance(time.interval(since: now)) }
        await settle()
    }

    func jump(by duration: Duration) async {
        await settle()
        await jump(to: server.now.adding(duration))
    }

    /// Steps from deadline to deadline until `condition` holds. False when no sleeper is left to wake or the next
    /// one is later than `limit` of virtual time from now; nil means no limit.
    func run(upTo limit: Duration? = .seconds(120), until condition: () async -> Bool) async -> Bool {
        let end = limit.map { server.now.adding($0) }
        while true {
            await settle()
            if await condition() { return true }
            guard !Task.isCancelled, let next = sleeperDeadlines.first else { return false }
            if let end, next > end { return false }
            await jump(to: next)
        }
    }

    /// Lets `duration` of virtual time pass, running everything due up to and including its end.
    func pass(_ duration: Duration) async {
        let end = server.now.adding(duration)
        while !Task.isCancelled {
            await settle()
            guard let next = sleeperDeadlines.first, next <= end else { return await jump(to: end) }
            await jump(to: next)
        }
    }

    // MARK: Diagnostics

    func dump() -> String {
        let now = server.now
        let waits = sleeperDeadlines.map { "+\($0.interval(since: now))" }
        return "virtual time \(now.rfc3339); \(waits.count) asleep on the clock: \(waits.joined(separator: ", "))"
    }
}

/// `now()` is the world's time shifted by `offset`. A sleep parks until the driver reaches its deadline.
final class SimClock: SyncClock {
    let world: SimWorld
    private let shifted: Mutex<Duration>

    fileprivate init(world: SimWorld, offset: Duration) {
        self.world = world
        shifted = Mutex(offset)
    }

    var offset: Duration { shifted.withLock { $0 } }

    func now() -> Timestamp { world.now.adding(offset) }

    func sleep(for duration: Duration) async throws {
        try await world.sleep(until: world.now.adding(duration), on: ObjectIdentifier(self))
    }

    /// Moves this clock alone forward: its sleepers come due sooner, everyone else's are untouched.
    func advance(by duration: Duration) async {
        precondition(duration >= .zero, "a clock only moves forward")
        await world.settle()
        shifted.withLock { $0 += duration }
        world.shift(ObjectIdentifier(self), by: duration)
        await world.settle()
    }
}

/// The fake server's direct transport, confined to the world's thread.
struct SimTransport: HTTPTransport {
    let world: SimWorld
    let base: DirectTransport

    func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse {
        world.requireThread("a request")
        return try await base.send(request)
    }
}

/// Ends the process when a world outlives its real-time limit: its thread is blocked or it never goes quiet.
private final class Watchdog: Sendable {
    private let disarmed = Mutex(false)
    private let condition = NSCondition()

    init(limit: Duration, dump: @escaping @Sendable () -> String) {
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        let deadline = Date().addingTimeInterval(seconds)
        let thread = Thread { [self] in
            condition.lock()
            while !disarmed.withLock({ $0 }), Date() < deadline { condition.wait(until: deadline) }
            condition.unlock()
            if !disarmed.withLock({ $0 }) { fatalError("SimWorld watchdog: still running after \(limit). \(dump())") }
        }
        thread.name = "SimWorld watchdog"
        thread.start()
    }

    func disarm() {
        disarmed.withLock { $0 = true }
        condition.lock()
        condition.signal()
        condition.unlock()
    }
}

extension SnapshotRecorder {
    /// The consumer is a task of `world`, so at every settled point it has recorded all that was sent.
    convenience init(_ stream: AsyncStream<AccountSnapshot>, in world: SimWorld) {
        self.init(stream) { body in world.start(body).task }
    }

    /// Runs until `predicate` holds for a snapshot at or after position `since`.
    func wait(
        in world: SimWorld, since: Int = 0, where predicate: @escaping @Sendable (AccountSnapshot) -> Bool
    ) async -> AccountSnapshot? {
        let found = await world.run { history.dropFirst(since).contains(where: predicate) }
        return found ? history.dropFirst(since).first(where: predicate) : nil
    }
}
