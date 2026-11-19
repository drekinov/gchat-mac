import ChatModel
import Foundation
import Testing

@testable import ChatStore

extension Fixture {
    func write(_ operations: StoreWrite.Operation...) throws -> StoreWriteResult {
        try store.write(gate: gate, generation: generation) { batch in
            for operation in operations { batch.append(operation) }
        }
    }
}

@Suite struct BookkeepingStoreTests {
    let a = spaceName("A")

    @Test(arguments: Backend.allCases)
    func metasReturnOnlyKeysWithThePrefix(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(
            .setMeta(key: "owed|spaces/A", value: "1"), .setMeta(key: "owed|spaces/B", value: "2"),
            .setMeta(key: "owed", value: "x"), .setMeta(key: "owed}", value: "x"), .setMeta(key: "owee", value: "x"),
            .setMeta(key: "notify|spaces/A", value: "3"), .setMeta(key: "owedé", value: "x"))
        #expect(try f.store.metas(prefix: "owed|") == ["owed|spaces/A": "1", "owed|spaces/B": "2"])
        #expect(try f.store.metas(prefix: "notify|") == ["notify|spaces/A": "3"])
        #expect(try f.store.metas(prefix: "owedé").count == 1)
        #expect(try f.store.metas(prefix: "missing|").isEmpty)
        if backend == .sqlite {
            try f.reopenSQLite()
            #expect(try f.store.metas(prefix: "owed|").count == 2)
        }
    }

    @Test(arguments: Backend.allCases)
    func mergeTakesTheMaxBoundaryUnionsIDsAndBumpsTheRevision(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.mergeOwed(a, boundary: stamp(20), messages: [messageName("A", "m1")]))
        let first = try #require(try f.store.owed(a))
        try f.commit(.deferOwed(a, revision: first.revision, at: stamp(100)))
        #expect(try f.store.owed(a)?.attempts == 1)
        try f.commit(
            .mergeOwed(
                a, boundary: stamp(10),
                messages: [messageName("A", "m1"), messageName("A", "m2"), messageName("B", "foreign")]))
        let merged = try #require(try f.store.owed(a))
        #expect(merged.boundary == stamp(20))
        #expect(merged.messages(in: a) == [messageName("A", "m1"), messageName("A", "m2")])
        #expect(merged.revision > first.revision)
        #expect(merged.attempts == 0)
        #expect(merged.nextTry == nil)
    }

    @Test(arguments: Backend.allCases)
    func revisionsNeverRepeatAfterARowIsRecreated(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.mergeOwed(a, boundary: stamp(20), messages: []))
        let first = try #require(try f.store.owed(a)).revision
        try f.commit(.clearOwed(a), .mergeOwed(a, boundary: stamp(20), messages: []))
        #expect(try #require(try f.store.owed(a)).revision != first)
    }

    @Test(arguments: Backend.allCases)
    func resolveNeedsTheSameRevisionStrictCoverageAndEveryID(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.mergeOwed(a, boundary: stamp(20), messages: []))
        let revision = try #require(try f.store.owed(a)).revision

        try f.commit(.resolveOwed(a, revision: revision, coveredUpTo: stamp(20), fetched: []))
        #expect(try f.store.owed(a) != nil, "the message at the boundary isn't covered by an end equal to it")
        try f.commit(.resolveOwed(a, revision: revision + 1, coveredUpTo: stamp(21), fetched: []))
        #expect(try f.store.owed(a) != nil, "a newer write keeps the row")
        try f.commit(.resolveOwed(a, revision: revision, coveredUpTo: stamp(21), fetched: []))
        #expect(try f.store.owed(a) == nil)
    }

    @Test(arguments: Backend.allCases)
    func resolveRemovesStoredAndGoneIDsEvenWhenTheRowStays(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let ids = ["m1", "m2", "m3"].map { messageName("A", $0) }
        try f.commit(.mergeOwed(a, boundary: stamp(20), messages: ids))
        let revision = try #require(try f.store.owed(a)).revision
        try f.commit(
            .upsertMessages([makeMessage(id: "m1", at: 5)]),
            .resolveOwed(a, revision: revision + 7, coveredUpTo: stamp(30), fetched: [ids[1]]))
        #expect(try f.store.owed(a)?.messages(in: a) == [ids[2]])
        try f.commit(.resolveOwed(a, revision: revision, coveredUpTo: stamp(30), fetched: []))
        #expect(try f.store.owed(a)?.messages(in: a) == [ids[2]], "a missing ID keeps the row")
        try f.commit(.resolveOwed(a, revision: revision, coveredUpTo: stamp(30), fetched: [ids[2]]))
        #expect(try f.store.owed(a) == nil)
    }

    @Test(arguments: Backend.allCases)
    func aSpaceKeepsAtMostAThousandIDsAndReportsTheRest(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let ids = (0..<1005).map { messageName("A", "m\($0)") }
        let first = try f.write(.mergeOwed(a, boundary: stamp(20), messages: Array(ids.prefix(600))))
        #expect(first.rejectedOwed.isEmpty)
        let second = try f.write(.mergeOwed(a, boundary: stamp(20), messages: Array(ids.dropFirst(590))))
        #expect(second.rejectedOwed == Array(ids.suffix(5)))
        #expect(try f.store.owed(a)?.ids.count == OwedRecord.maxMessages)
    }

    @Test(arguments: Backend.allCases)
    func failedAttemptsBackOffAndDropOnlyRowsWithoutIDs(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let b = spaceName("B")
        try f.commit(
            .mergeOwed(a, boundary: stamp(20), messages: []),
            .mergeOwed(b, boundary: stamp(20), messages: [messageName("B", "m")]))
        var delays: [Int64] = []
        for attempt in 1...6 {
            let revisionA = try f.store.owed(a)?.revision ?? 0
            let revisionB = try #require(try f.store.owed(b)).revision
            try f.commit(
                .deferOwed(a, revision: revisionA, at: stamp(1000)), .deferOwed(b, revision: revisionB, at: stamp(1000))
            )
            if attempt < OwedRecord.maxAttempts { #expect(try f.store.owed(a)?.attempts == attempt) }
            delays.append(try #require(try f.store.owed(b)?.nextTry).seconds - 1000)
        }
        #expect(delays == [30, 120, 600, 3600, 3600, 3600])
        #expect(try f.store.owed(a) == nil)
        #expect(try f.store.owed(b)?.attempts == 6)
        #expect(try f.store.droppedOwedCount() == 1)

        let revision = try #require(try f.store.owed(b)).revision
        try f.commit(.mergeOwed(b, boundary: stamp(5), messages: []))
        try f.commit(.deferOwed(b, revision: revision, at: stamp(2000)))
        #expect(try f.store.owed(b)?.attempts == 0, "a stale revision doesn't count against new data")
    }

    @Test(arguments: Backend.allCases)
    func listingsThatOmitASpaceDropOnlyRowsWithoutIDs(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let b = spaceName("B")
        try f.commit(
            .mergeOwed(a, boundary: stamp(20), messages: []),
            .mergeOwed(b, boundary: stamp(20), messages: [messageName("B", "m")]))
        for _ in 0..<OwedRecord.maxOmissions { try f.commit(.owedOmitted(a), .owedOmitted(b)) }
        #expect(try f.store.owed(a) == nil)
        #expect(try f.store.owed(b)?.omitted == 3)
        #expect(try f.store.owedRecords().keys.sorted() == [b])
    }

    @Test(arguments: Backend.allCases)
    func relistResolvesOnlyTheVersionAListingSaw(_ backend: Backend) throws {
        let f = try Fixture(backend)
        #expect(try f.store.relist() == RelistRecord())
        try f.commit(.bumpRelist)
        let seen = try f.store.relist().requested
        try f.commit(.bumpRelist)
        try f.commit(.resolveRelist(seen))
        #expect(try f.store.relist().isPending)
        try f.commit(.resolveRelist(seen - 1))
        #expect(try f.store.relist().resolved == seen)
        try f.commit(.resolveRelist(try f.store.relist().requested))
        #expect(try !f.store.relist().isPending)
        try f.commit(.resolveRelist(99))
        #expect(try f.store.relist() == RelistRecord(requested: 2, resolved: 2))
    }

    @Test(arguments: Backend.allCases)
    func candidatesSkipStoredAndNotifiedMessagesAndCollapsePastTwenty(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(
            .upsertMessages([makeMessage(id: "stored", at: 1)]),
            .markNotified([messageName("A", "notified")], at: stamp(1)))
        try f.commit(
            .addNotifyCandidates(
                a,
                ["stored", "notified", "new1", "new1", "new2"].map { messageName("A", $0) } + [messageName("B", "x")]),
            .upsertMessages([makeMessage(id: "new1", at: 2), makeMessage(id: "new2", at: 3)]))
        #expect(try f.store.notifyRecords()[a] == NotifyRecord(ids: ["new1", "new2"]))
        try f.commit(.addNotifyCandidates(a, (0..<19).map { messageName("A", "c\($0)") }))
        #expect(try f.store.notifyRecords()[a] == NotifyRecord(ids: [], overflow: 21))
        try f.commit(.addNotifyCandidates(a, [messageName("A", "after")]), .flagNotifyGap(a))
        #expect(try f.store.notifyRecords()[a] == NotifyRecord(ids: ["after"], overflow: 21, gap: true))

        try f.commit(.removeNotifyPending(a, messages: [], overflow: 21, gap: true))
        #expect(try f.store.notifyRecords()[a] == NotifyRecord(ids: ["after"]))
        try f.commit(.removeNotifyPending(a, messages: [messageName("A", "after")], overflow: 0, gap: false))
        #expect(try f.store.notifyRecords().isEmpty)
        #expect(try f.store.metas(prefix: NotifyRecord.keyPrefix).isEmpty)
    }

    @Test(arguments: Backend.allCases)
    func deletingASpaceDropsItsPendingNotifications(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.mergeSpace(makeSpace("A")), .addNotifyCandidates(a, [messageName("A", "m")]))
        try f.commit(.deleteSpace(a))
        #expect(try f.store.notifyRecords().isEmpty)
    }

    @Test(arguments: Backend.allCases)
    func undecodableRecordsCountAsAbsent(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(
            .setMeta(key: OwedRecord.key(a), value: "{"), .setMeta(key: NotifyRecord.key(a), value: "nope"),
            .setMeta(key: RelistRecord.key, value: "[]"))
        #expect(try f.store.owed(a) == nil)
        #expect(try f.store.owedRecords().isEmpty)
        #expect(try f.store.notifyRecords().isEmpty)
        #expect(try f.store.relist() == RelistRecord())
        try f.commit(.mergeOwed(a, boundary: stamp(3), messages: []), .bumpRelist)
        #expect(try f.store.owed(a)?.boundary == stamp(3))
        #expect(try f.store.relist().requested == 1)
    }

    @Test func recordsAreSealedAndTheSchemaVersionIsUnchanged() throws {
        let f = try Fixture(.sqlite)
        try f.commit(
            .mergeOwed(a, boundary: stamp(20), messages: [messageName("A", "owedcanary")]),
            .addNotifyCandidates(a, [messageName("A", "notifycanary")]), .bumpRelist)
        f.closeSQLite()
        let bytes = storeBytes(f.directory)
        #expect(bytes.range(of: Data("owedcanary".utf8)) == nil)
        #expect(bytes.range(of: Data("notifycanary".utf8)) == nil)

        try f.reopenSQLite()
        #expect(try f.store.owed(a)?.ids == ["owedcanary"])
        #expect(try f.store.notifyRecords()[a]?.ids == ["notifycanary"])
        let version = try withRawConnection(f) { try $0.userVersion() }
        #expect(version == SQLiteAccountStore.migrations().count)
        #expect(version == 2)
    }
}
