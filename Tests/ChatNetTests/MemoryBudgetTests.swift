import Foundation
import Synchronization
import Testing

@testable import ChatNet

@Suite struct MemoryBudgetTests {
    @Test func reservesAndReleases() async throws {
        let budget = MemoryBudget(capacity: 100)
        let first = try await budget.reserve(60)
        #expect(await budget.available == 40)
        #expect(first.bytes == 60)
        first.release()
        #expect(await budget.available == 100)
        #expect(first.bytes == 0)
    }

    @Test func doubleReleaseReturnsBytesOnce() async throws {
        let budget = MemoryBudget(capacity: 100)
        let first = try await budget.reserve(30)
        let second = try await budget.reserve(30)
        first.release()
        first.release()
        #expect(await budget.available == 70)
        second.release()
        #expect(await budget.available == 100)
    }

    @Test func deinitReleases() async throws {
        let budget = MemoryBudget(capacity: 100)
        do {
            let reservation = try await budget.reserve(80)
            #expect(await budget.available == 20)
            _ = reservation
        }
        #expect(await budget.available == 100)
    }

    @Test func tryReserveFailsWhenFull() async throws {
        let budget = MemoryBudget(capacity: 100)
        let held = await budget.tryReserve(70)
        #expect(held != nil)
        #expect(await budget.tryReserve(31) == nil)
        #expect(await budget.tryReserve(30) != nil)
        _ = held
    }

    @Test func oversizedRequestFailsImmediately() async {
        let budget = MemoryBudget(capacity: 100)
        await #expect(throws: MemoryBudgetError.exceedsCapacity(requested: 101, capacity: 100)) {
            _ = try await budget.reserve(101)
        }
        await #expect(throws: MemoryBudgetError.invalidSize) { _ = try await budget.reserve(-1) }
        #expect(await budget.tryReserve(101) == nil)
    }

    @Test func shrinkReturnsTheDifferenceOnly() async throws {
        let budget = MemoryBudget(capacity: 100)
        let reservation = try await budget.reserve(80)
        reservation.shrink(to: 30)
        #expect(await budget.available == 70)
        reservation.shrink(to: 50)
        #expect(reservation.bytes == 30)
        reservation.release()
        #expect(await budget.available == 100)
    }

    /// Each waiter keeps its 60 bytes until the test opens its turn, so only one can hold the budget at a time.
    @Test func waitersAreServedInArrivalOrder() async throws {
        let budget = MemoryBudget(capacity: 100)
        let full = try await budget.reserve(100)
        let order = Mutex<[Int]>([])
        let turns = (0..<5).map { _ in Gate() }
        defer { for turn in turns { turn.open() } }
        var holders: [Recorded<Result<Void, any Error>>] = []
        for index in 0..<5 {
            holders.append(
                Recorded(catching: {
                    let reservation = try await budget.reserve(60)
                    order.withLock { $0.append(index) }
                    try await turns[index].wait()
                    reservation.release()
                }))
            try #require(await eventually { budget.waiterCount == index + 1 })
        }
        full.release()
        for index in 0..<5 {
            try #require(await eventually { order.withLock { $0.count } == index + 1 })
            #expect(order.withLock { $0 } == Array(0...index))
            #expect(budget.waiterCount == 4 - index)
            turns[index].open()
        }
        for holder in holders { try #require(await holder.settled()).get() }
        #expect(await budget.available == 100)
    }

    @Test func aLargeHeadWaiterIsNotStarvedBySmallerOnes() async throws {
        let budget = MemoryBudget(capacity: 100)
        let held = try await budget.reserve(60)
        let big = Recorded(catching: { try await budget.reserve(80) })
        defer { big.cancel() }
        try #require(await eventually { budget.waiterCount == 1 })
        #expect(await budget.tryReserve(10) == nil)
        let small = Recorded(catching: { try await budget.reserve(10) })
        defer { small.cancel() }
        try #require(await eventually { budget.waiterCount == 2 })
        held.release()
        let bigReservation = try #require(await big.settled()).get()
        #expect(bigReservation.bytes == 80)
        bigReservation.release()
        let smallReservation = try #require(await small.settled()).get()
        #expect(smallReservation.bytes == 10)
    }

    @Test func cancellationLeavesTheQueueAndUnblocksOthers() async throws {
        let budget = MemoryBudget(capacity: 100)
        let held = try await budget.reserve(90)
        let blocked = Recorded(catching: { try await budget.reserve(50) })
        try #require(await eventually { budget.waiterCount == 1 })
        let behind = Recorded(catching: { try await budget.reserve(5) })
        defer { behind.cancel() }
        try #require(await eventually { budget.waiterCount == 2 })
        blocked.cancel()
        let refused = try #require(await blocked.settled())
        #expect(throws: CancellationError.self) { _ = try refused.get() }
        try #require(await eventually { budget.waiterCount == 0 })
        let granted = try #require(await behind.settled()).get()
        #expect(granted.bytes == 5)
        granted.release()
        held.release()
        #expect(await budget.available == 100)
    }

    @Test func alreadyCancelledTaskNeverEnqueues() async throws {
        let budget = MemoryBudget(capacity: 100)
        let held = try await budget.reserve(100)
        let attempt = Recorded(catching: {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await budget.reserve(1)
        })
        let refused = try #require(await attempt.settled())
        #expect(throws: CancellationError.self) { _ = try refused.get() }
        held.release()
        #expect(await budget.available == 100)
    }

    @Test func thousandTasksNeverExceedCapacity() async throws {
        let capacity = 1000
        let budget = MemoryBudget(capacity: capacity)
        let inUse = Mutex(0)
        let peak = Mutex(0)
        let storm = Recorded(catching: {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<1000 {
                    group.addTask {
                        let size = 1 + (index * 37) % 400
                        let reservation = try await budget.reserve(size)
                        let now = inUse.withLock { value -> Int in
                            value += size
                            return value
                        }
                        peak.withLock { $0 = max($0, now) }
                        await Task.yield()
                        inUse.withLock { $0 -= size }
                        reservation.release()
                    }
                }
                try await group.waitForAll()
            }
        })
        defer { storm.cancel() }
        try #require(await storm.settled()).get()
        #expect(peak.withLock { $0 } <= capacity)
        #expect(await budget.available == capacity)
    }

    @Test func cancelledStormLeavesTheBudgetWhole() async throws {
        let budget = MemoryBudget(capacity: 50)
        let held = try await budget.reserve(50)
        let attempts = (0..<200).map { _ in Recorded(catching: { try await budget.reserve(10).release() }) }
        try #require(await eventually { budget.waiterCount == 200 })
        for attempt in attempts.prefix(150) { attempt.cancel() }
        held.release()
        var granted = 0
        var refused = 0
        for attempt in attempts {
            switch try #require(await attempt.settled()) {
            case .success: granted += 1
            case .failure: refused += 1
            }
        }
        #expect(granted == 50)
        #expect(refused == 150)
        #expect(await budget.available == 50)
    }
}
