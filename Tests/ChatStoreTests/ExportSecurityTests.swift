import ChatModel
import Foundation
import Testing

@testable import ChatStore

private func contents(_ url: URL) -> [String] {
    ((try? FileManager.default.subpathsOfDirectory(atPath: url.path)) ?? []).sorted()
}

func makeVictim(in f: Fixture) throws -> URL {
    let victim = f.temp.url.appendingPathComponent("victim", isDirectory: true)
    try FileManager.default.createDirectory(
        at: victim, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    return victim
}

extension ExportLockSuites {
    @Suite struct ExportSymlinkTests {
        @Test func aSymlinkedAccountDirectoryIsRefused() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(100))
            let victim = try makeVictim(in: f)
            try f.directory.createExports()
            try FileManager.default.removeItem(at: f.directory.exportsURL)
            try FileManager.default.createSymbolicLink(at: f.directory.exportsURL, withDestinationURL: victim)

            #expect(throws: ExportError.self) { try exports.export(from: reader, filename: "x.bin") }
            #expect(contents(victim).isEmpty)
            #expect(try fileMode(victim) == 0o755)
        }

        @Test func aSymlinkedExportsRootIsRefused() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(100))
            let victim = try makeVictim(in: f)
            let root = f.temp.url.appendingPathComponent("exports")
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: victim)

            #expect(throws: ExportError.self) { try exports.export(from: reader, filename: "x.bin") }
            #expect(contents(victim).isEmpty)
            #expect(try fileMode(victim) == 0o755)
        }
    }
}

extension ExportLockSuites {
    @Suite struct ExportPlantedPathTests {
        @Test func aSymlinkPlantedAtTheFileNameIsNotFollowed() throws {
            let (f, _, _, reader) = try exportFixture(pattern(100))
            let victim = try makeVictim(in: f)
            let target = victim.appendingPathComponent("target.txt")
            try Data("original".utf8).write(to: target)
            var seams = ExportDirectory.Seams()
            seams.afterFolderCreated = { folder in
                try? FileManager.default.createSymbolicLink(
                    at: folder.appendingPathComponent("x.bin"), withDestinationURL: target)
            }
            let exports = ExportDirectory(directory: f.directory, seams: seams)
            let link = f.directory.exportsURL.appendingPathComponent(reader.hash).appendingPathComponent("x.bin")

            #expect(throws: ExportError.self) { try exports.export(from: reader, filename: "x.bin") }
            #expect(try Data(contentsOf: target) == Data("original".utf8))
            // Left as it was, never followed: cleanup removes only what the export itself made.
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path)
            #expect(!contents(f.directory.exportsURL).contains { $0.hasSuffix(".partial") })
        }

        @Test func aSymlinkInPlaceOfAPreviousCopyIsRefusedNotFollowed() throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(100))
            let victim = try makeVictim(in: f)
            let target = victim.appendingPathComponent("target.txt")
            try Data("original".utf8).write(to: target)
            let url = try exports.export(from: reader, filename: "x.bin")
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            let again = try #require(try cache.open(mediaID: "media/x"))

            #expect(throws: ExportError.io(code: Int(EEXIST))) { try exports.export(from: again, filename: "x.bin") }
            #expect(try Data(contentsOf: target) == Data("original".utf8))
            #expect(quarantine(of: target) == nil)
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == target.path)
            #expect(!contents(f.directory.exportsURL).contains { $0.hasSuffix(".partial") })
        }

        @Test func aHardLinkInPlaceOfACopyIsRefusedAndTheOtherFileIsUntouched() throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(100))
            let a = try exports.export(from: reader, filename: "x.bin")
            let outside = f.temp.url.appendingPathComponent("outside.txt")
            try Data("elsewhere".utf8).write(to: outside)
            try FileManager.default.removeItem(at: a)
            #expect(link(outside.path, a.path) == 0)
            let again = try #require(try cache.open(mediaID: "media/x"))

            #expect(throws: ExportError.io(code: Int(EMLINK))) { try exports.export(from: again, filename: "x.bin") }
            #expect(quarantine(of: outside) == nil)
            #expect(try Data(contentsOf: outside) == Data("elsewhere".utf8))
        }

        @Test func aFolderSwappedForASymlinkAfterCreationIsDetected() throws {
            let (f, _, _, reader) = try exportFixture(pattern(100))
            let victim = try makeVictim(in: f)
            let moved = f.temp.url.appendingPathComponent("moved", isDirectory: true)
            var seams = ExportDirectory.Seams()
            seams.afterFolderCreated = { folder in
                try? FileManager.default.moveItem(at: folder, to: moved)
                try? FileManager.default.createSymbolicLink(at: folder, withDestinationURL: victim)
            }
            let exports = ExportDirectory(directory: f.directory, seams: seams)

            #expect(throws: ExportError.self) { try exports.export(from: reader, filename: "x.bin") }
            #expect(contents(victim).isEmpty)
        }

        @Test func theFileSwappedBeforeQuarantineIsDetectedAndRemoved() throws {
            let (f, _, _, reader) = try exportFixture(pattern(100))
            let victim = try makeVictim(in: f)
            let target = victim.appendingPathComponent("target.txt")
            try Data("original".utf8).write(to: target)
            var seams = ExportDirectory.Seams()
            seams.beforeQuarantine = { url in
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            }
            let exports = ExportDirectory(directory: f.directory, seams: seams)

            #expect(throws: ExportError.io(code: Int(ESTALE))) { try exports.export(from: reader, filename: "x.bin") }
            #expect(quarantine(of: target) == nil)
            #expect(try Data(contentsOf: target) == Data("original".utf8))
            #expect(contents(f.directory.exportsURL).isEmpty)
        }
    }
}

extension ExportLockSuites {
    @Suite struct ExportQuarantineTests {
        private func exporter(_ f: Fixture, _ configure: (inout ExportDirectory.Seams) -> Void) -> ExportDirectory {
            var seams = ExportDirectory.Seams()
            configure(&seams)
            return ExportDirectory(directory: f.directory, seams: seams)
        }

        @Test func theResourceValuesPathQuarantinesTheFile() throws {
            let (f, _, _, reader) = try exportFixture(pattern(100))
            let exports = exporter(f) {
                $0.setQuarantineAttribute = { _, _ in
                    Issue.record("the xattr path must not run")
                    return -1
                }
            }
            let url = try exports.export(from: reader, filename: "a.pdf")

            let fresh = URL(fileURLWithPath: url.path)
            let properties = try #require(
                try fresh.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
            #expect(properties["LSQuarantineAgentName"] as? String == "Thimble")
            #expect(properties["LSQuarantineType"] != nil)
            let raw = try #require(quarantine(of: url))
            #expect(raw.split(separator: ";", omittingEmptySubsequences: false).count == 4)
        }

        @Test func aSandboxedProcessNeverFallsBackToTheAttribute() throws {
            let (f, _, _, reader) = try exportFixture(pattern(100))
            let exports = exporter(f) {
                $0.setQuarantineProperties = { _ in throw CocoaError(.fileWriteNoPermission) }
                $0.setQuarantineAttribute = { _, _ in
                    Issue.record("the xattr path must not run when sandboxed")
                    return 0
                }
                $0.isSandboxed = { true }
            }
            do throws(ExportError) {
                _ = try exports.export(from: reader, filename: "a.pdf")
                Issue.record("expected failure")
            } catch {
                if case .quarantineFailed = error {} else { Issue.record("unexpected \(error)") }
            }
            #expect(contents(f.directory.exportsURL).isEmpty)
        }

        @Test func anUnsandboxedProcessFallsBackToTheAttribute() throws {
            let (f, _, _, reader) = try exportFixture(pattern(100))
            let exports = exporter(f) {
                $0.setQuarantineProperties = { _ in throw CocoaError(.fileWriteNoPermission) }
                $0.isSandboxed = { false }
            }
            let url = try exports.export(from: reader, filename: "a.pdf")
            let value = try #require(quarantine(of: url))
            #expect(value.hasPrefix("0083;"))
            #expect(value.contains(";Thimble;"))
        }

        @Test func unsandboxedFallbackStillFailsClosed() throws {
            let (f, _, _, reader) = try exportFixture(pattern(100))
            let exports = exporter(f) {
                $0.setQuarantineProperties = { _ in throw CocoaError(.fileWriteNoPermission) }
                $0.setQuarantineAttribute = { _, _ in
                    errno = EPERM
                    return -1
                }
                $0.isSandboxed = { false }
            }
            #expect(throws: ExportError.quarantineFailed(code: Int(EPERM))) {
                try exports.export(from: reader, filename: "a.pdf")
            }
            #expect(contents(f.directory.exportsURL).isEmpty)
        }

        @Test func aSetterThatSilentlyDoesNothingFailsClosed() throws {
            let (f, _, _, reader) = try exportFixture(pattern(100))
            let exports = exporter(f) { $0.setQuarantineProperties = { _ in } }
            #expect(throws: ExportError.quarantineFailed(code: Int(ENOATTR))) {
                try exports.export(from: reader, filename: "a.pdf")
            }
            #expect(contents(f.directory.exportsURL).isEmpty)
        }

        @Test func sandboxDetectionReadsTheContainerVariable() {
            #expect(
                ExportDirectory.runningSandboxed()
                    == (ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil))
        }
    }
}

extension ExportLockSuites {
    @Suite struct ExportWipeSymlinkTests {
        enum Wipe: String, CaseIterable, Sendable, CustomTestStringConvertible {
            case account
            case all
            case delegated

            var testDescription: String { rawValue }

            func run(_ f: Fixture) throws {
                switch self {
                case .account: try ExportDirectory(directory: f.directory).wipe()
                case .all: try ExportDirectory.wipeAll(root: f.temp.url)
                case .delegated: try f.directory.wipeExports()
                }
            }
        }

        private func victim(in f: Fixture) throws -> (dir: URL, file: URL, nested: URL) {
            let dir = try makeVictim(in: f)
            let file = dir.appendingPathComponent("keep.txt")
            let nested = dir.appendingPathComponent("sub/inner.txt")
            try FileManager.default.createDirectory(
                at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("precious".utf8).write(to: file)
            try Data("precious".utf8).write(to: nested)
            return (dir, file, nested)
        }

        private func expectSurvivors(_ v: (dir: URL, file: URL, nested: URL)) throws {
            #expect(try Data(contentsOf: v.file) == Data("precious".utf8))
            #expect(try Data(contentsOf: v.nested) == Data("precious".utf8))
            #expect(try fileMode(v.dir) == 0o755)
        }

        private func isGone(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) != 0
        }

        @Test(arguments: Wipe.allCases) func aSymlinkedExportsRootIsUnlinkedNotFollowed(_ wipe: Wipe) throws {
            let (f, _, _, _) = try exportFixture(pattern(10))
            let v = try victim(in: f)
            let root = f.temp.url.appendingPathComponent("exports")
            try f.directory.createExports()
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: v.dir)

            try wipe.run(f)
            try expectSurvivors(v)
            #expect(isGone(root))
        }

        @Test(arguments: Wipe.allCases) func aSymlinkedAccountFolderIsUnlinkedNotFollowed(_ wipe: Wipe) throws {
            let (f, _, _, _) = try exportFixture(pattern(10))
            let v = try victim(in: f)
            let account = f.directory.exportsURL
            try f.directory.createExports()
            try FileManager.default.removeItem(at: account)
            try FileManager.default.createSymbolicLink(at: account, withDestinationURL: v.dir)

            try wipe.run(f)
            try expectSurvivors(v)
            #expect(isGone(account))
        }

        @Test(arguments: Wipe.allCases) func symlinksInsideAnExportFolderAreUnlinkedNotFollowed(_ wipe: Wipe) throws {
            let (f, exports, cache, reader) = try exportFixture(pattern(10))
            let v = try victim(in: f)
            let url = try exports.export(from: reader, filename: "a.bin")
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createSymbolicLink(
                at: folder.appendingPathComponent("dirlink"), withDestinationURL: v.dir)
            try FileManager.default.createSymbolicLink(
                at: folder.appendingPathComponent("filelink"), withDestinationURL: v.file)
            try FileManager.default.createSymbolicLink(
                at: f.directory.exportsURL.appendingPathComponent("toplink"), withDestinationURL: v.dir)
            let second = try exports.export(from: try #require(try cache.open(mediaID: "media/x")), filename: "b.bin")

            try wipe.run(f)
            try expectSurvivors(v)
            #expect(isGone(f.directory.exportsURL) || wipe == .all)
            #expect(isGone(url) && isGone(second) && isGone(folder.appendingPathComponent("dirlink")))
        }

        @Test(arguments: Wipe.allCases) func aSymlinkToTheExportsTreeItselfLeavesTheTargetAlone(_ wipe: Wipe) throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            let url = try exports.export(from: reader, filename: "a.bin")
            let alias = f.temp.url.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.directory.exportsURL)
            try wipe.run(f)
            #expect(isGone(url))
            #expect(!FileManager.default.fileExists(atPath: f.directory.exportsURL.path))
        }

        @Test func deeplyNestedTreesAreRemoved() throws {
            let (f, exports, _, reader) = try exportFixture(pattern(10))
            let url = try exports.export(from: reader, filename: "a.bin")
            var deep = url.deletingLastPathComponent()
            for level in 0..<30 { deep.appendPathComponent("d\(level)", isDirectory: true) }
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: deep.appendingPathComponent("leaf"))
            try ExportDirectory(directory: f.directory).wipe()
            #expect(!FileManager.default.fileExists(atPath: f.directory.exportsURL.path))
        }

        @Test func wipingWhenNothingExistsIsANoOp() throws {
            let f = try Fixture(.sqlite)
            for wipe in Wipe.allCases { try wipe.run(f) }
            try ExportDirectory.wipeAll(root: f.temp.url.appendingPathComponent("missing"))
        }
    }
}
