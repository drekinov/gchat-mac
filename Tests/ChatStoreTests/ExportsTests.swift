import ChatModel
import Foundation
import Testing

@testable import ChatStore

func quarantine(of url: URL) -> String? {
    var buffer = [UInt8](repeating: 0, count: 256)
    let count = getxattr(url.path, "com.apple.quarantine", &buffer, buffer.count, 0, 0)
    return count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : nil
}

func exportFixture(
    _ data: Data = pattern(2 * mebibyte + 5)
) throws -> (Fixture, ExportDirectory, MediaCache, MediaReader) {
    let f = try Fixture(.sqlite)
    let cache = try f.mediaCache()
    try cache.put("media/x", data)
    let reader = try #require(try cache.open(mediaID: "media/x"))
    return (f, ExportDirectory(directory: f.directory), cache, reader)
}

/// Suites that take the export lock. Each test has a root of its own, so none waits for another. A test that waits
/// for a signal from another thread ends at the time limit if the signal never comes.
@Suite(.timeLimit(.minutes(1))) enum ExportLockSuites {}

extension ExportLockSuites {
    @Suite struct ExportTests {
        @Test func writesTheDecryptedFileWithAQuarantineAttribute() throws {
            let data = pattern(2 * mebibyte + 5)
            let (f, exports, _, reader) = try exportFixture(data)
            let url = try exports.export(from: reader, filename: "photo.png")

            #expect(try Data(contentsOf: url) == data)
            let value = try #require(quarantine(of: url))
            let fields = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            #expect(fields.count == 4)
            #expect(Int(fields[1], radix: 16).map { abs(Date().timeIntervalSince1970 - Double($0)) < 60 } == true)
            #expect(UUID(uuidString: fields[3]) != nil)
            let properties = try #require(
                try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.quarantinePropertiesKey])
                    .quarantineProperties)
            #expect(properties["LSQuarantineAgentName"] as? String == "Thimble")
            _ = f
        }

        @Test func layoutAndPermissions() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(100))
            let keyedName = reader.hash
            let url = try exports.export(from: reader, filename: "a.txt")
            let folder = url.deletingLastPathComponent()

            #expect(url.lastPathComponent == "a.txt")
            // The cache's keyed name: one folder per attachment that doesn't reveal its media ID.
            #expect(folder.lastPathComponent == keyedName)
            #expect(!folder.lastPathComponent.contains("media"))
            #expect(
                folder.deletingLastPathComponent().standardizedFileURL == f.directory.exportsURL.standardizedFileURL)
            #expect(f.directory.exportsURL.path.hasSuffix("exports/\(f.account.description)"))
            #expect(try fileMode(url) == 0o600)
            #expect(try fileMode(folder) == 0o700)
            #expect(try fileMode(f.directory.exportsURL) == 0o700)
        }

        @Test func uniqueExportsGetTheirOwnFolder() throws {
            let (f, exports, cache, first) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: first, filename: "same.bin", placement: .unique)
            let b = try exports.export(
                from: try #require(try cache.open(mediaID: "media/x")), filename: "same.bin", placement: .unique)
            #expect(a != b)
            #expect(a.lastPathComponent == b.lastPathComponent)
            #expect(UUID(uuidString: a.deletingLastPathComponent().lastPathComponent) != nil)
        }

        @Test func openingAgainHandsBackTheStoredCopyAsItIs() throws {
            let (f, exports, cache, first) = try exportFixture(pattern(1000))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: first, filename: "photo.webp")
            // Changed in place by the app it was opened in.
            let edited = Data("annotated".utf8)
            try edited.write(to: a)
            let inode = try #require(
                try FileManager.default.attributesOfItem(atPath: a.path)[.systemFileNumber] as? Int)

            let b = try exports.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "photo.webp")
            #expect(b == a)
            #expect(try Data(contentsOf: b) == edited)
            #expect(try FileManager.default.attributesOfItem(atPath: b.path)[.systemFileNumber] as? Int == inode)
            #expect(quarantine(of: b) != nil)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: b.deletingLastPathComponent().path) == [
                    "photo.webp"
                ])
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.exportsURL.path).count == 1)
        }

        @Test func aDifferentNameGetsItsOwnCopy() throws {
            let (f, exports, cache, first) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: first, filename: "")
            #expect(a.lastPathComponent == "attachment")
            let b = try exports.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "photo.webp")
            #expect(b.lastPathComponent == "photo.webp")
            #expect(b.deletingLastPathComponent() == a.deletingLastPathComponent())
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: a.deletingLastPathComponent().path).sorted() == [
                    "attachment", "photo.webp",
                ])
        }

        @Test func anotherQuarantinedFileInTheFolderIsNeverHandedOut() throws {
            let (f, exports, cache, first) = try exportFixture(pattern(10))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: first, filename: "photo.webp")
            // Saved next to it by the app it was opened in (Export As…), which quarantines what it writes.
            let sibling = a.deletingLastPathComponent().appendingPathComponent("photo.jpg")
            try Data("another picture".utf8).write(to: sibling)
            let value = Array("0083;0;Preview;".utf8)
            #expect(setxattr(sibling.path, ExportDirectory.quarantineAttribute, value, value.count, 0, 0) == 0)

            let b = try exports.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "photo.webp")
            #expect(b == a)
            #expect(try Data(contentsOf: sibling) == Data("another picture".utf8))
        }

        @Test func aCopyWhoseQuarantineWasDroppedKeepsItsEditsAndIsQuarantinedAgain() throws {
            let (f, exports, cache, first) = try exportFixture(pattern(1000))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: first, filename: "doc.pdf")
            // Saved by an app that didn't keep the quarantine.
            let edited = Data("annotated".utf8)
            try edited.write(to: a)
            #expect(removexattr(a.path, ExportDirectory.quarantineAttribute, 0) == 0)

            let b = try exports.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "doc.pdf")
            #expect(b == a)
            #expect(try Data(contentsOf: b) == edited)
            #expect(quarantine(of: b) != nil)
        }

        @Test func aCopyWithAQuarantineMacOSCantReadIsQuarantinedAgain() throws {
            let (f, exports, cache, first) = try exportFixture(pattern(1000))
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: first, filename: "doc.pdf")
            let edited = Data("annotated".utf8)
            try edited.write(to: a)
            let garbage = Array("not a quarantine".utf8)
            #expect(setxattr(a.path, ExportDirectory.quarantineAttribute, garbage, garbage.count, 0, 0) == 0)
            #expect(!ExportDirectory.hasQuarantineProperties(a))

            let b = try exports.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "doc.pdf")
            #expect(b == a)
            #expect(try Data(contentsOf: b) == edited)
            #expect(ExportDirectory.hasQuarantineProperties(b))
        }

        @Test func aCopyWhoseQuarantineCantBeRestoredIsLeftAloneAndNotHandedOut() throws {
            let (f, plain, cache, first) = try exportFixture(pattern(1000))
            defer { withExtendedLifetime(f) {} }
            let a = try plain.export(from: first, filename: "doc.pdf")
            let edited = Data("annotated".utf8)
            try edited.write(to: a)
            #expect(removexattr(a.path, ExportDirectory.quarantineAttribute, 0) == 0)
            var seams = ExportDirectory.Seams()
            seams.setQuarantineProperties = { _ in throw CocoaError(.fileWriteNoPermission) }
            seams.isSandboxed = { true }
            let again = try #require(try cache.open(mediaID: "media/x"))

            #expect(throws: ExportError.self) {
                try ExportDirectory(directory: f.directory, seams: seams).export(from: again, filename: "doc.pdf")
            }
            #expect(try Data(contentsOf: a) == edited)
            #expect(quarantine(of: a) == nil)
        }

        @Test func aStoredCopySwappedBeforeItsHandedOutIsRefused() throws {
            let (f, plain, cache, first) = try exportFixture(pattern(100))
            defer { withExtendedLifetime(f) {} }
            let a = try plain.export(from: first, filename: "doc.pdf")
            var seams = ExportDirectory.Seams()
            seams.beforeHandingOutStored = { url in
                // Another process puts a different file at the path after it was checked.
                let other = url.deletingLastPathComponent().appendingPathComponent("other")
                try? Data("not the attachment".utf8).write(to: other)
                _ = rename(other.path, url.path)
            }
            let again = try #require(try cache.open(mediaID: "media/x"))

            #expect(throws: ExportError.io(code: Int(ESTALE))) {
                try ExportDirectory(directory: f.directory, seams: seams).export(from: again, filename: "doc.pdf")
            }
            _ = a
        }

        @Test func aCopyAnotherExportStoredFirstIsHandedOut() throws {
            let data = pattern(1000)
            let (f, plain, cache, first) = try exportFixture(data)
            defer { withExtendedLifetime(f) {} }
            let second = try #require(try cache.open(mediaID: "media/x"))
            let stored = Locked<URL?>(nil)
            var seams = ExportDirectory.Seams()
            seams.beforeQuarantine = { _ in
                // While this export is still writing, another one of the same attachment starts and finishes.
                let url = try? plain.export(from: second, filename: "same.bin")
                stored.update { $0 = url }
            }

            let url = try ExportDirectory(directory: f.directory, seams: seams).export(
                from: first, filename: "same.bin")
            let storedURL = try #require(stored.current)
            #expect(url == storedURL)
            #expect(try Data(contentsOf: url) == data)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == [
                    "same.bin"
                ])
        }

        @Test func aStoredCopyIsNotReplacedByALaterWriter() throws {
            let (f, plain, cache, first) = try exportFixture(pattern(1000))
            defer { withExtendedLifetime(f) {} }
            let second = try #require(try cache.open(mediaID: "media/x"))
            let storedInode = Locked<Int?>(nil)
            var seams = ExportDirectory.Seams()
            seams.beforeQuarantine = { _ in
                guard let url = try? plain.export(from: second, filename: "same.bin") else { return }
                let inode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? Int
                storedInode.update { $0 = inode }
            }

            let url = try ExportDirectory(directory: f.directory, seams: seams).export(
                from: first, filename: "same.bin")
            // The first stored copy is the one handed out: an app may already have it open.
            let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
            #expect(inode != nil && inode == storedInode.current)
        }

        @Test func aWithdrawnExportHandsOutNothingAndLeavesTheStoredCopy() throws {
            let data = pattern(100)
            let (f, exports, cache, first) = try exportFixture(data)
            defer { withExtendedLifetime(f) {} }
            let a = try exports.export(from: first, filename: "a.bin")
            let again = try #require(try cache.open(mediaID: "media/x"))

            #expect(throws: ExportError.withdrawn) {
                try exports.export(from: again, filename: "a.bin", shouldHandOut: { _ in false })
            }
            #expect(try Data(contentsOf: a) == data)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: a.deletingLastPathComponent().path) == ["a.bin"])
        }

        @Test func aWithdrawnFirstExportLeavesNothingBehind() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(100))
            defer { withExtendedLifetime(f) {} }
            #expect(throws: ExportError.withdrawn) {
                try exports.export(from: reader, filename: "a.bin", shouldHandOut: { _ in false })
            }
            // Not even the account's folder.
            #expect(!FileManager.default.fileExists(atPath: f.directory.exportsURL.path))
        }

        @Test func aSessionThatEndsJustBeforeTheClaimWritesNothing() throws {
            let (f, _, _, reader) = try exportFixture(pattern(100))
            defer { withExtendedLifetime(f) {} }
            let folders = Locked(0)
            var seams = ExportDirectory.Seams()
            seams.afterFolderCreated = { _ in folders.update { $0 += 1 } }
            // Current when the export starts, ended by the time it takes the lock.
            let current: (ExportDirectory.Stage) -> Bool = { $0 != .claiming }

            #expect(throws: ExportError.withdrawn) {
                try ExportDirectory(directory: f.directory, seams: seams).export(
                    from: reader, filename: "a.bin", shouldHandOut: current)
            }
            #expect(folders.current == 0)
            // Not even the account's folder.
            #expect(!FileManager.default.fileExists(atPath: f.directory.exportsURL.path))
        }

        @Test func aSessionThatEndsWhileAStoredCopyIsCheckedGetsNothing() throws {
            let (f, plain, cache, first) = try exportFixture(pattern(100))
            defer { withExtendedLifetime(f) {} }
            let a = try plain.export(from: first, filename: "doc.pdf")
            let ended = Locked(false)
            var seams = ExportDirectory.Seams()
            seams.beforeHandingOutStored = { _ in ended.update { $0 = true } }
            let again = try #require(try cache.open(mediaID: "media/x"))

            #expect(throws: ExportError.withdrawn) {
                try ExportDirectory(directory: f.directory, seams: seams).export(
                    from: again, filename: "doc.pdf", shouldHandOut: { _ in !ended.current })
            }
            #expect(FileManager.default.fileExists(atPath: a.path))
        }

        @Test func aSessionThatEndsWhileANewCopyIsWrittenLeavesNothing() throws {
            let (f, _, _, reader) = try exportFixture(pattern(100))
            defer { withExtendedLifetime(f) {} }
            let ended = Locked(false)
            var seams = ExportDirectory.Seams()
            seams.beforeQuarantine = { _ in ended.update { $0 = true } }

            #expect(throws: ExportError.withdrawn) {
                try ExportDirectory(directory: f.directory, seams: seams).export(
                    from: reader, filename: "a.bin", shouldHandOut: { _ in !ended.current })
            }
            #expect(try FileManager.default.subpathsOfDirectory(atPath: f.directory.exportsURL.path).isEmpty)
        }

        @Test func aWriterWhoseSessionEndedLeavesTheNewSessionsCopyAlone() throws {
            let (f, plain, cache, first) = try exportFixture(pattern(100))
            defer { withExtendedLifetime(f) {} }
            let second = try #require(try cache.open(mediaID: "media/x"))
            let ended = Locked(false)
            let newCopy = Locked<URL?>(nil)
            let edited = Data("edited by the new session's app".utf8)
            var seams = ExportDirectory.Seams()
            seams.beforeQuarantine = { _ in
                // While this export writes, a new session stores the copy, its app saves it without the quarantine,
                // and this export's session ends.
                guard let url = try? plain.export(from: second, filename: "doc.pdf") else { return }
                try? edited.write(to: url)
                _ = removexattr(url.path, ExportDirectory.quarantineAttribute, 0)
                newCopy.update { $0 = url }
                ended.update { $0 = true }
            }

            #expect(throws: ExportError.withdrawn) {
                try ExportDirectory(directory: f.directory, seams: seams).export(
                    from: first, filename: "doc.pdf", shouldHandOut: { _ in !ended.current })
            }
            let url = try #require(newCopy.current)
            #expect(try Data(contentsOf: url) == edited)
            #expect(quarantine(of: url) == nil)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["doc.pdf"]
            )
        }

        @Test func concurrentExportsOfOneAttachmentAllSucceedWithOneCopy() async throws {
            let data = pattern(64 * 1024)
            let (f, _, cache, first) = try exportFixture(data)
            defer { withExtendedLifetime(f) {} }
            let readers = try [first] + (1..<8).map { _ in try #require(try cache.open(mediaID: "media/x")) }
            // However long each waits for its turn, none gives up.
            let exports = ExportDirectory(directory: f.directory, seams: .patient)

            let running = readers.map { reader in onThread { try exports.export(from: reader, filename: "same.bin") } }
            var urls: [URL] = []
            for export in running { urls.append(try await export.value.get()) }
            #expect(Set(urls).count == 1)
            let url = try #require(urls.first)
            #expect(try Data(contentsOf: url) == data)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == [
                    "same.bin"
                ])
        }

        @Test func emptyMediaExportsAnEmptyQuarantinedFile() throws {
            let (f, exports, _, reader) = try exportFixture(Data())
            defer { withExtendedLifetime(f) {} }
            let url = try exports.export(from: reader, filename: "empty")
            #expect(try Data(contentsOf: url).isEmpty)
            #expect(quarantine(of: url) != nil)
        }

        @Test func failsClosedWhenQuarantineCannotBeSet() throws {
            let (f, _, _, reader) = try exportFixture()
            var seams = ExportDirectory.Seams()
            seams.setQuarantineProperties = { _ in throw CocoaError(.fileWriteNoPermission) }
            seams.setQuarantineAttribute = { _, _ in
                errno = EPERM
                return -1
            }
            seams.isSandboxed = { false }
            let failing = ExportDirectory(directory: f.directory, seams: seams)
            #expect(throws: ExportError.quarantineFailed(code: Int(EPERM))) {
                try failing.export(from: reader, filename: "x.png")
            }
            let leftovers = try FileManager.default.subpathsOfDirectory(atPath: f.directory.exportsURL.path)
            #expect(leftovers.isEmpty)
        }

        @Test func aCorruptSourceLeavesNothingBehind() throws {
            let (f, exports, cache, _) = try exportFixture(pattern(2 * mebibyte))
            var bytes = try Data(contentsOf: f.mediaFile("media/x"))
            bytes[1_500_000] ^= 1
            try bytes.write(to: f.mediaFile("media/x"))
            let reader = try #require(try cache.open(mediaID: "media/x"))
            do throws(ExportError) {
                _ = try exports.export(from: reader, filename: "x.png")
                Issue.record("expected failure")
            } catch {
                if case .media(.corrupt) = error {} else { Issue.record("unexpected \(error)") }
            }
            #expect(try FileManager.default.subpathsOfDirectory(atPath: f.directory.exportsURL.path).isEmpty)
        }

        @Test func wipeRemovesEverythingForTheAccountOnly() throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(10))
            _ = try exports.export(from: reader, filename: "a.bin")
            _ = try exports.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "b.bin")

            let other = AccountDirectory(root: f.temp.url, account: AccountID())
            try other.createExports()
            try Data("x".utf8).write(to: other.exportsURL.appendingPathComponent("keep"))

            try exports.wipe()
            #expect(!FileManager.default.fileExists(atPath: f.directory.exportsURL.path))
            #expect(FileManager.default.fileExists(atPath: other.exportsURL.appendingPathComponent("keep").path))
            try exports.wipe()
        }

        @Test func wipeAllRemovesEveryAccountAndIsIdempotent() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            _ = try exports.export(from: reader, filename: "a.bin")
            let other = AccountDirectory(root: f.temp.url, account: AccountID())
            try other.createExports()
            try Data("x".utf8).write(to: other.exportsURL.appendingPathComponent("file"))
            let stray = f.temp.url.appendingPathComponent("exports/stray")
            try Data("x".utf8).write(to: stray)

            try ExportDirectory.wipeAll(root: f.temp.url)
            #expect(!FileManager.default.fileExists(atPath: f.temp.url.appendingPathComponent("exports").path))
            #expect(FileManager.default.fileExists(atPath: f.directory.storeURL.path))
            try ExportDirectory.wipeAll(root: f.temp.url)
        }

        @Test func wipeDoesNotFollowASymlinkedExportsDirectory() throws {
            let temp = TempDirectory()
            let victim = temp.url.appendingPathComponent("victim", isDirectory: true)
            try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
            try Data("precious".utf8).write(to: victim.appendingPathComponent("file"))
            let exports = temp.url.appendingPathComponent("exports")
            try FileManager.default.createSymbolicLink(at: exports, withDestinationURL: victim)

            try ExportDirectory.wipeAll(root: temp.url)
            #expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("file").path))
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: exports.path)) == nil)
        }

        @Test func wipeReportsEntriesItCannotRemove() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            let url = try exports.export(from: reader, filename: "a.bin")
            let folder = url.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            #expect(throws: ExportError.wipeIncomplete(failed: 1)) { try exports.wipe() }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try exports.wipe()
            #expect(!FileManager.default.fileExists(atPath: f.directory.exportsURL.path))
        }
    }
}

@Suite struct FilenameSanitizingTests {
    @Test(arguments: [
        ("photo.png", "photo.png"),
        ("a/b/c.txt", "abc.txt"),
        ("..\\..\\evil.sh", "evil.sh"),
        ("../../etc/passwd", "etcpasswd"),
        (".hidden", "hidden"),
        ("...", "attachment"),
        ("", "attachment"),
        ("   ", "attachment"),
        ("/", "attachment"),
        ("a\u{0}b\u{7}c\nd\te.txt", "abcde.txt"),
        ("a\u{85}b\u{2028}c.txt", "abc.txt"),
        ("invoice\u{202E}fdp.exe", "invoicefdp.exe"),
        ("\u{2066}x\u{2069}\u{200F}\u{200E}\u{061C}.txt", "x.txt"),
        ("  spaced name.pdf  ", "spaced name.pdf"),
        ("Zoë 写真 🎉.jpg", "Zoë 写真 🎉.jpg"),
        ("a:b.txt", "ab.txt"),
    ])
    func sanitizes(input: String, expected: String) {
        #expect(ExportDirectory.sanitize(input) == expected)
    }

    @Test func capsAtTwoHundredFiftyFiveBytesKeepingTheExtension() {
        let long = String(repeating: "a", count: 400) + ".pdf"
        let result = ExportDirectory.sanitize(long)
        #expect(result.utf8.count == 255)
        #expect(result.hasSuffix(".pdf"))

        let emoji = String(repeating: "🎉", count: 100) + ".jpeg"
        let capped = ExportDirectory.sanitize(emoji)
        #expect(capped.utf8.count <= 255)
        #expect(capped.hasSuffix(".jpeg"))
        #expect(capped.dropLast(5).allSatisfy { $0 == "🎉" })
    }

    @Test func aHugeExtensionIsTreatedAsPartOfTheName() {
        let result = ExportDirectory.sanitize("x." + String(repeating: "b", count: 400))
        #expect(result.utf8.count <= 255)
        #expect(!result.isEmpty)
    }

    @Test func exactlyAtTheLimitIsUntouched() {
        let name = String(repeating: "n", count: 251) + ".txt"
        #expect(name.utf8.count == 255)
        #expect(ExportDirectory.sanitize(name) == name)
    }

    @Test func resultIsAlwaysASingleSafeComponent() {
        let hostile = ["../..", "a/../b", "\u{202E}/\u{0}", ".", "..", "x/", "/x", "CON:", "\r\n"]
        for name in hostile {
            let result = ExportDirectory.sanitize(name)
            #expect(!result.isEmpty)
            #expect(!result.contains("/") && !result.hasPrefix("."))
            #expect(result.utf8.count <= 255)
        }
    }
}
