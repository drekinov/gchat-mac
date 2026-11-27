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

/// What other tasks and threads report, in order. A wait ends when its condition holds, when the log is closed, or
/// when the test is cancelled at its time limit; nothing here waits on a clock.
private final class MediaSignals<Event: Sendable>: Sendable {
    private struct Waiter {
        let id: Int
        let done: @Sendable ([Event]) -> Bool
        let resume: @Sendable (Bool) -> Void
    }

    private struct State {
        var log: [Event] = []
        var closed = false
        var waiters: [Waiter] = []
        var nextID = 0
    }

    private let state = Mutex(State())

    func record(_ event: Event) {
        let ready = state.withLock { state -> [Waiter] in
            state.log.append(event)
            let ready = state.waiters.filter { $0.done(state.log) }
            state.waiters.removeAll { $0.done(state.log) }
            return ready
        }
        for waiter in ready { waiter.resume(true) }
    }

    var all: [Event] { state.withLock { $0.log } }

    /// Lets every waiter go, now and from now on.
    func close() {
        let waiters = state.withLock { state -> [Waiter] in
            state.closed = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(false) }
    }

    /// Nil when the wait is over already; otherwise the waiter's ID.
    private func enlist(
        _ done: @escaping @Sendable ([Event]) -> Bool, cancelled: Bool = false,
        resume: @escaping @Sendable (Bool) -> Void
    ) -> Int? {
        let outcome = state.withLock { state -> (id: Int?, held: Bool) in
            if done(state.log) { return (nil, true) }
            if state.closed || cancelled { return (nil, false) }
            state.nextID += 1
            state.waiters.append(Waiter(id: state.nextID, done: done, resume: resume))
            return (state.nextID, false)
        }
        if outcome.id == nil { resume(outcome.held) }
        return outcome.id
    }

    private func dismiss(_ id: Int) {
        let waiter = state.withLock { state -> Waiter? in
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return state.waiters.remove(at: index)
        }
        waiter?.resume(false)
    }

    /// Returns once `done` holds; throws if the log is closed or the waiting task cancelled first.
    func wait(where done: @escaping @Sendable ([Event]) -> Bool) async throws {
        let id = Mutex<Int?>(nil)
        let held = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // Under the handler's lock, so a cancellation either sees the waiter or is seen here.
                id.withLock { $0 = enlist(done, cancelled: Task.isCancelled) { continuation.resume(returning: $0) } }
            }
        } onCancel: {
            id.withLock { if let waiting = $0 { dismiss(waiting) } }
        }
        guard held else { throw CancellationError() }
    }

    /// Like `wait`, but cancelling the waiting task doesn't end it: only `done` holding or the log closing does.
    func hold(until done: @escaping @Sendable ([Event]) -> Bool) async {
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            _ = enlist(done) { continuation.resume(returning: $0) }
        }
    }

    /// For a seam that runs synchronously: blocks its thread until `done` holds or the log is closed.
    func block(until done: @escaping @Sendable ([Event]) -> Bool) {
        let woken = DispatchSemaphore(value: 0)
        _ = enlist(done) { _ in woken.signal() }
        woken.wait()
    }
}

extension MediaSignals where Event: Equatable {
    func wait(for event: Event) async throws { try await wait { $0.contains(event) } }
}

/// The task's result. Unlike `Task.value`, this stops waiting when the test is cancelled at its time limit, so a
/// task that never ends fails the test instead of hanging the run.
private func finished<Value: Sendable>(_ task: Task<Value, Never>) async throws -> Value {
    let result = MediaSignals<Value>()
    Task { result.record(await task.value) }
    try await result.wait { !$0.isEmpty }
    return result.all[0]
}

/// Attachments end to end against the fake: send with uploads, then download, cache, decode and export.
@Suite(.timeLimit(.minutes(1))) struct MediaFlowTests {
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

        /// With `closeSleep`, that is how the loader's `close` waits out its timeout.
        func loader(
            redirectHosts: Set<String> = [], capacity: Int = 32 << 20, media: (any ChatMediaAPI)? = nil,
            account: AccountID = AccountID(), closeSleep: (@Sendable (Duration) async throws -> Void)? = nil
        ) throws -> MediaLoader {
            let directory = AccountDirectory(root: root, account: account)
            let key = StoreKey.random(for: account)
            _ = try SQLiteAccountStore.open(directory: directory, key: key)
            let cache = try MediaCache(directory: directory, key: key)
            let exports = ExportDirectory(directory: directory)
            let pipeline = ImagePipeline(budget: MemoryBudget(capacity: capacity))
            let fetcher = SafeFetcher(allowedHosts: redirectHosts, protocolClasses: [FakeMediaHost.self])
            guard let closeSleep else {
                return MediaLoader(
                    media: media ?? client, cache: cache, exports: exports, pipeline: pipeline, fetcher: fetcher,
                    gate: h.gate)
            }
            return MediaLoader(
                media: media ?? client, cache: cache, exports: exports, pipeline: pipeline, fetcher: fetcher,
                gate: h.gate, closeSleep: closeSleep)
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
        defer { try? FileManager.default.removeItem(at: rig.root) }
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
        let waits = MediaSignals<Int>()
        loader.onWaitForDownload = { waits.record(1) }
        let resource = try #require(MediaResourceName("media/large-photo"))
        let attachment = Attachment(contentName: "photo.webp", contentType: "image/webp", source: .uploaded(resource))

        let image = Task { await Self.imageError(loader, attachment) }
        try await server.waitForDownloads(1)
        let export = Task { await Self.exportResult(loader, attachment) }
        // The export is waiting on the image's download before that download fails for size.
        try await waits.wait { $0.count == 1 }
        server.release()

        #expect(try await finished(image) == .api(.transport(.responseTooLarge)))
        let url = try await finished(export).get()
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
        let waits = MediaSignals<Int>()
        loader.onWaitForDownload = { waits.record(1) }
        let resource = try #require(MediaResourceName("media/large-photo"))
        let attachment = Attachment(contentName: "photo.webp", contentType: "image/webp", source: .uploaded(resource))

        let first = Task { await Self.imageError(loader, attachment) }
        try await server.waitForDownloads(1)
        let export = Task { await Self.exportResult(loader, attachment) }
        try await waits.wait { $0.count == 1 }
        // The image-sized download stops at its limit and the export's larger one takes its place, still held.
        server.releaseHeld()
        #expect(try await finished(first) == .api(.transport(.responseTooLarge)))
        // Already in place when the first caller hears back, so nothing smaller can start in between.
        try #require(loader.runningDownloadLimit(resource) == MediaLoader.maxFileBytes)
        try await server.waitForDownloads(2)
        #expect(server.heldCount == 1)
        // Another view asks for the image now: it waits on the larger download rather than starting a new one.
        // Three waits: the export on the first download, then the export and the new request on the larger one.
        let second = Task { await Self.imageError(loader, attachment) }
        try await waits.wait { $0.count == 3 }
        server.release()

        let url = try await finished(export).get()
        #expect(try Data(contentsOf: url) == Data("whole file".utf8))
        // The cached bytes aren't an image, which is fine here: no third download was made for it.
        #expect(try await finished(second)?.needsAnotherApp == true)
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
        let waits = MediaSignals<Int>()
        loader.onWaitForDownload = {
            waits.record(1)
            if waits.all.count == 1 {
                for await _ in resume { break }
            }
        }
        let settled = MediaSignals<Int>()
        loader.afterDownloadSettles = { settled.record($0) }
        let resource = try #require(MediaResourceName("media/large-photo"))
        let attachment = Attachment(contentName: "photo.webp", contentType: "image/webp", source: .uploaded(resource))

        let image = Task { await Self.imageError(loader, attachment) }
        try await server.waitForDownloads(1)
        let export = Task { await Self.exportResult(loader, attachment) }
        try await waits.wait { $0.count == 1 }
        server.release()
        #expect(try await finished(image) == .api(.transport(.responseTooLarge)))
        // The larger attempt has finished and left the table before the export looks at the first one's result.
        try await settled.wait(for: MediaLoader.maxFileBytes)
        #expect(loader.runningDownloadLimit(resource) == nil)
        resumer.yield()

        switch try await finished(export) {
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
        let waits = MediaSignals<Int>()
        loader.onWaitForDownload = { waits.record(1) }
        let settled = MediaSignals<Int>()
        loader.afterDownloadSettles = { settled.record($0) }
        let resource = try #require(MediaResourceName("media/photo"))
        let attachment = Attachment(contentName: "photo.png", contentType: "image/png", source: .uploaded(resource))

        let image = Task { await Self.imageError(loader, attachment) }
        try await server.waitForDownloads(1)
        let export = Task { await Self.exportResult(loader, attachment) }
        try await waits.wait { $0.count == 1 }
        // Only the download waiting now is let through: one started after it would stay held, and in the table.
        server.releaseHeld()

        #expect(try await finished(image) == .api(.rateLimited(retryAfter: .seconds(30))))
        let exported = try await finished(export)
        #expect(throws: MediaLoadError.api(.rateLimited(retryAfter: .seconds(30)))) { try exported.get() }
        try await settled.wait(for: MediaLoader.maxImageBytes)
        #expect(loader.runningDownloadLimit(resource) == nil)
        #expect(server.limits == [MediaLoader.maxImageBytes])
    }

    /// Nil when the image loads.
    static func imageError(_ loader: MediaLoader, _ attachment: ChatModel.Attachment) async -> MediaLoadError? {
        do throws(MediaLoadError) {
            _ = try await loader.image(attachment, maxPixelSize: 200)
            return nil
        } catch {
            return error
        }
    }

    static func exportResult(_ loader: MediaLoader, _ attachment: ChatModel.Attachment) async -> Result<
        URL, MediaLoadError
    > {
        do throws(MediaLoadError) {
            return .success(try await loader.export(attachment))
        } catch {
            return .failure(error)
        }
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

    @Test func forgettingExpiredMediaRemovesTheCachedAndExportedCopies() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let media = rig.h.server.addMedia(Data("gone soon".utf8), contentType: "application/pdf", filename: "g.pdf")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let attachment = try #require(message.attachments.first)
        guard case .uploaded(let resource) = attachment.source else { return #expect(Bool(false)) }
        let loader = try rig.loader()
        let url = try await loader.export(attachment)
        #expect(loader.cache.contains(mediaID: resource.rawValue))

        #expect(await loader.forget([resource.rawValue]))
        #expect(!loader.cache.contains(mediaID: resource.rawValue))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        #expect(await loader.forget([resource.rawValue]), "forgetting what is gone already succeeds")
    }

    @Test func aSessionRemovesTheMediaOfExpiredHistoryOffMessages() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let server = rig.h.server
        let media = server.addMedia(Data("one day only".utf8), contentType: "application/pdf", filename: "d.pdf")
        let message = server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let attachment = try #require(message.attachments.first)
        let clock = ServerClock(server: server)
        let store = InMemoryAccountStore(now: { clock.now() })
        let gate = rig.h.gate
        var team = try #require(server.space(rig.team))
        team.historyOn = false
        try store.write(gate: gate, generation: try #require(gate.current)) { batch in
            batch.append(.mergeSpace(team))
            batch.append(.upsertMessages([message]))
        }
        let loader = try rig.loader()
        let url = try await loader.export(attachment)
        #expect(loader.cache.contains(mediaID: media.rawValue))

        server.advance(.seconds(25 * 3600))
        let session = AccountSession(
            account: AccountID(), me: rig.h.alice.user.name, api: rig.client, store: store, clock: clock,
            logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: rig.root)),
            gate: gate, mediaLoader: loader)
        #expect(try store.message(message.name) == nil)
        #expect(try store.expiredCleanup()?.media == [media.rawValue])

        await session.cleanUpExpired(try #require(gate.current))
        #expect(!loader.cache.contains(mediaID: media.rawValue))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try store.expiredCleanup() == nil)
    }

    @Test func openingAnAttachmentAgainReusesItsPath() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let media = rig.h.server.addMedia(Data("hello pdf".utf8), contentType: "application/pdf", filename: "r.pdf")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let attachment = try #require(message.attachments.first)
        let loader = try rig.loader()

        let first = try await loader.export(attachment)
        let second = try await loader.export(attachment)
        #expect(first == second)
        #expect(try Data(contentsOf: second) == Data("hello pdf".utf8))
        let unique = try await loader.export(attachment, placement: .unique)
        #expect(unique != first)
    }

    @MainActor @Test func theFileWorkOfAnExportRunsOffTheMainActor() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let media = rig.h.server.addMedia(Data("hello pdf".utf8), contentType: "application/pdf", filename: "r.pdf")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let loader = try rig.loader()
        let onMain = Recorder<Bool>()
        loader.beforeExportWrite = { onMain.append(Thread.isMainThread) }

        _ = try await loader.export(try #require(message.attachments.first))
        #expect(onMain.all == [false])
    }

    @Test func aCallWhoseSessionEndedLeavesTheStoredCopyAlone() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let media = rig.h.server.addMedia(Data("hello pdf".utf8), contentType: "application/pdf", filename: "r.pdf")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let attachment = try #require(message.attachments.first)
        let loader = try rig.loader()
        let stored = try await loader.export(attachment)
        let gate = rig.h.gate
        loader.afterExportWrite = { gate.retire() }

        await #expect(throws: MediaLoadError.retired) { _ = try await loader.export(attachment) }
        // Another session may be using it; logout's wipe is what removes it.
        #expect(try Data(contentsOf: stored) == Data("hello pdf".utf8))
    }

    @Test func makingACopyRemovesThisAccountsOldCopies() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let account = AccountID()
        let directory = AccountDirectory(root: rig.root, account: account)
        try directory.createExports()
        // A copy nobody has touched for two days, from before this run.
        let old = directory.exportsURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        let oldFile = old.appendingPathComponent("old.pdf")
        try Data("old".utf8).write(to: oldFile)
        let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: oldFile.path)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: old.path)
        let media = rig.h.server.addMedia(Data("hello pdf".utf8), contentType: "application/pdf", filename: "r.pdf")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let loader = try rig.loader(account: account)
        let swept = MediaSignals<Int>()
        loader.afterSweepRequest = { swept.record(1) }

        let url = try await loader.export(try #require(message.attachments.first))
        try await swept.wait { !$0.isEmpty }
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
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
        let exports = rig.root.appending(path: "exports")
        let written = Recorder<Bool>()
        // Logout starts once the copy is written, as it's about to be handed out.
        loader.afterExportWrite = {
            let files = FileManager.default.enumerator(atPath: exports.path)?.compactMap { $0 as? String } ?? []
            written.append(files.contains { $0.hasSuffix("s.pdf") })
            gate.retire()
        }

        await #expect(throws: MediaLoadError.retired) {
            _ = try await loader.export(try #require(message.attachments.first))
        }
        #expect(written.all == [true])
        let left =
            FileManager.default.enumerator(atPath: rig.root.appending(path: "exports").path)?
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".pdf") || $0.hasSuffix(".partial") } ?? []
        #expect(left.isEmpty)
    }

    @Test func aSessionThatEndsAsTheExportComesBackIsNotOpened() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let media = rig.h.server.addMedia(Data("secret".utf8), contentType: "application/pdf", filename: "s.pdf")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let loader = try rig.loader()
        let gate = rig.h.gate
        // Logout starts after the file work handed back the copy, before the caller gets it.
        loader.beforeExportReturns = { gate.retire() }

        await #expect(throws: MediaLoadError.retired) {
            _ = try await loader.export(try #require(message.attachments.first))
        }
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

    /// A real logout with an export still running: it stops at the loader's close, and the eraser, as it starts on
    /// the exports, finds that close ended because the export did.
    @Test func logoutWaitsForARunningExportBeforeWiping() async throws {
        enum Step: Sendable, Equatable { case exportHeld, closeWaiting, release, wiping }
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let media = rig.h.server.addMedia(Data("secret".utf8), contentType: "application/pdf", filename: "s.pdf")
        let message = rig.h.server.postMedia([media], in: rig.team, from: .account(rig.h.bob))
        let attachment = try #require(message.attachments.first)
        let steps = MediaSignals<Step>()
        defer { steps.close() }
        let account = AccountID()
        let root = rig.root
        // The close never times out here: only the export ending lets logout past it.
        let loader = try rig.loader(account: account) { _ in
            steps.record(.closeWaiting)
            try await MediaSignals<Int>().wait { !$0.isEmpty }
        }
        loader.beforeExportReturns = {
            steps.record(.exportHeld)
            steps.block { $0.contains(.release) }
        }
        let eraser = WipeObserver(directory: AccountDirectory(root: root, account: account)) {
            steps.record(.wiping)
            return WipeObserver.Seen(
                closeOutcome: loader.exportCloseOutcome, exportsRunning: loader.exportsRunning,
                copies: Self.exportedPDFs(under: root).count)
        }
        let session = AccountSession(
            account: account, me: rig.h.alice.user.name, api: rig.client, store: rig.h.store,
            clock: ServerClock(server: rig.h.server),
            logoutRunner: LogoutRunner(eraser: eraser, tombstones: LogoutTombstones(root: root)), gate: rig.h.gate,
            mediaLoader: loader)

        let export = Task { await Self.exportResult(loader, attachment) }
        try await steps.wait(for: .exportHeld)
        #expect(Self.exportedPDFs(under: root).count == 1, "the export's file exists")

        let logout = Task { await session.logout(refreshToken: nil) }
        try await steps.wait { $0.contains(.closeWaiting) || $0.contains(.wiping) }
        // Logout is at the loader's close, behind the export, and hasn't started on the files.
        #expect(steps.all == [.exportHeld, .closeWaiting])
        #expect(loader.exportCloseWaiters == 1)
        #expect(loader.exportCloseOutcome == nil)

        steps.record(.release)
        let exported = try await finished(export)
        #expect(throws: MediaLoadError.retired) { try exported.get() }
        let report = try await finished(logout)
        #expect(!report.aborted && report.failedSteps.isEmpty)
        // What the eraser found as it entered the wipe: the close over, ended by the export, whose copy the wipe
        // then takes.
        #expect(eraser.seen.all == [WipeObserver.Seen(closeOutcome: .exportsEnded, exportsRunning: 0, copies: 1)])
        #expect(steps.all == [.exportHeld, .closeWaiting, .release, .wiping])
        #expect(Self.exportedPDFs(under: root).isEmpty)
    }

    static func exportedPDFs(under root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? [])
            .filter { $0.contains("exports/") && $0.hasSuffix(".pdf") }
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

/// Wipes an account's exports for real, as logout's eraser, and notes what it finds as the wipe starts.
private final class WipeObserver: AccountEraser {
    struct Seen: Sendable, Equatable {
        var closeOutcome: ExportGuard.CloseOutcome?
        var exportsRunning: Int
        /// Exported PDFs on disk.
        var copies: Int
    }

    let seen = Recorder<Seen>()
    private let directory: AccountDirectory
    private let look: @Sendable () -> Seen

    init(directory: AccountDirectory, look: @escaping @Sendable () -> Seen) {
        self.directory = directory
        self.look = look
    }

    func wipeExports(_ account: AccountID) throws {
        seen.append(look())
        try directory.wipeExports()
    }

    func removeNotifications(_ account: AccountID) async {}
    func shredStoreKey(_ account: AccountID) throws {}
    func deleteCredentials(_ account: AccountID) throws {}
    func deleteAccountFiles(_ account: AccountID) throws {}
    func unregister(_ account: AccountID) throws {}
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
    private let starts = MediaSignals<Int>()

    init(size: Int, bytes: Data, failures: [Int: ChatAPIError] = [:]) {
        self.size = size
        self.bytes = bytes
        self.failures = failures
    }

    /// The size limit of each download, in the order they started.
    var limits: [Int] { state.withLock { $0.limits } }

    /// Returns once `count` downloads have started; each is held from the moment it starts, unless released.
    func waitForDownloads(_ count: Int) async throws {
        try await starts.wait { $0.count >= count }
    }

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
            starts.record(maxBytes)
            if go { continuation.resume() }
        }
        if let failure = failures[maxBytes] { throw failure }
        guard size <= maxBytes else { throw .transport(.responseTooLarge) }
        do { try onChunk(bytes) } catch { throw .transport(.sinkFailed) }
        return MediaDownload(byteCount: bytes.count)
    }
}

struct UploadAdmissionTests {
    @Test func admissionClosingDuringAnUploadStartsNoFurtherRequest() async throws {
        let rig = MediaFlowTests.Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let attachments = try (0..<2).map { index in
            let file = try rig.tempFile(Data("file \(index)".utf8), name: "f\(index).txt")
            return PendingAttachment(
                bookmark: PathFileAccess.bookmark(for: file), filename: "f\(index).txt", contentType: "text/plain",
                byteCount: 6)
        }
        let item = try rig.sends.enqueue(
            text: "two files", space: rig.team, thread: nil, attachments: attachments, rig.h.generation)
        let server = rig.h.server
        let uploads: @Sendable () -> Int = {
            server.requests.filter { $0.path.contains(":upload") || $0.path.hasPrefix("/upload/") }.count
        }

        let outcomes = try #require(try await rig.sends.drain(rig.team, rig.h.generation) { uploads() == 0 })

        #expect(outcomes[item.id] == .notAdmitted)
        #expect(uploads() == 1)
        #expect(server.messages(in: rig.team).isEmpty)
        let held = try #require(try rig.h.store.outbox().first)
        #expect(held.state == .queued && held.attempts == 0)
        #expect(held.payload.attachments.first?.uploadToken != nil, "the finished upload is kept")
        #expect(held.payload.attachments.last?.uploadToken == nil)
    }
}

/// A close timer in the test's hands: it reports when it starts and when it is cancelled, and runs out only when
/// the test says so.
private struct HandTimer: Sendable {
    enum Event: Sendable, Hashable {
        case started(Duration)
        case cancelled(Duration)
        case ranOut(Duration)
    }

    let log = MediaSignals<Event>()
    private let expired = MediaSignals<Duration>()

    func runOut(_ timeout: Duration) { expired.record(timeout) }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [log, expired] timeout in
            try await withTaskCancellationHandler {
                log.record(.started(timeout))
                try await expired.wait(for: timeout)
                log.record(.ranOut(timeout))
            } onCancel: {
                log.record(.cancelled(timeout))
            }
        }
    }
}

/// `ExportGuard.closeAndWait`: how a close ends, what it leaves registered, and what keeps the guard alive.
@Suite(.timeLimit(.minutes(1))) struct ExportCloseTests {
    private typealias Outcome = ExportGuard.CloseOutcome

    @Test func aCloseWithNoExportRunningEndsAtOnceAndRefusesNewExports() async throws {
        let exports = ExportGuard(sleep: HandTimer().sleep)
        let close = Task { await exports.closeAndWait(timeout: .seconds(1)) }

        #expect(try await finished(close) == .exportsEnded)
        #expect(exports.closeOutcome == .exportsEnded)
        #expect(exports.waiterCount == 0)
        #expect(!exports.begin { true })
    }

    @Test func aCloseEndsWithTheLastExportAndCancelsItsTimer() async throws {
        let timer = HandTimer()
        let exports = ExportGuard(sleep: timer.sleep)
        #expect(exports.begin { true })
        #expect(exports.begin { true })
        let close = Task { await exports.closeAndWait(timeout: .seconds(1)) }
        try await timer.log.wait(for: .started(.seconds(1)))

        exports.end()
        // One export is still running, so the close is still waiting.
        try #require(exports.waiterCount == 1)
        #expect(exports.closeOutcome == nil)
        exports.end()
        #expect(try await finished(close) == .exportsEnded)
        // Cancelled by the export's `end` itself, before it answered the close.
        #expect(timer.log.all == [.started(.seconds(1)), .cancelled(.seconds(1))])
        #expect(exports.waiterCount == 0)
        #expect(exports.closeOutcome == .exportsEnded)
    }

    @Test func aCloseThatTimesOutLeavesNoWaiterForTheExportToAnswerLater() async throws {
        let timer = HandTimer()
        let exports = ExportGuard(sleep: timer.sleep)
        #expect(exports.begin { true })
        let close = Task { await exports.closeAndWait(timeout: .seconds(1)) }
        try await timer.log.wait(for: .started(.seconds(1)))

        timer.runOut(.seconds(1))
        #expect(try await finished(close) == .timedOut)
        try #require(exports.waiterCount == 0)
        #expect(exports.closeOutcome == .timedOut)
        // The export ends after the close gave up on it: there is nobody left to answer.
        exports.end()
        #expect(exports.closeOutcome == .timedOut)
        #expect(exports.activeCount == 0)
        let again = Task { await exports.closeAndWait(timeout: .seconds(2)) }
        #expect(try await finished(again) == .exportsEnded)
    }

    /// The timer is started in the step that registers the close, so however soon it runs out it finds its waiter.
    @Test func aTimeoutThatRunsOutAsSoonAsItStartsStillEndsItsClose() async throws {
        let exports = ExportGuard(sleep: { _ in })
        #expect(exports.begin { true })
        let close = Task { await exports.closeAndWait(timeout: .seconds(1)) }

        #expect(try await finished(close) == .timedOut)
        #expect(exports.waiterCount == 0)
        #expect(exports.closeOutcome == .timedOut)
    }

    @Test func overlappingClosesEachGetTheirOwnAnswer() async throws {
        let timer = HandTimer()
        let exports = ExportGuard(sleep: timer.sleep)
        #expect(exports.begin { true })
        let short = Task { await exports.closeAndWait(timeout: .seconds(1)) }
        try await timer.log.wait(for: .started(.seconds(1)))
        let long = Task { await exports.closeAndWait(timeout: .seconds(2)) }
        try await timer.log.wait(for: .started(.seconds(2)))
        #expect(exports.waiterCount == 2)

        timer.runOut(.seconds(1))
        #expect(try await finished(short) == .timedOut)
        // Only the caller whose time ran out stopped waiting.
        try #require(exports.waiterCount == 1)
        #expect(exports.closeOutcome == .timedOut)
        exports.end()
        #expect(try await finished(long) == .exportsEnded)
        #expect(exports.waiterCount == 0)
        #expect(exports.closeOutcome == .exportsEnded)
        #expect(
            timer.log.all == [
                .started(.seconds(1)), .started(.seconds(2)), .ranOut(.seconds(1)), .cancelled(.seconds(2)),
            ])
    }

    @Test func theLastExportEndingAnswersEveryWaitingClose() async throws {
        let timer = HandTimer()
        let exports = ExportGuard(sleep: timer.sleep)
        #expect(exports.begin { true })
        let first = Task { await exports.closeAndWait(timeout: .seconds(1)) }
        try await timer.log.wait(for: .started(.seconds(1)))
        let second = Task { await exports.closeAndWait(timeout: .seconds(2)) }
        try await timer.log.wait(for: .started(.seconds(2)))

        exports.end()
        // Both timers are cancelled by the time `end` returns.
        try #require(Set(timer.log.all.dropFirst(2)) == [.cancelled(.seconds(1)), .cancelled(.seconds(2))])
        #expect(try await finished(first) == .exportsEnded)
        #expect(try await finished(second) == .exportsEnded)
        #expect(exports.waiterCount == 0)
    }

    /// The timer here goes on running after it is cancelled, so anything it held would still be held.
    @Test func nothingKeepsTheGuardAliveAfterACloseTheExportsEnded() async throws {
        let timer = MediaSignals<String>()
        defer { timer.close() }
        let holder = Mutex<ExportGuard?>(
            ExportGuard(sleep: { _ in
                timer.record("started")
                await timer.hold { $0.contains("let go") }
                try Task.checkCancellation()
            }))
        weak var guarded = holder.withLock { $0 }
        #expect(holder.withLock { $0?.begin(isCurrent: { true }) } == true)
        let close = Task { () -> Outcome? in
            guard let exports = holder.withLock({ $0 }) else { return nil }
            return await exports.closeAndWait(timeout: .seconds(1))
        }
        try await timer.wait(for: "started")
        holder.withLock { $0?.end() }
        #expect(try await finished(close) == .exportsEnded)

        holder.withLock { $0 = nil }
        #expect(guarded == nil)
    }

    @Test func nothingKeepsTheGuardAliveAfterACloseThatTimedOut() async throws {
        let holder = Mutex<ExportGuard?>(ExportGuard(sleep: { _ in }))
        weak var guarded = holder.withLock { $0 }
        #expect(holder.withLock { $0?.begin(isCurrent: { true }) } == true)
        let close = Task { () -> Outcome? in
            guard let exports = holder.withLock({ $0 }) else { return nil }
            return await exports.closeAndWait(timeout: .seconds(1))
        }
        #expect(try await finished(close) == .timedOut)

        // The export is still running and never answers; no waiter is left that could hold the guard for it.
        holder.withLock { $0 = nil }
        #expect(guarded == nil)
    }
}
