import Foundation
import Synchronization
import Testing

@testable import ChatNet

/// Polls `condition` until it holds or `timeout` passes; the timeout only guards against hangs.
func waitUntil(timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

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

    @Test func waitersAreServedInArrivalOrder() async throws {
        let budget = MemoryBudget(capacity: 100)
        let full = try await budget.reserve(100)
        let order = Mutex<[Int]>([])
        let held = Mutex<[Reservation]>([])
        var tasks: [Task<Void, any Error>] = []
        for index in 0..<5 {
            tasks.append(
                Task {
                    let reservation = try await budget.reserve(60)
                    order.withLock { $0.append(index) }
                    held.withLock { $0.append(reservation) }
                    try await Task.sleep(for: .milliseconds(5))
                    reservation.release()
                })
            try #require(await waitUntil { budget.waiterCount == index + 1 })
        }
        full.release()
        for task in tasks { try await task.value }
        #expect(order.withLock { $0 } == [0, 1, 2, 3, 4])
        #expect(await budget.available == 100)
    }

    @Test func aLargeHeadWaiterIsNotStarvedBySmallerOnes() async throws {
        let budget = MemoryBudget(capacity: 100)
        let held = try await budget.reserve(60)
        let big = Task { try await budget.reserve(80) }
        try #require(await waitUntil { budget.waiterCount == 1 })
        #expect(await budget.tryReserve(10) == nil)
        let small = Task { try await budget.reserve(10) }
        try #require(await waitUntil { budget.waiterCount == 2 })
        held.release()
        let bigReservation = try await big.value
        #expect(bigReservation.bytes == 80)
        bigReservation.release()
        let smallReservation = try await small.value
        #expect(smallReservation.bytes == 10)
    }

    @Test func cancellationLeavesTheQueueAndUnblocksOthers() async throws {
        let budget = MemoryBudget(capacity: 100)
        let held = try await budget.reserve(90)
        let blocked = Task { try await budget.reserve(50) }
        try #require(await waitUntil { budget.waiterCount == 1 })
        let behind = Task { try await budget.reserve(5) }
        try #require(await waitUntil { budget.waiterCount == 2 })
        blocked.cancel()
        await #expect(throws: CancellationError.self) { _ = try await blocked.value }
        try #require(await waitUntil { budget.waiterCount == 0 })
        let granted = try await behind.value
        #expect(granted.bytes == 5)
        granted.release()
        held.release()
        #expect(await budget.available == 100)
    }

    @Test func alreadyCancelledTaskNeverEnqueues() async throws {
        let budget = MemoryBudget(capacity: 100)
        let held = try await budget.reserve(100)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await budget.reserve(1)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        held.release()
        #expect(await budget.available == 100)
    }

    @Test func thousandTasksNeverExceedCapacity() async throws {
        let capacity = 1000
        let budget = MemoryBudget(capacity: capacity)
        let inUse = Mutex(0)
        let peak = Mutex(0)
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
        #expect(peak.withLock { $0 } <= capacity)
        #expect(await budget.available == capacity)
    }

    @Test func cancelledStormLeavesTheBudgetWhole() async throws {
        let budget = MemoryBudget(capacity: 50)
        let held = try await budget.reserve(50)
        let tasks = (0..<200).map { _ in Task { try await budget.reserve(10).release() } }
        try #require(await waitUntil { budget.waiterCount == 200 })
        for task in tasks.prefix(150) { task.cancel() }
        held.release()
        var granted = 0
        for task in tasks where (try? await task.value) != nil {
            granted += 1
        }
        #expect(granted >= 50)
        #expect(await budget.available == 50)
    }
}
