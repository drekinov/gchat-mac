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
        let url = try exports.export(from: reader, filename: "a.txt")
        let folder = url.deletingLastPathComponent()

        #expect(url.lastPathComponent == "a.txt")
        #expect(UUID(uuidString: folder.lastPathComponent) != nil)
        #expect(folder.deletingLastPathComponent().standardizedFileURL == f.directory.exportsURL.standardizedFileURL)
        #expect(f.directory.exportsURL.path.hasSuffix("exports/\(f.account.description)"))
        #expect(try fileMode(url) == 0o600)
        #expect(try fileMode(folder) == 0o700)
        #expect(try fileMode(f.directory.exportsURL) == 0o700)
    }

    @Test func eachExportGetsItsOwnFolder() throws {
        let (f, exports, cache, first) = try exportFixture(pattern(10))
        defer { withExtendedLifetime(f) {} }
        let a = try exports.export(from: first, filename: "same.bin")
        let b = try exports.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "same.bin")
        #expect(a != b)
        #expect(a.lastPathComponent == b.lastPathComponent)
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
