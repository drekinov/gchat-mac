import ChatModel
import FakeChatServer
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatSync

private actor Journal {
    private let world: SimWorld
    private(set) var entries: [String] = []
    private(set) var offThread = 0

    init(_ world: SimWorld) { self.world = world }

    func note(_ entry: String) {
        if !world.executor.onThread { offThread += 1 }
        entries.append(entry)
    }
}

/// Blocks the calling thread, which an async function may not do directly.
private func blockThread(until semaphore: DispatchSemaphore) { semaphore.wait() }

@concurrent private func hopsOffItsCaller(_ world: SimWorld) async -> Bool { world.executor.onThread }

/// The guarantees every `SimWorld` rig relies on.
struct SimWorldTests {
    // MARK: Confinement

    @Test func actorsGroupsAndConcurrentFunctionsStayOnTheThread() async throws {
        try await SimWorld.run { world in
            #expect(world.executor.onThread)
            let journal = Journal(world)
            await journal.note("body")
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<4 {
                    group.addTask {
                        #expect(world.executor.onThread)
                        await journal.note("child \(index)")
                    }
                }
            }
            #expect(await hopsOffItsCaller(world))
            #expect(world.executor.onThread)
            let started = world.start { world.executor.onThread }
            #expect(await started.value)
            #expect(await journal.offThread == 0)
            #expect(await journal.entries.count == 5)
        }
    }

    @Test func callersQueuedBehindABusyActorStayOnTheThread() async throws {
        try await SimWorld.run { world in
            let journal = Journal(world)
            let gate = world.barrier()
            gate.arm()
            let first = world.start {
                await journal.note("first in")
                await gate.pass()
                await journal.note("first out")
            }
            for index in 0..<4 { world.start { await journal.note("queued \(index)") } }
            await world.settle()
            #expect(await journal.entries == ["first in", "queued 0", "queued 1", "queued 2", "queued 3"])
            gate.release()
            await first.value
            #expect(await journal.offThread == 0)
        }
    }

    // MARK: Settling

    @Test func settleReturnsOnlyOnceEverythingStartedHasRun() async throws {
        try await SimWorld.run { world in
            let journal = Journal(world)
            for index in 0..<5 {
                world.start {
                    await journal.note("a\(index)")
                    await Task.yield()
                    await journal.note("b\(index)")
                }
            }
            await world.settle()
            #expect(await journal.entries.count == 10)
        }
    }

    @Test func aGroupChildHeldAtAGateDoesNotHideItsSiblingsWork() async throws {
        try await SimWorld.run { world in
            let journal = Journal(world)
            let gate = world.barrier()
            gate.arm()
            let group = world.start {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await gate.pass()
                        await journal.note("held")
                    }
                    group.addTask { await journal.note("sibling") }
                }
            }
            await world.settle()
            #expect(await journal.entries == ["sibling"])
            #expect(!group.isFinished)
            gate.release()
            await world.settle()
            #expect(await journal.entries == ["sibling", "held"])
            #expect(group.isFinished)
        }
    }

    // MARK: The clock

    @Test func timeMovesOnlyThroughTheDriver() async throws {
        try await SimWorld.run { world in
            let clock = world.clock()
            let start = world.now
            let sleeper = world.start { try? await clock.sleep(for: .seconds(10)) }
            await world.settle()
            #expect(world.now == start)
            #expect(world.sleeperDeadlines == [start.adding(.seconds(10))])
            #expect(!sleeper.isFinished)
            await world.jump(by: .seconds(9))
            #expect(!sleeper.isFinished)
            await world.jump(by: .seconds(1))
            #expect(sleeper.isFinished)
            #expect(world.sleeperDeadlines.isEmpty)
        }
    }

    @Test func tiedDeadlinesWakeInTheOrderTheyWentToSleep() async throws {
        try await SimWorld.run { world in
            let clock = world.clock()
            let journal = Journal(world)
            for index in 0..<5 {
                world.start {
                    try? await clock.sleep(for: .seconds(3))
                    await journal.note("\(index)")
                }
                await world.settle()
            }
            #expect(await world.run { await journal.entries.count == 5 })
            #expect(await journal.entries == ["0", "1", "2", "3", "4"])
        }
    }

    @Test func runStepsFromDeadlineToDeadlineAndStopsAtItsLimit() async throws {
        try await SimWorld.run { world in
            let clock = world.clock()
            let start = world.now
            let ticks = Recorder<Duration>()
            world.start {
                for _ in 0..<3 {
                    try? await clock.sleep(for: .seconds(60))
                    ticks.append(world.now.interval(since: start))
                }
            }
            #expect(await world.run(upTo: .seconds(100)) { ticks.all.count == 2 } == false)
            #expect(ticks.all == [.seconds(60)])
            #expect(await world.run { ticks.all.count == 3 })
            #expect(ticks.all == [.seconds(60), .seconds(120), .seconds(180)])
            #expect(await world.run { false } == false, "nothing is left to wake")
        }
    }

    @Test func passRunsWhatIsDueUpToAndIncludingItsEnd() async throws {
        try await SimWorld.run { world in
            let clock = world.clock()
            let start = world.now
            let woke = Recorder<Int>()
            for seconds in [5, 30, 31] {
                world.start {
                    try? await clock.sleep(for: .seconds(seconds))
                    woke.append(seconds)
                }
            }
            await world.pass(.seconds(30))
            #expect(woke.all == [5, 30])
            #expect(world.now == start.adding(.seconds(30)))
        }
    }

    @Test func aJumpWakesEverythingOverdueAtTheNewTime() async throws {
        try await SimWorld.run { world in
            let clock = world.clock()
            let start = world.now
            let woke = Recorder<Duration>()
            for seconds in [5, 50] {
                world.start {
                    try? await clock.sleep(for: .seconds(seconds))
                    woke.append(world.now.interval(since: start))
                }
            }
            await world.jump(by: .seconds(100))
            #expect(woke.all == [.seconds(100), .seconds(100)])
        }
    }

    @Test func clocksWithDifferentOffsetsShareOneTimeline() async throws {
        try await SimWorld.run { world in
            let ahead = world.clock(offset: .seconds(3600))
            let plain = world.clock()
            #expect(ahead.now() == plain.now().adding(.seconds(3600)))
            let sleeper = world.start { try? await ahead.sleep(for: .seconds(10)) }
            await world.jump(by: .seconds(10))
            #expect(sleeper.isFinished)
        }
    }

    @Test func advancingOneClockBringsOnlyItsOwnSleepersNearer() async throws {
        try await SimWorld.run { world in
            let first = world.clock()
            let second = world.clock()
            let start = world.now
            let sleepers = [first, second].map { clock in
                world.start { try? await clock.sleep(for: .seconds(60)) }
            }
            await first.advance(by: .seconds(59))
            #expect(first.now() == second.now().adding(.seconds(59)))
            #expect(!sleepers[0].isFinished && !sleepers[1].isFinished)
            await first.advance(by: .seconds(1))
            #expect(sleepers[0].isFinished)
            #expect(!sleepers[1].isFinished)
            #expect(world.now == start)
            await world.jump(by: .seconds(60))
            #expect(sleepers[1].isFinished)
        }
    }

    @Test func cancellingBeforeTheSleepIsRegisteredLeavesNoSleeper() async throws {
        try await SimWorld.run { world in
            let clock = world.clock()
            let outcome = Recorder<Bool>()
            let task = world.start {
                do {
                    try await clock.sleep(for: .seconds(10))
                    outcome.append(false)
                } catch {
                    outcome.append(true)
                }
            }
            task.cancel()
            await world.settle()
            #expect(outcome.all == [true])
            #expect(world.sleeperDeadlines.isEmpty)
        }
    }

    @Test func cancellingASleeperWakesItOnceAndItsDeadlineWakesNothing() async throws {
        try await SimWorld.run { world in
            let clock = world.clock()
            let outcome = Recorder<Bool>()
            let task = world.start {
                do {
                    try await clock.sleep(for: .seconds(10))
                    outcome.append(false)
                } catch {
                    outcome.append(true)
                }
            }
            await world.settle()
            #expect(world.sleeperDeadlines.count == 1)
            task.cancel()
            await world.settle()
            #expect(outcome.all == [true])
            #expect(world.sleeperDeadlines.isEmpty)
            await world.jump(by: .seconds(20))
            #expect(outcome.all == [true])
        }
    }

    // MARK: Operations that need time

    @Test func performMovesTimeUntilTheOperationEnds() async throws {
        try await SimWorld.run { world in
            let clock = world.clock()
            let start = world.now
            let value = try await world.perform { () -> Int in
                try? await clock.sleep(for: .seconds(42))
                return 7
            }
            #expect(value == 7)
            #expect(world.now == start.adding(.seconds(42)))
        }
    }

    @Test func performReportsAnOperationThatCanNeverEnd() async throws {
        try await SimWorld.run { world in
            let gate = world.barrier()
            gate.arm()
            await #expect(throws: SimError.self) {
                try await world.perform { await gate.pass() }
            }
        }
    }

    @Test func aFinishedDrainCancelsItsTimer() async throws {
        try await SimWorld.run { world in
            let clock = world.clock()
            let registry = WorkRegistry(executor: world.executor)
            registry.spawn { try? await clock.sleep(for: .seconds(3600)) }
            await world.settle()
            let start = world.now
            let drained = try await world.perform { await registry.cancelAndDrain(timeout: .seconds(2), clock: clock) }
            #expect(drained)
            #expect(world.now == start, "the tasks ended on cancellation, with no time passing")
            #expect(world.sleeperDeadlines.isEmpty, "the drain's own timer is gone")
        }
    }

    @Test func aDrainGivesUpAtItsDeadlineWhenATaskIgnoresCancellation() async throws {
        try await SimWorld.run { world in
            let clock = world.clock()
            let registry = WorkRegistry(executor: world.executor)
            let gate = world.barrier()
            gate.arm()
            registry.spawn { await gate.pass() }
            await world.settle()
            let start = world.now
            let drained = try await world.perform { await registry.cancelAndDrain(timeout: .seconds(2), clock: clock) }
            #expect(!drained)
            #expect(world.now == start.adding(.seconds(2)))
            #expect(registry.count == 1)
            gate.release()
            await world.settle()
            #expect(registry.count == 0)
        }
    }

    // MARK: Failure modes

    @Test func aBodyWaitingAtAGateTheWorldOwnsIsReportedAndMovesOn() async throws {
        let reached = Recorder<String>()
        await withKnownIssue {
            try await SimWorld.run { world in
                let gate = world.barrier()
                gate.arm()
                await gate.pass()
                reached.append("after the gate")
            }
        }
        #expect(reached.all == ["after the gate"])
    }

    @Test func aBodyNothingCanResumeFailsTheTestAtOnce() async throws {
        await withKnownIssue {
            await #expect(throws: SimError.self) {
                try await SimWorld.run { _ in
                    let lost = Barrier()
                    lost.arm()
                    await lost.pass()
                }
            }
        }
    }

    @Test func cancellingTheTestEndsALongDrive() async throws {
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        let test = Task {
            try await SimWorld.run { world in
                let clock = world.clock()
                world.start {
                    while !Task.isCancelled { try? await clock.sleep(for: .seconds(1)) }
                }
                signal.yield()
                await world.pass(.seconds(1_000_000_000))
            }
        }
        for await _ in started { break }
        test.cancel()
        _ = await test.result
    }

    /// The body blocks until the other thread has run, so the trap is the only way this process can fail.
    @Test func workThatLeavesTheThreadTraps() async {
        await #expect(processExitsWith: .failure) {
            try await SimWorld.run { world in
                let ran = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    world.requireThread()
                    ran.signal()
                }
                blockThread(until: ran)
            }
        }
    }

    @Test func aBarrierReachedOffTheThreadTraps() async {
        await #expect(processExitsWith: .failure) {
            try await SimWorld.run { world in
                let barrier = world.barrier()
                let ran = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    Task {
                        await barrier.pass()
                        ran.signal()
                    }
                }
                blockThread(until: ran)
            }
        }
    }

    @Test func aBlockedThreadEndsTheProcess() async {
        await #expect(processExitsWith: .failure) {
            try await SimWorld.run(watchdog: .milliseconds(300)) { _ in
                while true {}
            }
        }
    }

    @Test func aLoopThatKeepsSettlingEndsTheProcess() async {
        await #expect(processExitsWith: .failure) {
            try await SimWorld.run(watchdog: .milliseconds(300)) { world in
                while true { await world.settle() }
            }
        }
    }

    // MARK: Transport

    @Test func requestsAreServedOnTheThreadInTheOrderIssued() async throws {
        try await SimWorld.run { world in
            let server = world.server
            let alice = server.addAccount(displayName: "Alice")
            let space = server.addSpace(.space, displayName: "Team", members: [alice])
            let client = GoogleChatClient(transport: world.transport(), tokens: StaticTokens(token: alice.token))
            let order = Recorder<Int>()
            for index in 0..<8 {
                world.start {
                    _ = try? await client.getSpace(space)
                    order.append(index)
                }
            }
            await world.settle()
            #expect(order.all == Array(0..<8))
            #expect(server.requests.count == 8)
        }
    }
}
