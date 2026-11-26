import ChatModel
import Foundation
import Testing

@testable import ChatStore

private let timedOut = ExportError.io(code: Int(ETIMEDOUT))

extension ExportLockSuites {
    /// The lock other processes share. `OtherProcess` stands in for one.
    @Suite struct ExportCrossProcessTests {
        @Test func pruningHoldsTheSharedLockWhileItDecidesAndRemoves() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            try makeOld(a)
            let lock = f.temp.url.appendingPathComponent(ExportDirectory.lockName)
            let held = Locked<Bool?>(nil)
            var seams = ExportDirectory.Seams()
            seams.beforePruneRemoval = { _ in held.update { $0 = isLockedElsewhere(lock) } }

            try ExportDirectory(directory: f.directory, seams: seams).prune(changedBefore: cutoff())
            #expect(held.current == true)
            #expect(!exists(a))
        }

        @Test func handingOutAStoredCopyHoldsTheSharedLock() throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            _ = try exports.export(from: reader, filename: "a.bin")
            let lock = f.temp.url.appendingPathComponent(ExportDirectory.lockName)
            let held = Locked<Bool?>(nil)
            var seams = ExportDirectory.Seams()
            seams.beforeHandingOutStored = { _ in held.update { $0 = isLockedElsewhere(lock) } }

            _ = try ExportDirectory(directory: f.directory, seams: seams).export(
                from: try #require(try cache.open(mediaID: "media/x")), filename: "a.bin")
            #expect(held.current == true)
        }

        @Test func aTemporaryIsLockedAsSoonAsItExists() throws {
            let (f, _, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let locked = Locked<[Bool]>([])
            var seams = ExportDirectory.Seams()
            seams.afterFolderCreated = { folder in
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                let temporaries = names.filter(ExportDirectory.isTemporaryName)
                locked.update { $0 = temporaries.map { isLockedElsewhere(folder.appendingPathComponent($0)) } }
            }

            _ = try ExportDirectory(directory: f.directory, seams: seams).export(from: reader, filename: "a.bin")
            #expect(locked.current == [true])
        }

        @Test func withoutAUsableSharedLockNothingIsTouched() async throws {
            let (f, plain, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try plain.export(from: reader, filename: "a.bin")
            try makeOld(a)
            let elsewhere = f.temp.url.appendingPathComponent("elsewhere")
            try Data("not a lock".utf8).write(to: elsewhere)
            let lock = f.temp.url.appendingPathComponent(ExportDirectory.lockName)
            try FileManager.default.removeItem(at: lock)
            try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: elsewhere)
            let again = try #require(try cache.open(mediaID: "media/x"))
            let time = LockTime()
            var seams = ExportDirectory.Seams()
            time.install(in: &seams)
            let exports = ExportDirectory(directory: f.directory, seams: seams)

            // Each step fails on the lock file itself, at once: the step before it left the root's slot free.
            let export = try await onThread { try exports.export(from: again, filename: "b.bin") }.value
            #expect(throws: ExportError.io(code: Int(ELOOP))) { try export.get() }
            let prune = try await onThread { try exports.prune(changedBefore: cutoff()) }.value
            #expect(throws: ExportError.io(code: Int(ELOOP))) { try prune.get() }
            let wipe = try await onThread { try exports.wipe() }.value
            #expect(throws: ExportError.io(code: Int(ELOOP))) { try wipe.get() }
            #expect(time.waits.isEmpty)
            #expect(exists(a))
            #expect(!exists(a.deletingLastPathComponent().appendingPathComponent("b.bin")))
            #expect(try Data(contentsOf: elsewhere) == Data("not a lock".utf8))
        }

        @Test func theFirstExportIntoAFreshFolderTakesTheSharedLock() throws {
            let (f, _, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let root = f.temp.url.appendingPathComponent("fresh", isDirectory: true)
            let directory = AccountDirectory(root: root, account: AccountID())
            let lockExisted = Locked<Bool?>(nil)
            var seams = ExportDirectory.Seams()
            seams.afterFolderCreated = { _ in
                lockExisted.update { $0 = exists(root.appendingPathComponent(ExportDirectory.lockName)) }
            }

            let url = try ExportDirectory(directory: directory, seams: seams).export(from: reader, filename: "a.bin")
            #expect(lockExisted.current == true)
            #expect(exists(url))
        }

        @Test func anExportAndAWipeGiveUpWhileAnotherProcessKeepsTheSharedLock() async throws {
            let (f, plain, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try plain.export(from: reader, filename: "a.bin")
            let other = try OtherProcess(holdingTheLockOf: f.temp.url)
            defer { other.release() }
            let busy = Events<ExportDirectory.LockSite>()
            let time = LockTime()
            var seams = ExportDirectory.Seams()
            seams.lockWait = .milliseconds(200)
            seams.onLockBusy = { busy.record($0) }
            time.install(in: &seams)
            let impatient = ExportDirectory(directory: f.directory, seams: seams)
            let again = try #require(try cache.open(mediaID: "media/x"))

            let export = try await onThread { try impatient.export(from: again, filename: "b.bin") }.value
            #expect(throws: timedOut) { try export.get() }
            // Twenty pauses fill the wait; the lock is tried before each of them and once more after the last.
            #expect(time.waits == Array(repeating: ExportDirectory.lockRetry, count: 20))
            #expect(busy.all == Array(repeating: .claim, count: 21))
            let wipe = try await onThread { try impatient.wipe() }.value
            #expect(throws: timedOut) { try wipe.get() }
            #expect(time.waits == Array(repeating: ExportDirectory.lockRetry, count: 40))
            #expect(busy.count(of: .wipe) == 21)
            #expect(exists(a))
            #expect(!exists(a.deletingLastPathComponent().appendingPathComponent("b.bin")))
        }

        @Test func aWipeThatCantLookIntoItsRootFailsInsteadOfSkipping() throws {
            let (f, _, _, _) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let parent = f.temp.url.appendingPathComponent("unreadable", isDirectory: true)
            let root = parent.appendingPathComponent("Accounts", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let exports = ExportDirectory(directory: AccountDirectory(root: root, account: AccountID()))
            #expect(chmod(parent.path, 0) == 0)
            defer { chmod(parent.path, 0o700) }

            #expect(throws: ExportError.io(code: Int(EACCES))) { try exports.wipe() }
            #expect(throws: ExportError.io(code: Int(EACCES))) { try ExportDirectory.wipeAll(root: root) }
        }

        @Test func aSweepStopsAtTheFirstLockTimeout() async throws {
            let (f, plain, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            var copies = [try plain.export(from: reader, filename: "0.bin", placement: .unique)]
            for index in 1..<10 {
                let again = try #require(try cache.open(mediaID: "media/x"))
                copies.append(try plain.export(from: again, filename: "\(index).bin", placement: .unique))
            }
            for copy in copies { try makeOld(copy) }
            let other = try OtherProcess(holdingTheLockOf: f.temp.url)
            defer { other.release() }
            let attempts = Locked(0)
            let removals = Locked(0)
            let time = LockTime()
            var seams = ExportDirectory.Seams()
            seams.lockWait = .milliseconds(100)
            seams.onPruneEntryAttempt = { _ in attempts.update { $0 += 1 } }
            seams.beforePruneRemoval = { _ in removals.update { $0 += 1 } }
            time.install(in: &seams)
            let pruning = ExportDirectory(directory: f.directory, seams: seams)

            let pruned = try await onThread { try pruning.prune(changedBefore: cutoff()) }.value
            #expect(throws: timedOut) { try pruned.get() }
            // One wait, not one for each of the ten copies.
            #expect(attempts.current == 1)
            #expect(time.waits == Array(repeating: ExportDirectory.lockRetry, count: 10))
            #expect(removals.current == 0)
            #expect(copies.allSatisfy(exists))
        }

        /// While a step pauses between two tries at a shared lock another process holds, it is out of its root's
        /// line: the next step there gets as far as the shared lock at every try, and another root isn't held up.
        @Test func aStepWaitingForAnotherProcessHoldsUpNeitherItsRootsLineNorAnotherRoot() async throws {
            enum Step: Sendable, Equatable { case pausing, retry }
            let (f, _, _, waitingReader) = try exportFixture(pattern(10))
            let (g, _, _, otherReader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime((f, g)) {} }
            let (here, there) = (f.directory, g.directory)
            let other = try OtherProcess(holdingTheLockOf: f.temp.url)
            defer { other.release() }
            let steps = Events<Step>()
            defer { steps.close() }
            var parked = ExportDirectory.Seams.patient
            parked.wait = { _, _ in
                steps.record(.pausing)
                if !steps.block(until: { $0.contains(.retry) }) { parkForGood() }
            }
            let waiting = onThread { [parked] in
                try ExportDirectory(directory: here, seams: parked).export(from: waitingReader, filename: "a.bin")
            }
            try await steps.wait(for: .pausing)

            let otherRoot = LockTime()
            var unhindered = ExportDirectory.Seams()
            otherRoot.install(in: &unhindered)
            let elsewhere = try await onThread { [unhindered] in
                try ExportDirectory(directory: there, seams: unhindered).export(from: otherReader, filename: "b.bin")
            }.value
            #expect(exists(try elsewhere.get()))
            #expect(otherRoot.waits.isEmpty)

            let sameRoot = LockTime()
            var probing = ExportDirectory.Seams()
            probing.lockWait = .milliseconds(50)
            sameRoot.install(in: &probing)
            let probe = try await onThread { [probing] in try ExportDirectory(directory: here, seams: probing).wipe() }
                .value
            #expect(throws: timedOut) { try probe.get() }
            // Five pauses for the shared lock, never one long wait in line behind the export.
            try #require(sameRoot.waits == Array(repeating: ExportDirectory.lockRetry, count: 5))

            other.release()
            steps.record(.retry)
            #expect(exists(try await waiting.value.get()))
        }

        @Test func aWipeWaitsWhileAnotherProcessHoldsTheSharedLock() async throws {
            enum Step: Sendable, Equatable { case busy, pausing, retry, finished }
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            let directory = f.directory
            let other = try OtherProcess(holdingTheLockOf: f.temp.url)
            defer { other.release() }
            let steps = Events<Step>()
            defer { steps.close() }
            var seams = ExportDirectory.Seams.patient
            seams.onLockBusy = { if $0 == .wipe { steps.record(.busy) } }
            seams.wait = { _, _ in
                steps.record(.pausing)
                if !steps.block(until: { $0.contains(.retry) }) { parkForGood() }
            }
            let wipe = onThread { [seams] in
                defer { steps.record(.finished) }
                try ExportDirectory(directory: directory, seams: seams).wipe()
            }

            try await steps.wait { $0.contains(.pausing) || $0.contains(.finished) }
            // It found the lock held and is between two tries; what the other process is working on is untouched.
            #expect(steps.all == [.busy, .pausing])
            #expect(exists(a))
            other.release()
            steps.record(.retry)
            try await wipe.value.get()
            #expect(steps.all == [.busy, .pausing, .retry, .finished])
            #expect(!exists(a))
        }
    }
}

extension ExportLockSuites {
    /// The line this process's steps wait in at each root.
    @Suite struct ExportTurnTests {
        enum Step: Sendable, Equatable { case holding, resume }

        /// A sweep of `directory` that stops at the first old entry, holding the lock, until `.resume` is recorded.
        private func stalledSweep(
            of directory: AccountDirectory, _ steps: Events<Step>
        ) async throws -> Background<Result<Void, any Error>> {
            var stalling = ExportDirectory.Seams.patient
            stalling.beforePruneRemoval = { _ in
                steps.record(.holding)
                _ = steps.block { $0.contains(.resume) }
            }
            let sweep = onThread { [stalling] in
                try ExportDirectory(directory: directory, seams: stalling).prune(changedBefore: cutoff())
            }
            try await steps.wait(for: .holding)
            return sweep
        }

        @Test func aWipeGivesUpAtItsDeadlineBehindAStalledSweepAndLeavesTheLine() async throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            try makeOld(a)
            let directory = f.directory
            let steps = Events<Step>()
            defer { steps.close() }
            let sweep = try await stalledSweep(of: directory, steps)
            let busy = Events<ExportDirectory.LockSite>()
            let time = LockTime()
            var impatient = ExportDirectory.Seams()
            impatient.onLockBusy = { busy.record($0) }
            time.install(in: &impatient)

            // The sweep is stuck holding the root's slot; the wipe waits in line once, for all of its wait.
            let wipe = try await onThread { [impatient] in
                try ExportDirectory(directory: directory, seams: impatient).wipe()
            }.value
            #expect(throws: timedOut) { try wipe.get() }
            #expect(time.waits == [ExportDirectory.lockWait])
            #expect(busy.all == [.wipe])
            #expect(exists(a))

            steps.record(.resume)
            try await sweep.value.get()
            #expect(!exists(a))
            // Nobody is left in line, so the slot the sweep let go of is free: the next step never waits.
            let after = LockTime()
            var next = ExportDirectory.Seams()
            after.install(in: &next)
            try await onThread { [next] in try ExportDirectory(directory: directory, seams: next).wipe() }.value.get()
            #expect(after.waits.isEmpty)
        }

        @Test func nothingStartsOnceTheWaitHasRunOut() async throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            let directory = f.directory
            let admitted = Locked(0)
            let time = LockTime()
            var seams = ExportDirectory.Seams()
            // Both locks are free, but the turn that finds them so comes after the wait has run out.
            seams.lockWait = .zero
            seams.onLockAdmitted = { _ in admitted.update { $0 += 1 } }
            time.install(in: &seams)

            let late = try await onThread { [seams] in try ExportDirectory(directory: directory, seams: seams).wipe() }
                .value
            #expect(throws: timedOut) { try late.get() }
            #expect(admitted.current == 0)
            #expect(time.waits.isEmpty)
            #expect(exists(a))
            #expect(!isLockedElsewhere(f.temp.url.appendingPathComponent(ExportDirectory.lockName)))
            // The slot was let go of too: a step with time left gets it at once.
            var next = ExportDirectory.Seams()
            time.install(in: &next)
            try await onThread { [next] in try ExportDirectory(directory: directory, seams: next).wipe() }.value.get()
            #expect(time.waits.isEmpty)
            #expect(!exists(a))
        }

        @Test func aTurnThatComesAfterTheWaitRanOutStartsNothingAndGoesToTheNextInLine() async throws {
            enum Queued: Sendable, Equatable { case wipe, export }
            enum Admitted: Sendable, Equatable {
                case wipe
                case export(ExportDirectory.LockSite)
            }
            let (f, plain, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            try makeOld(try plain.export(from: reader, filename: "old.bin", placement: .unique))
            let kept = try plain.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "kept.bin")
            let again = try #require(try cache.open(mediaID: "media/x"))
            let directory = f.directory
            let steps = Events<Step>()
            let queued = Events<Queued>()
            let admitted = Events<Admitted>()
            defer { for log in [steps.close, queued.close, admitted.close] { log() } }
            let sweep = try await stalledSweep(of: directory, steps)

            // The wipe's time is the test's; it waits in line for as long as it takes to be handed the slot.
            let clock = Locked(Duration.zero)
            var late = ExportDirectory.Seams()
            late.now = { clock.current }
            late.wait = { turn, _ in turn.wait(upTo: ExportDirectory.Seams.patient.lockWait) }
            late.onLockBusy = { _ in queued.record(.wipe) }
            late.onLockAdmitted = { _ in admitted.record(.wipe) }
            let wipe = onThread { [late] in try ExportDirectory(directory: directory, seams: late).wipe() }
            try await queued.wait(for: .wipe)
            var patient = ExportDirectory.Seams.patient
            patient.onLockBusy = { if $0 == .claim { queued.record(.export) } }
            patient.onLockAdmitted = { admitted.record(.export($0)) }
            let export = onThread { [patient] in
                try ExportDirectory(directory: directory, seams: patient).export(from: again, filename: "new.bin")
            }
            try await queued.wait(for: .export)

            // The wipe's wait runs out while it is in line; only then does the sweep let go and hand it the slot.
            clock.update { $0 = ExportDirectory.lockWait }
            steps.record(.resume)

            let wiped = try await wipe.value
            #expect(throws: timedOut) { try wiped.get() }
            let url = try await export.value.get()
            try await sweep.value.get()
            #expect(admitted.all == [.export(.claim), .export(.publish)])
            #expect(exists(kept))
            #expect(exists(url))
        }

        @Test func oneWaitCoversTheTimeInLineAndTheTriesAtTheSharedLock() async throws {
            let (f, plain, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            try makeOld(try plain.export(from: reader, filename: "old.bin", placement: .unique))
            let (directory, root) = (f.directory, f.temp.url)
            let steps = Events<Step>()
            let queued = Events<ExportDirectory.LockSite>()
            defer { for log in [steps.close, queued.close] { log() } }
            let sweep = try await stalledSweep(of: directory, steps)

            let clock = Locked(Duration.zero)
            let waits = Events<Duration>()
            let other = Locked<OtherProcess?>(nil)
            defer { other.current?.release() }
            var seams = ExportDirectory.Seams()
            seams.now = { clock.current }
            seams.onLockBusy = { queued.record($0) }
            seams.wait = { turn, limit in
                waits.record(limit)
                guard clock.current == .zero else { return clock.update { $0 += limit } }
                // In line until it is handed the slot. Three of its five seconds have gone by then, and another
                // process has the shared lock the sweep let go of.
                turn.wait(upTo: ExportDirectory.Seams.patient.lockWait)
                clock.update { $0 = .seconds(3) }
                other.update { $0 = try? OtherProcess(holdingTheLockOf: root) }
            }
            let wipe = onThread { [seams] in try ExportDirectory(directory: directory, seams: seams).wipe() }
            try await queued.wait(for: .wipe)
            steps.record(.resume)

            let wiped = try await wipe.value
            #expect(throws: timedOut) { try wiped.get() }
            // The two seconds left are all the tries at the shared lock get: two hundred pauses.
            #expect(waits.all == [ExportDirectory.lockWait] + Array(repeating: ExportDirectory.lockRetry, count: 200))
            #expect(other.current != nil)
            try await sweep.value.get()
        }

        @Test func stepsWaitingAtARootTakeTheirTurnsInTheOrderTheyAsked() async throws {
            let (f, plain, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            try makeOld(try plain.export(from: reader, filename: "old.bin", placement: .unique))
            let directory = f.directory
            let steps = Events<Step>()
            let queued = Events<Int>()
            let admitted = Events<Int>()
            defer { for log in [steps.close, queued.close, admitted.close] { log() } }
            let sweep = try await stalledSweep(of: directory, steps)

            var wipes: [Background<Result<Void, any Error>>] = []
            for number in 1...3 {
                var seams = ExportDirectory.Seams.patient
                seams.onLockBusy = { _ in queued.record(number) }
                seams.onLockAdmitted = { _ in admitted.record(number) }
                wipes.append(onThread { [seams] in try ExportDirectory(directory: directory, seams: seams).wipe() })
                try await queued.wait(for: number)
            }
            steps.record(.resume)

            try await sweep.value.get()
            for wipe in wipes { try await wipe.value.get() }
            #expect(admitted.all == [1, 2, 3])
        }

        @Test func anExportQueuedBehindASweepIsAdmittedBeforeTheSweepsNextEntry() async throws {
            enum Turn: Sendable, Equatable {
                case sweep
                case export(ExportDirectory.LockSite)
            }
            enum Move: Sendable, Equatable { case sweepHolds, exportQueued, sweepAsksAgain, sweepAdmitted }
            let (f, plain, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            var copies = [try plain.export(from: reader, filename: "0.bin", placement: .unique)]
            for index in 1..<5 {
                let again = try #require(try cache.open(mediaID: "media/x"))
                copies.append(try plain.export(from: again, filename: "\(index).bin", placement: .unique))
            }
            for copy in copies { try makeOld(copy) }
            let again = try #require(try cache.open(mediaID: "media/x"))
            let directory = f.directory
            // Written by whoever holds the lock, so the order of the entries is the order the turns were taken in.
            let turns = Events<Turn>()
            let moves = Events<Move>()
            defer { for log in [turns.close, moves.close] { log() } }

            var sweeping = ExportDirectory.Seams.patient
            sweeping.onLockAdmitted = { _ in
                turns.record(.sweep)
                moves.record(.sweepAdmitted)
            }
            sweeping.onLockBusy = { _ in moves.record(.sweepAsksAgain) }
            // Holds the lock for its first entry until the export is in line behind it.
            sweeping.beforePruneRemoval = { _ in
                moves.record(.sweepHolds)
                _ = moves.block { $0.contains(.exportQueued) }
            }
            var contending = ExportDirectory.Seams.patient
            contending.onLockBusy = { if $0 == .claim { moves.record(.exportQueued) } }
            contending.onLockAdmitted = { turns.record(.export($0)) }
            // Woken, the export stands still until the sweep has asked for its next entry: found it ahead and
            // joined the line, or been let in first. The sweep gets every chance to overtake.
            contending.wait = { turn, limit in
                turn.wait(upTo: limit)
                _ = moves.block { $0.contains(.sweepAsksAgain) || $0.count(where: { $0 == .sweepAdmitted }) >= 2 }
            }

            let sweep = onThread { [sweeping] in
                try ExportDirectory(directory: directory, seams: sweeping).prune(changedBefore: cutoff())
            }
            try await moves.wait(for: .sweepHolds)
            let export = onThread { [contending] in
                try ExportDirectory(directory: directory, seams: contending).export(from: again, filename: "a.bin")
            }

            let url = try await export.value.get()
            try await sweep.value.get()
            #expect(Array(turns.all.prefix(2)) == [.sweep, .export(.claim)])
            #expect(turns.all.filter { $0 != .sweep } == [.export(.claim), .export(.publish)])
            #expect(turns.count(of: .sweep) == copies.count)
            #expect(exists(url))
            #expect(!copies.contains(where: exists))
        }

        @Test func aFailedExportReturnsWithoutWaitingForASweepAndItsTemporaryGoesLater() async throws {
            let (f, plain, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            // Something old for the sweep to stop at.
            try makeOld(try plain.export(from: reader, filename: "old.bin", placement: .unique))
            let directory = f.directory
            let steps = Events<Step>()
            defer { steps.close() }
            var stalling = ExportDirectory.Seams.patient
            stalling.beforePruneRemoval = { _ in
                steps.record(.holding)
                _ = steps.block { $0.contains(.resume) }
            }
            let stalled = ExportDirectory(directory: directory, seams: stalling)
            let sweep = Locked<Background<Result<Void, any Error>>?>(nil)
            let staged = Locked<URL?>(nil)
            let busy = Events<ExportDirectory.LockSite>()
            let time = LockTime()
            var failing = ExportDirectory.Seams()
            failing.onLockBusy = { busy.record($0) }
            // The copy is written; a sweep starts and stalls holding the lock before the export can publish it.
            failing.beforeQuarantine = { url in
                staged.update { $0 = url }
                sweep.update { $0 = onThread { try stalled.prune(changedBefore: cutoff()) } }
                _ = steps.block { $0.contains(.holding) }
            }
            time.install(in: &failing)
            let again = try #require(try cache.open(mediaID: "media/x"))

            let export = try await onThread { [failing] in
                try ExportDirectory(directory: directory, seams: failing).export(from: again, filename: "a.bin")
            }.value
            // The copy can't be published nor its temporary removed: each step waits in line once, for all of its
            // wait, and the export gives up rather than wait for the sweep.
            #expect(throws: timedOut) { try export.get() }
            #expect(time.waits == [ExportDirectory.lockWait, ExportDirectory.lockWait])
            #expect(busy.all == [.publish, .cleanup])
            let temporary = try #require(staged.current)
            #expect(exists(temporary))
            steps.record(.resume)
            try await #require(sweep.current).value.get()

            // The export let go of its temporary, so the next cleanup takes it.
            try plain.prune(changedBefore: cutoff())
            #expect(!exists(temporary))
        }

        @Test func workAtAnotherRootDoesntWaitForARootWhoseSlotIsHeld() async throws {
            let (f, plain, _, reader) = try exportFixture(pattern(10))
            let (g, _, _, otherReader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime((f, g)) {} }
            try makeOld(try plain.export(from: reader, filename: "old.bin", placement: .unique))
            let (here, there) = (f.directory, g.directory)
            let steps = Events<Step>()
            defer { steps.close() }
            let sweep = try await stalledSweep(of: here, steps)
            let time = LockTime()
            var seams = ExportDirectory.Seams()
            time.install(in: &seams)

            let url = try await onThread { [seams] in
                try ExportDirectory(directory: there, seams: seams).export(from: otherReader, filename: "b.bin")
            }.value
            #expect(exists(try url.get()))
            #expect(time.waits.isEmpty)
            steps.record(.resume)
            try await sweep.value.get()
        }

        @Test func aStepAskingForTheLockItsOwnThreadHoldsGivesUpAtItsDeadline() async throws {
            let (f, plain, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try plain.export(from: reader, filename: "a.bin")
            let again = try #require(try cache.open(mediaID: "media/x"))
            let outer = LockTime()
            var holding = ExportDirectory.Seams()
            outer.install(in: &holding)
            let inner = LockTime()
            var asking = ExportDirectory.Seams()
            inner.install(in: &asking)
            let nested = ExportDirectory(directory: f.directory, seams: asking)
            let exports = ExportDirectory(directory: f.directory, seams: holding)
            let asked = Locked<Result<Void, ExportError>?>(nil)

            // Asked for from inside the claim, where the export holds the lock, as a session's callback might.
            let url = try await onThread {
                try exports.export(from: again, filename: "b.bin") { stage in
                    if stage == .claiming {
                        let wiped = Result { () throws(ExportError) in try nested.wipe() }
                        asked.update { $0 = wiped }
                    }
                    return true
                }
            }.value.get()
            #expect(throws: timedOut) { try #require(asked.current).get() }
            #expect(inner.waits == [ExportDirectory.lockWait])
            // The export it interrupted carries on, and finds the lock free for publishing.
            #expect(outer.waits.isEmpty)
            #expect(exists(a))
            #expect(exists(url))
        }

        @Test func aStepThatFailsLetsGoOfTheLock() async throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            #expect(throws: ExportError.withdrawn) {
                try exports.export(from: reader, filename: "a.bin") { $0 != .claiming }
            }
            #expect(!isLockedElsewhere(f.temp.url.appendingPathComponent(ExportDirectory.lockName)))
            let time = LockTime()
            var seams = ExportDirectory.Seams()
            time.install(in: &seams)
            let wiping = ExportDirectory(directory: f.directory, seams: seams)
            try await onThread { try wiping.wipe() }.value.get()
            #expect(time.waits.isEmpty)
        }
    }
}
