import ChatModel
import Foundation
import Synchronization
import Testing

@testable import ChatStore

/// A value several threads write, read once they're done.
final class Locked<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ value: Value) { self.value = Mutex(value) }
    func update(_ body: (inout Value) -> Void) { value.withLock { body(&$0) } }
    var current: Value { value.withLock { $0 } }
}

/// Sets the modification time of `url` itself (a symlink's own, never its target's) `seconds` in the past.
private func backdate(_ url: URL, by seconds: TimeInterval) throws {
    let then = Int(Date().addingTimeInterval(-seconds).timeIntervalSince1970)
    var times = [timespec(tv_sec: then, tv_nsec: 0), timespec(tv_sec: then, tv_nsec: 0)]
    guard utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// A copy last touched two days ago: its file first, then its folder, since writing the file bumps the folder.
private func makeOld(_ url: URL) throws {
    try backdate(url, by: 2 * 86_400)
    try backdate(url.deletingLastPathComponent(), by: 2 * 86_400)
}

private func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

private func cutoff() -> Date { Date().addingTimeInterval(-ExportDirectory.maxAge) }

/// What seams on other threads report, in order. A test waits for the event it needs; the bound only guards
/// against a hang.
final class Events<Event: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var log: [Event] = []

    func record(_ event: Event) {
        condition.lock()
        log.append(event)
        condition.broadcast()
        condition.unlock()
    }

    var all: [Event] {
        condition.lock()
        defer { condition.unlock() }
        return log
    }

    func wait(until done: ([Event]) -> Bool) -> Bool {
        let limit = Date().addingTimeInterval(10)
        condition.lock()
        defer { condition.unlock() }
        while !done(log) {
            guard condition.wait(until: limit) else { return done(log) }
        }
        return true
    }
}

extension Events where Event: Equatable {
    func wait(for event: Event) -> Bool { wait { $0.contains(event) } }
}

extension ExportLockSuites {
    @Suite struct ExportPruneTests {
        @Test func removesCopiesUnchangedForADayAndKeepsNewerOnes() throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let old = try exports.export(from: reader, filename: "old.bin")
            let fresh = try exports.export(
                from: try #require(try cache.open(mediaID: "media/x")), filename: "new.bin", placement: .unique)
            try makeOld(old)

            try exports.prune(changedBefore: cutoff())
            #expect(!exists(old.deletingLastPathComponent()))
            #expect(exists(fresh))
            #expect(exists(f.directory.exportsURL))
        }

        @Test func aCopyAnotherAppChangedRecentlyStays() throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            // Saved into in place: the file is new, its folder old.
            let edited = try exports.export(from: reader, filename: "edited.bin")
            try backdate(edited.deletingLastPathComponent(), by: 2 * 86_400)
            // Saved by replacing the file: the folder is new, the file it holds old.
            let replaced = try exports.export(
                from: try #require(try cache.open(mediaID: "media/x")), filename: "b.bin", placement: .unique)
            try backdate(replaced, by: 2 * 86_400)

            try exports.prune(changedBefore: cutoff())
            #expect(exists(edited))
            #expect(exists(replaced))
        }

        @Test func pruningOneAccountLeavesOthersAlone() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            let other = AccountDirectory(root: f.temp.url, account: AccountID())
            try other.createExports()
            let otherFolder = other.exportsURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: false)
            let otherFile = otherFolder.appendingPathComponent("a.bin")
            try Data("x".utf8).write(to: otherFile)
            try makeOld(otherFile)
            let mine = try exports.export(from: reader, filename: "a.bin")
            try makeOld(mine)

            try exports.prune(changedBefore: cutoff())
            #expect(!exists(mine))
            #expect(exists(otherFile))
        }

        @Test func pruneAllCoversEveryAccountAndStrayEntries() throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(10))
            let old = try exports.export(from: reader, filename: "old.bin")
            try makeOld(old)
            let fresh = try exports.export(
                from: try #require(try cache.open(mediaID: "media/x")), filename: "new.bin", placement: .unique)
            // An account that is no longer signed in still has an old copy.
            let gone = AccountDirectory(root: f.temp.url, account: AccountID())
            try gone.createExports()
            let goneFolder = gone.exportsURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: goneFolder, withIntermediateDirectories: false)
            let goneFile = goneFolder.appendingPathComponent("a.bin")
            try Data("x".utf8).write(to: goneFile)
            try makeOld(goneFile)
            let exportsRoot = f.temp.url.appendingPathComponent("exports", isDirectory: true)
            let oldStray = exportsRoot.appendingPathComponent("old-stray")
            let newStray = exportsRoot.appendingPathComponent("new-stray")
            try Data("x".utf8).write(to: oldStray)
            try Data("x".utf8).write(to: newStray)
            try backdate(oldStray, by: 2 * 86_400)

            try ExportDirectory.pruneAll(root: f.temp.url, changedBefore: cutoff())
            #expect(!exists(old.deletingLastPathComponent()))
            #expect(!exists(goneFolder))
            #expect(!exists(oldStray))
            #expect(exists(fresh))
            #expect(exists(newStray))
            #expect(exists(f.directory.storeURL))
        }

        @Test func anAttachmentOpenedAgainWhilePruningIsNotRemovedWithItsOldFolder() throws {
            let data = pattern(1000)
            let (f, plain, cache, reader) = try exportFixture(data)
            defer { withExtendedLifetime(f) {} }
            let old = try plain.export(from: reader, filename: "photo.webp")
            try makeOld(old)
            let again = try #require(try cache.open(mediaID: "media/x"))
            let reopened = Locked<URL?>(nil)
            let busy = Events<ExportDirectory.LockSite>()
            var contending = ExportDirectory.Seams()
            contending.onLockBusy = { busy.record($0) }
            let contender = ExportDirectory(directory: f.directory, seams: contending)
            let export = DispatchGroup()
            let blocked = Locked<Bool?>(nil)
            var seams = ExportDirectory.Seams()
            seams.beforePruneRemoval = { _ in
                // The folder has been judged old, and the attachment is opened again right now, on another thread.
                export.enter()
                Thread.detachNewThread {
                    let url = try? contender.export(from: again, filename: "photo.webp")
                    reopened.update { $0 = url }
                    export.leave()
                }
                blocked.update { $0 = busy.wait(for: .claim) }
            }

            try ExportDirectory(directory: f.directory, seams: seams).prune(changedBefore: cutoff())
            #expect(blocked.current == true)
            #expect(export.wait(timeout: .now() + 10) == .success)
            let url = try #require(reopened.current)
            #expect(try Data(contentsOf: url) == data)
        }

        @Test func openingACopyAgainKeepsItForAnotherDay() throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            try makeOld(a)
            let b = try exports.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "a.bin")
            #expect(b == a)

            try exports.prune(changedBefore: cutoff())
            #expect(exists(a))
        }

        @Test func aCopyThatCantBeMarkedAsJustUsedIsNotHandedOut() throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            try makeOld(a)
            var seams = ExportDirectory.Seams()
            seams.markUsed = { _ in EIO }
            let again = try #require(try cache.open(mediaID: "media/x"))

            // Handed out still looking old, the next sweep would take it from under the app opening it.
            #expect(throws: ExportError.io(code: Int(EIO))) {
                try ExportDirectory(directory: f.directory, seams: seams).export(from: again, filename: "a.bin")
            }
            #expect(exists(a))
        }

        @Test func abandonedTemporariesGoWhenTheAttachmentIsOpenedAgain() throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            let abandoned = a.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
            try Data("half of it".utf8).write(to: abandoned)

            _ = try exports.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "a.bin")
            #expect(!exists(abandoned))
            #expect(exists(a))
        }

        @Test func pruningRemovesAbandonedTemporariesButNotOneBeingWritten() throws {
            let (f, _, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let seen = Locked<(abandoned: Bool, writing: Bool)?>(nil)
            let directory = f.directory
            var seams = ExportDirectory.Seams()
            seams.beforeQuarantine = { staged in
                let abandoned = staged.deletingLastPathComponent().appendingPathComponent(
                    ".\(UUID().uuidString).partial")
                try? Data("left by a crash".utf8).write(to: abandoned)
                // The folder is fresh, so it stays, but only the temporary still being written survives.
                try? ExportDirectory(directory: directory).prune(changedBefore: cutoff())
                seen.update { $0 = (exists(abandoned), exists(staged)) }
            }

            let url = try ExportDirectory(directory: f.directory, seams: seams).export(from: reader, filename: "a.bin")
            #expect(seen.current?.abandoned == false)
            #expect(seen.current?.writing == true)
            #expect(exists(url))
        }

        @Test func onlyThisAppsAbandonedTemporaryFilesGo() throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            let folder = a.deletingLastPathComponent()
            let ours = folder.appendingPathComponent(".\(UUID().uuidString).partial")
            let editorFile = folder.appendingPathComponent(".notes.partial")
            let editorFolder = folder.appendingPathComponent(".autosave.partial", isDirectory: true)
            let lookalikeFolder = folder.appendingPathComponent(".\(UUID().uuidString).partial", isDirectory: true)
            for file in [ours, editorFile] { try Data("x".utf8).write(to: file) }
            for directory in [editorFolder, lookalikeFolder] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try Data("x".utf8).write(to: directory.appendingPathComponent("inside"))
            }

            _ = try exports.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "a.bin")
            try exports.prune(changedBefore: cutoff())
            #expect(!exists(ours))
            #expect(exists(editorFile))
            #expect(exists(editorFolder.appendingPathComponent("inside")))
            #expect(exists(lookalikeFolder.appendingPathComponent("inside")))
        }

        @Test func aFolderWithAnExportInProgressIsNotPruned() throws {
            let (f, _, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let directory = f.directory
            let survived = Locked<Bool?>(nil)
            var seams = ExportDirectory.Seams()
            seams.beforeQuarantine = { staged in
                // This export has stalled for two days before finishing its copy.
                try? backdate(staged, by: 2 * 86_400)
                try? backdate(staged.deletingLastPathComponent(), by: 2 * 86_400)
                try? ExportDirectory(directory: directory).prune(changedBefore: cutoff())
                survived.update { $0 = exists(staged) }
            }

            let url = try ExportDirectory(directory: f.directory, seams: seams).export(from: reader, filename: "a.bin")
            #expect(survived.current == true)
            #expect(exists(url))
        }

        @Test func anotherProcesssTemporaryStaysWhileItHoldsItsLock() throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            let folder = a.deletingLastPathComponent()
            let theirs = folder.appendingPathComponent(".\(UUID().uuidString).partial")
            try Data("being written elsewhere".utf8).write(to: theirs)
            // Held the way another process's export holds its temporary.
            let holder = open(theirs.path, O_RDONLY)
            #expect(flock(holder, LOCK_EX) == 0)

            _ = try exports.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "a.bin")
            #expect(exists(theirs))
            // Even when everything in the folder looks a day old, the folder stays while that export runs.
            try backdate(theirs, by: 2 * 86_400)
            try makeOld(a)
            try exports.prune(changedBefore: cutoff())
            #expect(exists(theirs))
            #expect(exists(a))

            Darwin.close(holder)
            _ = try exports.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "a.bin")
            #expect(!exists(theirs))
        }

        @Test func pruneReportsEntriesItCannotRemove() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let url = try exports.export(from: reader, filename: "a.bin")
            let folder = url.deletingLastPathComponent()
            try makeOld(url)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

            #expect(throws: ExportError.wipeIncomplete(failed: 1)) { try exports.prune(changedBefore: cutoff()) }
            #expect(throws: ExportError.wipeIncomplete(failed: 1)) {
                try ExportDirectory.pruneAll(root: f.temp.url, changedBefore: cutoff())
            }
        }

        @Test func pruningWhenNothingExistsIsANoOp() throws {
            let f = try Fixture(.sqlite)
            try ExportDirectory(directory: f.directory).prune(changedBefore: cutoff())
            try ExportDirectory.pruneAll(root: f.temp.url, changedBefore: cutoff())
            try ExportDirectory.pruneAll(root: f.temp.url.appendingPathComponent("missing"), changedBefore: cutoff())
        }
    }
}

extension ExportLockSuites {
    @Suite struct ExportPruneSymlinkTests {
        enum Prune: String, CaseIterable, Sendable, CustomTestStringConvertible {
            case account
            case all

            var testDescription: String { rawValue }

            func run(_ f: Fixture) throws {
                switch self {
                case .account: try ExportDirectory(directory: f.directory).prune(changedBefore: cutoff())
                case .all: try ExportDirectory.pruneAll(root: f.temp.url, changedBefore: cutoff())
                }
            }
        }

        /// A directory outside the tree with a file in it, both old, so only following a link could remove them.
        private func victim(in f: Fixture) throws -> (dir: URL, file: URL) {
            let dir = try makeVictim(in: f)
            let file = dir.appendingPathComponent("keep.txt")
            try Data("precious".utf8).write(to: file)
            try backdate(file, by: 2 * 86_400)
            try backdate(dir, by: 2 * 86_400)
            return (dir, file)
        }

        @Test(arguments: Prune.allCases) func aSymlinkedExportsRootIsNotFollowed(_ prune: Prune) throws {
            let (f, _, _, _) = try exportFixture(pattern(10))
            let v = try victim(in: f)
            let root = f.temp.url.appendingPathComponent("exports")
            try f.directory.createExports()
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: v.dir)

            try prune.run(f)
            #expect(try Data(contentsOf: v.file) == Data("precious".utf8))
        }

        @Test(arguments: Prune.allCases) func aSymlinkedAccountFolderIsNotFollowed(_ prune: Prune) throws {
            let (f, _, _, _) = try exportFixture(pattern(10))
            let v = try victim(in: f)
            try f.directory.createExports()
            try FileManager.default.removeItem(at: f.directory.exportsURL)
            try FileManager.default.createSymbolicLink(at: f.directory.exportsURL, withDestinationURL: v.dir)
            try backdate(f.directory.exportsURL, by: 2 * 86_400)

            try prune.run(f)
            #expect(try Data(contentsOf: v.file) == Data("precious".utf8))
            // Pruning one account can't open it and leaves it for the wipe; pruning all treats it as an old stray
            // and unlinks the link itself.
            #expect(exists(f.directory.exportsURL) == (prune == .account))
        }

        @Test(arguments: Prune.allCases) func oldSymlinksAreUnlinkedNotFollowed(_ prune: Prune) throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            let v = try victim(in: f)
            let url = try exports.export(from: reader, filename: "a.bin")
            let folder = url.deletingLastPathComponent()
            let inside = folder.appendingPathComponent("dirlink")
            try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: v.dir)
            try backdate(inside, by: 2 * 86_400)
            try makeOld(url)
            let top = f.directory.exportsURL.appendingPathComponent("toplink")
            try FileManager.default.createSymbolicLink(at: top, withDestinationURL: v.dir)
            try backdate(top, by: 2 * 86_400)

            try prune.run(f)
            #expect(try Data(contentsOf: v.file) == Data("precious".utf8))
            #expect(!exists(folder))
            #expect(!exists(top))
        }

        @Test(arguments: Prune.allCases) func aFreshSymlinkStays(_ prune: Prune) throws {
            let (f, _, _, _) = try exportFixture(pattern(10))
            let v = try victim(in: f)
            try f.directory.createExports()
            let link = f.directory.exportsURL.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: v.dir)

            try prune.run(f)
            #expect(exists(link))
            #expect(try Data(contentsOf: v.file) == Data("precious".utf8))
        }
    }
}

extension ExportLockSuites {
    /// Another process is simulated with a second descriptor: flock locks belong to the open file, so they conflict
    /// within one process the way they do between two.
    @Suite struct ExportCrossProcessTests {
        private func heldElsewhere(_ url: URL) -> Bool {
            let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            return flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
        }

        @Test func pruningHoldsTheSharedLockWhileItDecidesAndRemoves() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            try makeOld(a)
            let lock = f.temp.url.appendingPathComponent(ExportDirectory.lockName)
            let held = Locked<Bool?>(nil)
            var seams = ExportDirectory.Seams()
            seams.beforePruneRemoval = { _ in held.update { $0 = self.heldElsewhere(lock) } }

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
            seams.beforeHandingOutStored = { _ in held.update { $0 = self.heldElsewhere(lock) } }

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
                locked.update { $0 = temporaries.map { self.heldElsewhere(folder.appendingPathComponent($0)) } }
            }

            _ = try ExportDirectory(directory: f.directory, seams: seams).export(from: reader, filename: "a.bin")
            #expect(locked.current == [true])
        }

        @Test func withoutAUsableSharedLockNothingIsTouched() throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            try makeOld(a)
            let elsewhere = f.temp.url.appendingPathComponent("elsewhere")
            try Data("not a lock".utf8).write(to: elsewhere)
            let lock = f.temp.url.appendingPathComponent(ExportDirectory.lockName)
            try FileManager.default.removeItem(at: lock)
            try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: elsewhere)
            let again = try #require(try cache.open(mediaID: "media/x"))

            #expect(throws: ExportError.io(code: Int(ELOOP))) { try exports.export(from: again, filename: "b.bin") }
            #expect(throws: ExportError.self) { try exports.prune(changedBefore: cutoff()) }
            #expect(throws: ExportError.self) { try exports.wipe() }
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

        @Test func anExportAndAWipeGiveUpWhileAnotherProcessKeepsTheSharedLock() throws {
            let (f, plain, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try plain.export(from: reader, filename: "a.bin")
            let holder = open(f.temp.url.appendingPathComponent(ExportDirectory.lockName).path, O_RDWR | O_CREAT, 0o600)
            defer { close(holder) }
            #expect(flock(holder, LOCK_EX) == 0)
            let busy = Events<ExportDirectory.LockSite>()
            var seams = ExportDirectory.Seams()
            seams.lockWait = .milliseconds(200)
            seams.onLockBusy = { busy.record($0) }
            let impatient = ExportDirectory(directory: f.directory, seams: seams)
            let again = try #require(try cache.open(mediaID: "media/x"))
            let export = Locked<Result<URL, ExportError>?>(nil)
            let wipe = Locked<Result<Void, ExportError>?>(nil)
            let done = DispatchGroup()
            done.enter()
            // On a thread of its own, so a wait that never gives up fails the test instead of hanging it.
            Thread.detachNewThread {
                let exported = Result { () throws(ExportError) in try impatient.export(from: again, filename: "b.bin") }
                export.update { $0 = exported }
                let wiped = Result { () throws(ExportError) in try impatient.wipe() }
                wipe.update { $0 = wiped }
                done.leave()
            }

            try #require(done.wait(timeout: .now() + 10) == .success)
            #expect(throws: ExportError.io(code: Int(ETIMEDOUT))) { try export.current?.get() }
            #expect(throws: ExportError.io(code: Int(ETIMEDOUT))) { try wipe.current?.get() }
            #expect(busy.all.contains(.claim))
            #expect(busy.all.contains(.wipe))
            #expect(exists(a))
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

        @Test func aSweepStopsAtTheFirstLockTimeout() throws {
            let (f, plain, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            var copies = [try plain.export(from: reader, filename: "0.bin", placement: .unique)]
            for index in 1..<10 {
                let again = try #require(try cache.open(mediaID: "media/x"))
                copies.append(try plain.export(from: again, filename: "\(index).bin", placement: .unique))
            }
            for copy in copies { try makeOld(copy) }
            let holder = open(f.temp.url.appendingPathComponent(ExportDirectory.lockName).path, O_RDWR | O_CREAT, 0o600)
            defer { close(holder) }
            #expect(flock(holder, LOCK_EX) == 0)
            let attempts = Locked(0)
            let removals = Locked(0)
            var seams = ExportDirectory.Seams()
            seams.lockWait = .milliseconds(100)
            seams.onPruneEntryAttempt = { _ in attempts.update { $0 += 1 } }
            seams.beforePruneRemoval = { _ in removals.update { $0 += 1 } }

            #expect(throws: ExportError.io(code: Int(ETIMEDOUT))) {
                try ExportDirectory(directory: f.directory, seams: seams).prune(changedBefore: cutoff())
            }
            // One wait, not one for each of the ten copies.
            #expect(attempts.current == 1)
            #expect(removals.current == 0)
            #expect(copies.allSatisfy(exists))
        }

        @Test func waitingForTheSharedLockDoesntHoldUpOtherWork() throws {
            let (f, _, _, waitingReader) = try exportFixture(pattern(10))
            let (g, other, _, otherReader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime((f, g)) {} }
            let holder = open(f.temp.url.appendingPathComponent(ExportDirectory.lockName).path, O_RDWR | O_CREAT, 0o600)
            #expect(flock(holder, LOCK_EX) == 0)
            let busy = Events<ExportDirectory.LockSite>()
            var seams = ExportDirectory.Seams()
            seams.lockWait = .seconds(5)
            seams.onLockBusy = { busy.record($0) }
            let waiting = ExportDirectory(directory: f.directory, seams: seams)
            let outcome = Locked<Bool?>(nil)
            let done = DispatchGroup()
            done.enter()
            Thread.detachNewThread {
                let url = try? waiting.export(from: waitingReader, filename: "a.bin")
                outcome.update { $0 = url != nil }
                done.leave()
            }
            // Once that export has found the shared lock held, another account's tree (a separate root here) gets its
            // copy while it's still waiting: had the wait held the process-wide lock, this would only finish once the
            // wait gave up.
            #expect(busy.wait(for: .claim))
            _ = try other.export(from: otherReader, filename: "b.bin")
            #expect(outcome.current == nil)
            close(holder)
            done.wait()
            #expect(outcome.current == true)
        }

        @Test func aWipeGivesUpOnTimeWhileThisProcessIsBusyWithTheTree() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            try makeOld(a)
            let directory = f.directory
            let inside = DispatchSemaphore(value: 0)
            let resume = DispatchSemaphore(value: 0)
            var pausing = ExportDirectory.Seams()
            pausing.beforePruneRemoval = { _ in
                inside.signal()
                _ = resume.wait(timeout: .now() + 10)
            }
            let pruned = DispatchGroup()
            pruned.enter()
            Thread.detachNewThread {
                try? ExportDirectory(directory: directory, seams: pausing).prune(changedBefore: cutoff())
                pruned.leave()
            }
            #expect(inside.wait(timeout: .now() + 10) == .success)
            let busy = Events<ExportDirectory.LockSite>()
            var impatient = ExportDirectory.Seams()
            impatient.lockWait = .milliseconds(200)
            impatient.onLockBusy = { busy.record($0) }

            // The sweep is stuck holding the lock; the wipe gives up on its own deadline instead of waiting it out.
            #expect(throws: ExportError.io(code: Int(ETIMEDOUT))) {
                try ExportDirectory(directory: directory, seams: impatient).wipe()
            }
            #expect(busy.all.contains(.wipe))
            #expect(exists(a))
            resume.signal()
            pruned.wait()
        }

        @Test func nothingStartsOnceTheWaitHasRunOut() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            var seams = ExportDirectory.Seams()
            // Both locks are free, but the attempt that finds them so comes after the wait has run out, as a retry can.
            seams.lockWait = .zero

            #expect(throws: ExportError.io(code: Int(ETIMEDOUT))) {
                try ExportDirectory(directory: f.directory, seams: seams).wipe()
            }
            #expect(exists(a))
        }

        @Test func aFailedExportReturnsWithoutWaitingForASweepAndItsTemporaryGoesLater() throws {
            let (f, plain, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            // Something old for the sweep to stop at.
            try makeOld(try plain.export(from: reader, filename: "old.bin", placement: .unique))
            let directory = f.directory
            let inside = DispatchSemaphore(value: 0)
            let resume = DispatchSemaphore(value: 0)
            let resumed = Locked(false)
            var pausing = ExportDirectory.Seams()
            pausing.beforePruneRemoval = { _ in
                inside.signal()
                _ = resume.wait(timeout: .now() + 60)
                resumed.update { $0 = true }
            }
            let pausingSeams = pausing
            let pruned = DispatchGroup()
            let staged = Locked<URL?>(nil)
            let busy = Events<ExportDirectory.LockSite>()
            var failing = ExportDirectory.Seams()
            failing.lockWait = .milliseconds(200)
            failing.onLockBusy = { busy.record($0) }
            failing.beforeQuarantine = { url in
                staged.update { $0 = url }
                pruned.enter()
                Thread.detachNewThread {
                    try? ExportDirectory(directory: directory, seams: pausingSeams).prune(changedBefore: cutoff())
                    pruned.leave()
                }
                _ = inside.wait(timeout: .now() + 10)
            }
            let again = try #require(try cache.open(mediaID: "media/x"))

            // The sweep holds the lock throughout, so the copy can't be published nor its temporary removed; the export
            // gives up on its own deadline rather than waiting for the sweep.
            #expect(throws: ExportError.io(code: Int(ETIMEDOUT))) {
                try ExportDirectory(directory: directory, seams: failing).export(from: again, filename: "a.bin")
            }
            #expect(resumed.current == false)
            #expect(busy.all.contains(.publish))
            #expect(busy.all.contains(.cleanup))
            let temporary = try #require(staged.current)
            #expect(exists(temporary))
            resume.signal()
            pruned.wait()

            // The export let go of its temporary, so the next cleanup takes it.
            try plain.prune(changedBefore: cutoff())
            #expect(!exists(temporary))
        }

        /// Relies on production's pause between entries outlasting the 10 ms lock-retry poll: whether the waiting
        /// export takes its turn within one pause comes down to those two durations, not to this test.
        @Test func anExportGetsItsTurnDuringALongSweep() throws {
            enum Event: Sendable, Equatable { case removing, exported, swept }
            enum Contender: Sendable, Equatable { case waiting, writing, finished }
            let (f, plain, cache, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            var copies = [try plain.export(from: reader, filename: "0.bin", placement: .unique)]
            for index in 1..<30 {
                let again = try #require(try cache.open(mediaID: "media/x"))
                copies.append(try plain.export(from: again, filename: "\(index).bin", placement: .unique))
            }
            for copy in copies { try makeOld(copy) }
            let directory = f.directory
            let order = Events<Event>()
            let contender = Events<Contender>()
            let yields = Locked(0)
            let stalled = Locked(false)
            var sweeping = ExportDirectory.Seams()
            // Each entry is removed only once the export is queued for the lock (or done), so every pause finds it
            // waiting. Blocking here holds the lock, so it never hands the export a turn itself.
            sweeping.beforePruneRemoval = { _ in
                order.record(.removing)
                let queued = contender.wait { $0.last == .waiting || $0.last == .finished }
                if !queued { stalled.update { $0 = true } }
            }
            sweeping.onYieldToWaiters = { yields.update { $0 += 1 } }
            let pruned = DispatchGroup()
            pruned.enter()
            Thread.detachNewThread {
                try? ExportDirectory(directory: directory, seams: sweeping).prune(changedBefore: cutoff())
                order.record(.swept)
                pruned.leave()
            }
            #expect(order.wait(for: .removing))
            var contending = ExportDirectory.Seams()
            contending.lockWait = .seconds(60)
            contending.onLockBusy = { _ in contender.record(.waiting) }
            let again = try #require(try cache.open(mediaID: "media/x"))

            let url = try ExportDirectory(directory: directory, seams: contending).export(
                from: again, filename: "a.bin"
            ) {
                stage in
                if stage == .claiming { contender.record(.writing) }
                return true
            }
            contender.record(.finished)
            order.record(.exported)
            #expect(pruned.wait(timeout: .now() + 60) == .success)
            #expect(exists(url))
            #expect(stalled.current == false)
            #expect(yields.current > 0)
            #expect(order.all.filter { $0 != .removing } == [.exported, .swept])
        }

        @Test func aWipeWaitsWhileAnotherProcessHoldsTheSharedLock() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: reader, filename: "a.bin")
            let holder = open(f.temp.url.appendingPathComponent(ExportDirectory.lockName).path, O_RDWR | O_CREAT, 0o600)
            #expect(flock(holder, LOCK_EX) == 0)
            let busy = Events<ExportDirectory.LockSite>()
            var seams = ExportDirectory.Seams()
            seams.onLockBusy = { busy.record($0) }
            let waiting = ExportDirectory(directory: f.directory, seams: seams)
            let wiped = DispatchGroup()
            wiped.enter()
            Thread.detachNewThread {
                try? waiting.wipe()
                wiped.leave()
            }

            #expect(busy.wait(for: .wipe))
            #expect(wiped.wait(timeout: .now()) == .timedOut)
            #expect(exists(a))
            close(holder)
            #expect(wiped.wait(timeout: .now() + 10) == .success)
            #expect(!exists(a))
        }
    }
}
