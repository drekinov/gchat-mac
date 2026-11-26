import ChatModel
import ChatStore
import Foundation
import Synchronization
import Testing

@testable import ChatSync

/// Blocks the threads that reach `pass()` until the test opens it, and counts them.
private final class ThreadHold: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var arrivals = 0

    var arrived: Int {
        condition.lock()
        defer { condition.unlock() }
        return arrivals
    }

    func pass() {
        condition.lock()
        defer { condition.unlock() }
        arrivals += 1
        while !isOpen { condition.wait() }
    }

    func open() {
        condition.lock()
        defer { condition.unlock() }
        isOpen = true
        condition.broadcast()
    }
}

@Suite struct ExportSweeperTests {
    static let interval: Duration = .seconds(3600)

    @Test func requestsDuringASweepRunItOnceMoreNotOncePerRequest() async throws {
        let runs = Atomic<Int>(0)
        let firstRun = ThreadHold()
        defer { firstRun.open() }
        let sweeper = ExportSweeper {
            if runs.add(1, ordering: .sequentiallyConsistent).newValue == 1 { firstRun.pass() }
        }

        let first = Running { await sweeper.request() }
        try #require(await eventually { firstRun.arrived == 1 })
        let burst = Running {
            for _ in 0..<5 { await sweeper.request() }
        }
        try #require(await burst.settled() != nil, "a request waited for the sweep in progress")
        #expect(runs.load(ordering: .sequentiallyConsistent) == 1)
        firstRun.open()
        try #require(await first.settled() != nil)
        #expect(runs.load(ordering: .sequentiallyConsistent) == 2)
    }

    @Test func itSweepsOnItsOwnAfterEachIntervalUntilCancelled() async throws {
        let runs = Atomic<Int>(0)
        let pauses = Pauses()
        let sweeper = ExportSweeper(sleep: pauses.sleep) { runs.add(1, ordering: .sequentiallyConsistent) }
        let sweeps = Running { await sweeper.repeating(every: Self.interval) }
        defer { sweeps.cancel() }
        for round in 1...3 {
            try #require(await eventually { pauses.asked.count == round })
            #expect(pauses.asked.last == Self.interval)
            #expect(runs.load(ordering: .sequentiallyConsistent) == round - 1)
            pauses.fire(round - 1)
        }
        try #require(await eventually { pauses.asked.count == 4 })
        #expect(runs.load(ordering: .sequentiallyConsistent) == 3)

        sweeps.cancel()
        try #require(await sweeps.settled() != nil, "cancelling did not end the sweeps")
        #expect(pauses.endings == [.fired, .fired, .fired, .cancelled])
        #expect(runs.load(ordering: .sequentiallyConsistent) == 3)
    }

    @Test func aCopyExpiresWithoutAnotherExport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gchat-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = AccountDirectory(root: root, account: AccountID())
        try directory.createExports()
        let folder = directory.exportsURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("opened once".utf8).write(to: folder.appendingPathComponent("doc.pdf"))
        // Two days on, with no export in between.
        let later = Date().addingTimeInterval(2 * 86_400)
        let pauses = Pauses()
        let sweeper = ExportSweeper(sleep: pauses.sleep) {
            try? ExportDirectory.pruneAll(root: root, changedBefore: later.addingTimeInterval(-ExportDirectory.maxAge))
        }

        let sweeps = Running { await sweeper.repeating(every: Self.interval) }
        defer { sweeps.cancel() }
        try #require(await eventually { pauses.asked.count == 1 })
        #expect(FileManager.default.fileExists(atPath: folder.path))
        pauses.fire(0)
        try #require(await eventually { pauses.asked.count == 2 })
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
