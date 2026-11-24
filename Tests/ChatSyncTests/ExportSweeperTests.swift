import ChatModel
import ChatStore
import Foundation
import Testing

@testable import ChatSync

@Suite struct ExportSweeperTests {
    @Test func requestsDuringASweepRunItOnceMoreNotOncePerRequest() async {
        let runs = Recorder<Int>()
        let firstRun = DispatchSemaphore(value: 0)
        let sweeper = ExportSweeper {
            runs.append(1)
            if runs.all.count == 1 { firstRun.wait() }
        }

        let first = Task { await sweeper.request() }
        #expect(await poll { runs.all.count == 1 })
        for _ in 0..<5 { await sweeper.request() }
        firstRun.signal()
        await first.value
        #expect(runs.all.count == 2)
    }

    @Test func itSweepsOnItsOwnWithoutBeingAsked() async {
        let runs = Recorder<Int>()
        let sweeper = ExportSweeper { runs.append(1) }
        let sweeps = Task { await sweeper.repeating(every: .milliseconds(20)) }
        defer { sweeps.cancel() }
        #expect(await poll { runs.all.count >= 3 })
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
        let sweeper = ExportSweeper {
            try? ExportDirectory.pruneAll(root: root, changedBefore: later.addingTimeInterval(-ExportDirectory.maxAge))
        }

        let sweeps = Task { await sweeper.repeating(every: .milliseconds(20)) }
        defer { sweeps.cancel() }
        #expect(await poll { !FileManager.default.fileExists(atPath: folder.path) })
    }
}
