import ChatKeychain
import ChatModel
import ChatNet
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatSync

/// Attachments end to end against the fake: send with uploads, then download, cache, decode and export.
struct MediaFlowTests {
    struct Rig {
        let h = Harness()
        let team: SpaceName
        let client: GoogleChatClient
        let sends: SendQueue
        let root = FileManager.default.temporaryDirectory.appending(path: "gchat-media-\(UUID().uuidString)")

        init() {
            team = h.server.addSpace(.space, displayName: "Team", members: [h.alice, h.bob])
            client = GoogleChatClient(transport: h.server.makeTransport(), tokens: StaticTokens(token: h.alice.token))
            sends = SendQueue(
                api: client, store: h.store, gate: h.gate, clock: ServerClock(server: h.server), media: client,
                files: PathFileAccess())
        }

        func tempFile(_ data: Data, name: String) throws -> URL {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appending(path: name)
            try data.write(to: url)
            return url
        }

        func loader(redirectHosts: Set<String> = []) throws -> MediaLoader {
            let account = AccountID()
            let directory = AccountDirectory(root: root, account: account)
            let key = StoreKey.random(for: account)
            _ = try SQLiteAccountStore.open(directory: directory, key: key)
            let cache = try MediaCache(directory: directory, key: key)
            return MediaLoader(
                media: client, cache: cache, exports: ExportDirectory(directory: directory),
                pipeline: ImagePipeline(budget: MemoryBudget(capacity: 32 << 20)),
                fetcher: SafeFetcher(allowedHosts: redirectHosts, protocolClasses: [FakeMediaHost.self]), gate: h.gate)
        }
    }

    @Test func sendUploadsAttachmentsAndKeepsTheirTokens() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let file = try rig.tempFile(FakeMedia.png(), name: "photo.png")
        let attachment = PendingAttachment(
            bookmark: PathFileAccess.bookmark(for: file), filename: "photo.png", contentType: "image/png",
            byteCount: 100)
        _ = try rig.sends.enqueue(
            text: "look", space: rig.team, thread: nil, attachments: [attachment], rig.h.generation)
        let outcomes = try #require(try await rig.sends.drain(rig.team, rig.h.generation))
        #expect(outcomes.values.allSatisfy { if case .sent = $0 { true } else { false } })

        let posted = try #require(rig.h.server.messages(in: rig.team).first { $0.text == "look" })
        #expect(posted.attachments.count == 1)
        guard case .uploaded = posted.attachments.first?.source else {
            Issue.record("expected uploaded content")
            return
        }
        #expect(try rig.h.store.outbox().isEmpty)
    }

    @Test func missingFileFailsTheSendAndRestoresTheDraft() async throws {
        let rig = Rig()
        let attachment = PendingAttachment(
            bookmark: PathFileAccess.bookmark(for: URL(fileURLWithPath: "/nonexistent/gone.pdf")),
            filename: "gone.pdf", contentType: "application/pdf", byteCount: 1)
        _ = try rig.sends.enqueue(
            text: "see pdf", space: rig.team, thread: nil, attachments: [attachment], rig.h.generation)
        let outcomes = try #require(try await rig.sends.drain(rig.team, rig.h.generation))
        #expect(outcomes.values.first == .failed(reason: "fileUnavailable"))
        #expect(try rig.h.store.drafts().first?.text == "see pdf")
        #expect(rig.h.server.messages(in: rig.team).isEmpty)
    }

    @Test func imagesDownloadOnceThenComeFromTheEncryptedCache() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let media = rig.h.server.addMedia(
            FakeMedia.png(width: 400, height: 300), contentType: "image/png", filename: "a.png")
        let message = rig.h.server.postMedia([media], text: "pic", in: rig.team, from: .account(rig.h.bob))
        let attachment = try #require(message.attachments.first)
        let loader = try rig.loader()

        let first = try await loader.image(attachment, maxPixelSize: 200)
        #expect(max(first.image.width, first.image.height) <= 200)
        let downloads = { rig.h.server.requests.filter { $0.path.hasPrefix("/v1/media/") }.count }
        #expect(downloads() == 1)
        _ = try await loader.image(attachment, maxPixelSize: 100)
        #expect(downloads() == 1)
    }

    @Test func exportIsQuarantined() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let media = rig.h.server.addMedia(Data("hello pdf".utf8), contentType: "application/pdf", filename: "r.pdf")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let loader = try rig.loader()
        let url = try await loader.export(try #require(message.attachments.first))
        #expect(try Data(contentsOf: url) == Data("hello pdf".utf8))
        let size = getxattr(url.path, ExportDirectory.quarantineAttribute, nil, 0, 0, 0)
        #expect(size > 0)
    }

    @Test func redirectedDownloadsGoTokenlessThroughTheAllowlist() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        rig.h.server.mediaRedirectHost = "media.fake.example"
        let media = rig.h.server.addMedia(FakeMedia.png(), contentType: "image/png", filename: "r.png")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let attachment = try #require(message.attachments.first)

        await #expect(throws: MediaLoadError.self) { _ = try await rig.loader().image(attachment, maxPixelSize: 64) }
        _ = try await rig.loader(redirectHosts: ["media.fake.example"]).image(attachment, maxPixelSize: 64)
        #expect(!rig.h.server.mediaHostRequests.isEmpty)
        #expect(rig.h.server.mediaHostRequests.allSatisfy { !$0.hadCredentials })
    }

    @Test func retiredGenerationDoesNotCommitToTheCache() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let media = rig.h.server.addMedia(FakeMedia.png(), contentType: "image/png", filename: "x.png")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let loader = try rig.loader()
        rig.h.gate.retire()
        await #expect(throws: MediaLoadError.retired) {
            _ = try await loader.image(try #require(message.attachments.first), maxPixelSize: 64)
        }
    }
}

extension MediaFlowTests {
    /// Logout (gate retired, exports wiped) lands right after the export wrote its file.
    @Test func exportRacingLogoutLeavesNoPlaintext() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let media = rig.h.server.addMedia(Data("secret".utf8), contentType: "application/pdf", filename: "s.pdf")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let loader = try rig.loader()
        let gate = rig.h.gate
        loader.afterExportWrite = { gate.retire() }

        await #expect(throws: MediaLoadError.retired) {
            _ = try await loader.export(try #require(message.attachments.first))
        }
        let exported =
            FileManager.default.enumerator(atPath: rig.root.appending(path: "exports").path)?
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".pdf") } ?? []
        #expect(exported.isEmpty)
    }

    @Test func exportAfterRetireDoesNothing() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let media = rig.h.server.addMedia(Data("x".utf8), contentType: "application/pdf", filename: "x.pdf")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let loader = try rig.loader()
        rig.h.gate.retire()
        await #expect(throws: MediaLoadError.retired) {
            _ = try await loader.export(try #require(message.attachments.first))
        }
    }

    /// Pause export before file creation while logout retires the session and wipes files.
    @Test func logoutWaitsForARunningExportBeforeWiping() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let media = rig.h.server.addMedia(Data("secret".utf8), contentType: "application/pdf", filename: "s.pdf")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let loader = try rig.loader()
        let gate = rig.h.gate
        let events = Recorder<String>()
        let root = rig.root
        let logout = Recorder<Task<Void, Never>>()
        loader.beforeExportWrite = {
            logout.append(
                Task {
                    gate.retire()
                    await loader.close(waitingUpTo: .seconds(5))
                    events.append("closed")
                    Self.removeExportedPDFs(under: root)
                    events.append("wiped")
                })
            Thread.sleep(forTimeInterval: 0.15)
            events.append("exportWriting")
        }

        await #expect(throws: MediaLoadError.retired) {
            _ = try await loader.export(try #require(message.attachments.first))
        }
        events.append("exportReturned")
        for task in logout.all { await task.value }
        #expect(events.all.firstIndex(of: "exportReturned")! < events.all.firstIndex(of: "closed")!)
        let left =
            FileManager.default.enumerator(atPath: rig.root.path)?.compactMap { $0 as? String }
            .filter { $0.contains("exports/") && $0.hasSuffix(".pdf") } ?? []
        #expect(left.isEmpty)
    }

    static func removeExportedPDFs(under root: URL) {
        let files = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []
        for file in files where file.contains("exports/") && file.hasSuffix(".pdf") {
            try? FileManager.default.removeItem(at: root.appending(path: file))
        }
    }

    @Test func exportsAreRefusedOnceClosed() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let media = rig.h.server.addMedia(Data("x".utf8), contentType: "application/pdf", filename: "x.pdf")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let loader = try rig.loader()
        await loader.close()
        await #expect(throws: MediaLoadError.self) {
            _ = try await loader.export(try #require(message.attachments.first))
        }
        let files = FileManager.default.enumerator(atPath: rig.root.path)?.compactMap { $0 as? String } ?? []
        #expect(!files.contains { $0.contains("exports/") && $0.hasSuffix(".pdf") })
    }
}
