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

        func loader(
            redirectHosts: Set<String> = [], capacity: Int = 32 << 20, media: (any ChatMediaAPI)? = nil
        ) throws -> MediaLoader {
            let account = AccountID()
            let directory = AccountDirectory(root: root, account: account)
            let key = StoreKey.random(for: account)
            _ = try SQLiteAccountStore.open(directory: directory, key: key)
            let cache = try MediaCache(directory: directory, key: key)
            return MediaLoader(
                media: media ?? client, cache: cache, exports: ExportDirectory(directory: directory),
                pipeline: ImagePipeline(budget: MemoryBudget(capacity: capacity)),
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

    @Test func anImageTooLargeToShowStillExportsForAnotherApp() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let png = FakeMedia.png(width: 400, height: 300)
        let media = rig.h.server.addMedia(png, contentType: "image/png", filename: "big.png")
        let message = rig.h.server.postMedia([media], text: "pic", in: rig.team, from: .account(rig.h.bob))
        let attachment = try #require(message.attachments.first)
        // Room for the file, but never for decoding it.
        let loader = try rig.loader(capacity: png.count + 1000)

        var caught: MediaLoadError?
        do {
            _ = try await loader.image(attachment, maxPixelSize: 200)
        } catch {
            caught = error
        }
        #expect(caught == .image(.tooLarge))
        #expect(caught?.needsAnotherApp == true)
        let url = try await loader.export(attachment)
        #expect(try Data(contentsOf: url) == png)
    }

    @Test func anExportWaitingOnAnImageSizedDownloadStillGetsTheWholeFile() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        // Over what an inline image may be, well within what an export allows.
        let server = HeldDownloads(size: MediaLoader.maxImageBytes + 1, bytes: Data("whole file".utf8))
        // Lets anything still held finish if a setup step stops the test, so it fails rather than hangs.
        defer { server.release() }
        let loader = try rig.loader(media: server)
        let waits = Recorder<Int>()
        loader.onWaitForDownload = { waits.append(1) }
        let resource = try #require(MediaResourceName("media/large-photo"))
        let attachment = Attachment(contentName: "photo.webp", contentType: "image/webp", source: .uploaded(resource))

        let image = Task { () -> MediaLoadError? in
            do throws(MediaLoadError) {
                _ = try await loader.image(attachment, maxPixelSize: 200)
                return nil
            } catch {
                return error
            }
        }
        try #require(await poll { server.limits.count == 1 })
        let export = Task { try await loader.export(attachment) }
        // The export is waiting on the image's download before that download fails for size.
        try #require(await poll { !waits.all.isEmpty })
        server.release()

        #expect(await image.value == .api(.transport(.responseTooLarge)))
        let url = try await export.value
        #expect(try Data(contentsOf: url) == Data("whole file".utf8))
        #expect(server.limits == [MediaLoader.maxImageBytes, MediaLoader.maxFileBytes])
        #expect(loader.runningDownloadLimit(resource) == nil)
    }

    @Test func theLargerDownloadReplacesTheFailedOneAtOnceAndLaterRequestsJoinIt() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let server = HeldDownloads(size: MediaLoader.maxImageBytes + 1, bytes: Data("whole file".utf8))
        // Lets anything still held finish if a setup step stops the test, so it fails rather than hangs.
        defer { server.release() }
        let loader = try rig.loader(media: server)
        let waits = Recorder<Int>()
        loader.onWaitForDownload = { waits.append(1) }
        let resource = try #require(MediaResourceName("media/large-photo"))
        let attachment = Attachment(contentName: "photo.webp", contentType: "image/webp", source: .uploaded(resource))
        let image = {
            Task { () -> MediaLoadError? in
                do throws(MediaLoadError) {
                    _ = try await loader.image(attachment, maxPixelSize: 200)
                    return nil
                } catch {
                    return error
                }
            }
        }

        let first = image()
        try #require(await poll { server.heldCount == 1 })
        let export = Task { try await loader.export(attachment) }
        try #require(await poll { waits.all.count == 1 })
        // The image-sized download stops at its limit and the export's larger one takes its place, still held.
        server.releaseHeld()
        #expect(await first.value == .api(.transport(.responseTooLarge)))
        // Already in place when the first caller hears back, so nothing smaller can start in between.
        #expect(loader.runningDownloadLimit(resource) == MediaLoader.maxFileBytes)
        try #require(await poll { server.heldCount == 1 })
        // Another view asks for the image now: it waits on the larger download rather than starting a new one.
        // Three waits: the export on the first download, then the export and the new request on the larger one.
        let second = image()
        try #require(await poll { waits.all.count == 3 })
        #expect(server.limits.count == 2)
        server.release()

        let url = try await export.value
        #expect(try Data(contentsOf: url) == Data("whole file".utf8))
        // The cached bytes aren't an image, which is fine here: no third download was made for it.
        #expect(await second.value?.needsAnotherApp == true)
        #expect(server.limits == [MediaLoader.maxImageBytes, MediaLoader.maxFileBytes])
        #expect(loader.runningDownloadLimit(resource) == nil)
    }

    /// The export pauses as it starts waiting on the image's download and resumes only after the larger attempt
    /// that took over has finished, successfully or rate-limited, and left the table.
    @Test(arguments: [nil, ChatAPIError.rateLimited(retryAfter: .seconds(30))] as [ChatAPIError?])
    func aCallerResumingAfterTheLargerAttemptFinishedGetsItsResult(_ failure: ChatAPIError?) async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let server = HeldDownloads(
            size: MediaLoader.maxImageBytes + 1, bytes: Data("whole file".utf8),
            failures: failure.map { [MediaLoader.maxFileBytes: $0] } ?? [:])
        defer { server.release() }
        let loader = try rig.loader(media: server)
        let (resume, resumer) = AsyncStream<Void>.makeStream()
        defer { resumer.finish() }
        let waits = Recorder<Int>()
        loader.onWaitForDownload = {
            waits.append(1)
            if waits.all.count == 1 {
                for await _ in resume { break }
            }
        }
        let resource = try #require(MediaResourceName("media/large-photo"))
        let attachment = Attachment(contentName: "photo.webp", contentType: "image/webp", source: .uploaded(resource))

        let image = Task { () -> MediaLoadError? in
            do throws(MediaLoadError) {
                _ = try await loader.image(attachment, maxPixelSize: 200)
                return nil
            } catch {
                return error
            }
        }
        try #require(await poll { server.heldCount == 1 })
        let export = Task { () -> Result<URL, MediaLoadError> in
            do throws(MediaLoadError) {
                return .success(try await loader.export(attachment))
            } catch {
                return .failure(error)
            }
        }
        try #require(await poll { waits.all.count == 1 })
        server.release()
        #expect(await image.value == .api(.transport(.responseTooLarge)))
        try #require(await poll { server.limits.count == 2 && loader.runningDownloadLimit(resource) == nil })
        resumer.yield()

        switch await export.value {
        case .success(let url):
            #expect(failure == nil)
            #expect(try Data(contentsOf: url) == Data("whole file".utf8))
        case .failure(let error):
            #expect(error == failure.map { .api($0) })
        }
        #expect(server.limits == [MediaLoader.maxImageBytes, MediaLoader.maxFileBytes])
        #expect(loader.runningDownloadLimit(resource) == nil)
    }

    @Test func aLargerCallerDoesNotRetryAFailureALargerLimitCannotFix() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        // Fails the image-sized download the way a rate-limited server would.
        let server = HeldDownloads(
            size: 1, bytes: Data(), failures: [MediaLoader.maxImageBytes: .rateLimited(retryAfter: .seconds(30))])
        defer { server.release() }
        let loader = try rig.loader(media: server)
        let waits = Recorder<Int>()
        loader.onWaitForDownload = { waits.append(1) }
        let resource = try #require(MediaResourceName("media/photo"))
        let attachment = Attachment(contentName: "photo.png", contentType: "image/png", source: .uploaded(resource))

        let image = Task { () -> MediaLoadError? in
            do throws(MediaLoadError) {
                _ = try await loader.image(attachment, maxPixelSize: 200)
                return nil
            } catch {
                return error
            }
        }
        try #require(await poll { server.heldCount == 1 })
        let export = Task { () -> MediaLoadError? in
            do throws(MediaLoadError) {
                _ = try await loader.export(attachment)
                return nil
            } catch {
                return error
            }
        }
        try #require(await poll { waits.all.count == 1 })
        server.release()

        #expect(await image.value == .api(.rateLimited(retryAfter: .seconds(30))))
        #expect(await export.value == .api(.rateLimited(retryAfter: .seconds(30))))
        #expect(server.limits == [MediaLoader.maxImageBytes])
    }

    @Test(arguments: [
        (MediaLoadError.image(.tooLarge), true),
        (.image(.tooManyFrames), true),
        (.image(.unsupported), true),
        (.image(.corrupt), true),
        (.transport(.responseTooLarge), true),
        (.api(.transport(.responseTooLarge)), true),
        (.image(.budget), false),
        (.image(.cancelled), false),
        (.transport(.offline), false),
        (.api(.transport(.offline)), false),
        (.api(.rateLimited(retryAfter: nil)), false),
        (.api(.unauthorized), false),
        (.retired, false),
    ])
    func onlyFailuresThatRetryingCantFixNeedAnotherApp(_ error: MediaLoadError, _ expected: Bool) {
        #expect(error.needsAnotherApp == expected)
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

/// A media server with one file of `size` bytes whose downloads wait until `release()`. Only `bytes` are
/// delivered, so a large file costs nothing to fake.
final class HeldDownloads: ChatMediaAPI {
    private struct State {
        var limits: [Int] = []
        var held: [CheckedContinuation<Void, Never>] = []
        var released = false
    }

    let size: Int
    let bytes: Data
    /// Thrown, by size limit, by downloads once they're let through, instead of delivering anything.
    let failures: [Int: ChatAPIError]
    private let state = Mutex(State())

    init(size: Int, bytes: Data, failures: [Int: ChatAPIError] = [:]) {
        self.size = size
        self.bytes = bytes
        self.failures = failures
    }

    /// The size limit of each download, in the order they started.
    var limits: [Int] { state.withLock { $0.limits } }

    /// Lets every download through, now and from now on.
    func release() { resume(andStopHolding: true) }

    /// Lets the downloads waiting now through; later ones still wait.
    func releaseHeld() { resume(andStopHolding: false) }

    private func resume(andStopHolding stop: Bool) {
        let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            if stop { state.released = true }
            defer { state.held = [] }
            return state.held
        }
        for continuation in held { continuation.resume() }
    }

    var heldCount: Int { state.withLock { $0.held.count } }

    func uploadAttachment(
        to space: SpaceName, file: URL, filename: String, contentType: String
    ) async throws(ChatAPIError) -> UploadedAttachment {
        throw .noCredentials
    }

    func downloadMedia(
        _ resource: MediaResourceName, maxBytes: Int, onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws(ChatAPIError) -> MediaDownload {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = state.withLock { state -> Bool in
                state.limits.append(maxBytes)
                guard !state.released else { return true }
                state.held.append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
        if let failure = failures[maxBytes] { throw failure }
        guard size <= maxBytes else { throw .transport(.responseTooLarge) }
        do { try onChunk(bytes) } catch { throw .transport(.sinkFailed) }
        return MediaDownload(byteCount: bytes.count)
    }
}
