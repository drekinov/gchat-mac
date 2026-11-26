import ChatModel
import Foundation
import Testing

@testable import ChatStore

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

        @Test func anAttachmentOpenedAgainWhilePruningIsNotRemovedWithItsOldFolder() async throws {
            enum Step: Sendable, Equatable { case judgedOld, reopening }
            let data = pattern(1000)
            let (f, plain, cache, reader) = try exportFixture(data)
            defer { withExtendedLifetime(f) {} }
            let old = try plain.export(from: reader, filename: "photo.webp")
            try makeOld(old)
            let again = try #require(try cache.open(mediaID: "media/x"))
            let directory = f.directory
            let steps = Events<Step>()
            defer { steps.close() }
            let blocked = Locked<Bool?>(nil)
            var sweeping = ExportDirectory.Seams.patient
            sweeping.beforePruneRemoval = { _ in
                // The folder has been judged old, and the attachment is opened again right now, on another thread.
                steps.record(.judgedOld)
                blocked.update { $0 = steps.block { $0.contains(.reopening) } }
            }
            var contending = ExportDirectory.Seams.patient
            contending.onLockBusy = { if $0 == .claim { steps.record(.reopening) } }
            let sweep = onThread { [sweeping] in
                try ExportDirectory(directory: directory, seams: sweeping).prune(changedBefore: cutoff())
            }
            try await steps.wait(for: .judgedOld)
            let reopened = onThread { [contending] in
                try ExportDirectory(directory: directory, seams: contending).export(from: again, filename: "photo.webp")
            }

            try await sweep.value.get()
            #expect(blocked.current == true)
            let url = try await reopened.value.get()
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
