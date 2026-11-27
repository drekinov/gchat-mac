import ChatModel
import ChatNet
import ChatStore
import CoreGraphics
import Foundation
import GoogleChat
import Synchronization

public enum MediaLoadError: Error, Sendable, Equatable {
    case api(ChatAPIError)
    case cache(MediaCacheError)
    case image(ImageError)
    case transport(TransportError)
    case export(ExportError)
    case notUploadedContent
    case retired
}

extension MediaLoadError {
    /// The file can't be shown here however often it's loaded: it's too large, in a form the image pipeline
    /// refuses, or damaged. Retrying won't help, but another app may still open it.
    public var needsAnotherApp: Bool {
        switch self {
        case .image(.tooLarge), .image(.tooManyFrames), .image(.unsupported), .image(.corrupt),
            .transport(.responseTooLarge), .api(.transport(.responseTooLarge)):
            true
        default:
            false
        }
    }
}

/// Attachments for one account: cached encrypted on first use, decoded through the shared budget, and exported
/// (quarantined) for opening elsewhere. Cache commits go through the session gate.
public final class MediaLoader: Sendable {
    public static let maxFileBytes = 200 * 1024 * 1024
    public static let maxImageBytes = 20 * 1024 * 1024

    let media: any ChatMediaAPI
    let cache: MediaCache
    let exports: ExportDirectory
    let pipeline: ImagePipeline
    let fetcher: SafeFetcher
    let gate: SessionGate
    /// Removes this account's copies that haven't changed for `ExportDirectory.maxAge`, asked for after each export;
    /// a burst of exports costs at most two sweeps.
    let sweeper: ExportSweeper
    private let inflight = Mutex<[String: Download]>([:])
    private let exportHook = Mutex<(@Sendable () -> Void)?>(nil)
    private let returnHook = Mutex<(@Sendable () -> Void)?>(nil)
    private let exportsInFlight: ExportGuard

    /// A download one caller started and others may wait on, with the size limit it was started with.
    private struct Download: Sendable {
        let maxBytes: Int
        let task: Task<Void, any Error>
        let link: DownloadLink
    }

    /// What a running download shares with the callers waiting on it: the largest limit among them, and the
    /// larger attempt that took over if it stopped at its own limit.
    private final class DownloadLink: Sendable {
        private let state: Mutex<(wanted: Int, next: Download?)>

        init(wanted: Int) { state = Mutex((wanted, nil)) }

        var wanted: Int { state.withLock { $0.wanted } }
        var next: Download? { state.withLock { $0.next } }

        func want(_ limit: Int) { state.withLock { $0.wanted = max($0.wanted, limit) } }
        func hand(to next: Download) { state.withLock { $0.next = next } }
    }

    private let beforeHook = Mutex<(@Sendable () -> Void)?>(nil)
    private let waitHook = Mutex<(@Sendable () async -> Void)?>(nil)
    private let sweptHook = Mutex<(@Sendable () -> Void)?>(nil)
    private let settledHook = Mutex<(@Sendable (Int) -> Void)?>(nil)

    /// Test seam: runs, and is awaited, when a caller starts waiting on a download that another caller started.
    var onWaitForDownload: (@Sendable () async -> Void)? {
        get { waitHook.withLock { $0 } }
        set { waitHook.withLock { $0 = newValue } }
    }

    /// Test seam: runs with a download's size limit once it has finished and left the table, or handed its place
    /// in it to a larger attempt.
    var afterDownloadSettles: (@Sendable (Int) -> Void)? {
        get { settledHook.withLock { $0 } }
        set { settledHook.withLock { $0 = newValue } }
    }

    /// Test seam: the size limit of the download running for `resource`, if there is one.
    func runningDownloadLimit(_ resource: MediaResourceName) -> Int? {
        inflight.withLock { $0[resource.rawValue]?.maxBytes }
    }

    /// Test seam: runs once the file work has handed back a copy, before the session is checked one last time.
    var beforeExportReturns: (@Sendable () -> Void)? {
        get { returnHook.withLock { $0 } }
        set { returnHook.withLock { $0 = newValue } }
    }

    /// Test seam: how many `close` calls are waiting for running exports to finish.
    var exportCloseWaiters: Int { exportsInFlight.waiterCount }

    /// Test seam: how many exports are between registering and ending.
    var exportsRunning: Int { exportsInFlight.activeCount }

    /// Test seam: runs when the cleanup asked for after an export has been through the sweeper.
    var afterSweepRequest: (@Sendable () -> Void)? {
        get { sweptHook.withLock { $0 } }
        set { sweptHook.withLock { $0 = newValue } }
    }

    /// Test seam: why the latest `close` stopped waiting for exports.
    var exportCloseOutcome: ExportGuard.CloseOutcome? { exportsInFlight.closeOutcome }

    /// Test seam: runs after the export is registered and its reader opened, before any file is created.
    var beforeExportWrite: (@Sendable () -> Void)? {
        get { beforeHook.withLock { $0 } }
        set { beforeHook.withLock { $0 = newValue } }
    }

    /// Test seam: runs right before the session is checked for the last time, as a copy is about to be handed out.
    var afterExportWrite: (@Sendable () -> Void)? {
        get { exportHook.withLock { $0 } }
        set { exportHook.withLock { $0 = newValue } }
    }

    public convenience init(
        media: any ChatMediaAPI, cache: MediaCache, exports: ExportDirectory, pipeline: ImagePipeline,
        fetcher: SafeFetcher, gate: SessionGate
    ) {
        self.init(
            media: media, cache: cache, exports: exports, pipeline: pipeline, fetcher: fetcher, gate: gate,
            closeSleep: { try await Task.sleep(for: $0) })
    }

    /// `closeSleep` is how `close` waits out its timeout; it throws when its task is cancelled.
    init(
        media: any ChatMediaAPI, cache: MediaCache, exports: ExportDirectory, pipeline: ImagePipeline,
        fetcher: SafeFetcher, gate: SessionGate, closeSleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        exportsInFlight = ExportGuard(sleep: closeSleep)
        self.media = media
        self.cache = cache
        self.exports = exports
        self.pipeline = pipeline
        self.fetcher = fetcher
        self.gate = gate
        sweeper = ExportSweeper {
            try? exports.prune(changedBefore: Date().addingTimeInterval(-ExportDirectory.maxAge))
        }
    }

    /// A display-size image for an uploaded attachment.
    public func image(_ attachment: Attachment, maxPixelSize: Int) async throws(MediaLoadError) -> DecodedImage {
        let resource = try uploaded(attachment)
        try await ensureCached(resource, contentType: attachment.contentType, maxBytes: Self.maxImageBytes)
        // The encoded bytes are admitted against the budget before they're read into memory.
        let size = try encodedSize(resource)
        let admission: EncodedAdmission
        do { admission = try await pipeline.reserveEncoded(byteCount: size) } catch { throw .image(error) }
        let data = try read(resource)
        do {
            return try await pipeline.thumbnail(from: data, admission: admission, maxPixelSize: maxPixelSize)
        } catch {
            throw .image(error)
        }
    }

    func encodedSize(_ resource: MediaResourceName) throws(MediaLoadError) -> Int {
        let reader: MediaReader?
        do { reader = try cache.open(mediaID: resource.rawValue) } catch { throw .cache(error) }
        guard let reader else { throw .cache(.closed) }
        defer { reader.close() }
        return reader.plaintextBytes
    }

    /// GIFs and custom emoji images live on token-less hosts; they go through `SafeFetcher` and aren't cached on disk.
    public func animation(at url: URL, maxPixelSize: Int) async throws(MediaLoadError) -> AnimatedImage {
        // Reserved before the fetch, so concurrent GIFs can't hold unbudgeted buffers; shrunk to what arrived.
        let admission: EncodedAdmission
        do { admission = try await pipeline.reserveEncoded(byteCount: Self.maxImageBytes) } catch {
            throw .image(error)
        }
        let data: Data
        do { data = try await fetcher.fetch(url, maxBytes: Self.maxImageBytes, admission: admission).0 } catch {
            throw .transport(error)
        }
        do { return try await pipeline.animation(from: data, admission: admission, maxPixelSize: maxPixelSize) } catch {
            throw .image(error)
        }
    }

    public static let maxAvatarBytes = 256 * 1024
    static let avatarAdmissionWait: Duration = .seconds(5)

    /// A small still image (a profile photo) from a token-less host; not cached on disk.
    public func avatar(at url: URL, maxPixelSize: Int) async throws(MediaLoadError) -> DecodedImage {
        let admission: EncodedAdmission
        do {
            admission = try await pipeline.reserveEncoded(
                byteCount: Self.maxAvatarBytes, timeout: Self.avatarAdmissionWait)
        } catch {
            throw .image(error)
        }
        let data: Data
        do { data = try await fetcher.fetch(url, maxBytes: Self.maxAvatarBytes, admission: admission).0 } catch {
            throw .transport(error)
        }
        do { return try await pipeline.thumbnail(from: data, admission: admission, maxPixelSize: maxPixelSize) } catch {
            throw .image(error)
        }
    }

    /// Decrypts into the account's quarantined exports directory for opening in another app. By default an
    /// attachment keeps one copy, which a later export hands back instead of writing another; `.unique` is for a
    /// caller that deletes its copy right away. A copy is handed out only while the session is current, checked at
    /// the last moment, so plaintext never outlives logout's wipe and a retired call never touches a copy another
    /// session may be using.
    public func export(
        _ attachment: Attachment, placement: ExportDirectory.Placement = .shared
    ) async throws(MediaLoadError) -> URL {
        guard let generation = gate.current else { throw .retired }
        let resource = try uploaded(attachment)
        try await ensureCached(resource, contentType: attachment.contentType, maxBytes: Self.maxFileBytes)
        // Registered before any plaintext exists; `close` refuses new exports and waits for this one, so logout's
        // wipe always runs after it.
        guard exportsInFlight.begin(isCurrent: { gate.isCurrent(generation) }) else { throw .retired }
        defer { exportsInFlight.end() }
        let url = try await writeExport(resource, attachment, placement, generation)
        // The session may have ended while this call came back from the file work; the copy is then left for
        // logout's wipe rather than opened.
        beforeExportReturns?()
        guard gate.isCurrent(generation) else { throw .retired }
        Task {
            await sweeper.request()
            afterSweepRequest?()
        }
        return url
    }

    /// The file work, off the caller's actor: Open runs on the main actor, and this can wait for pruning to let go
    /// of the export tree.
    @concurrent
    private func writeExport(
        _ resource: MediaResourceName, _ attachment: Attachment, _ placement: ExportDirectory.Placement,
        _ generation: Generation
    ) async throws(MediaLoadError) -> URL {
        let reader: MediaReader?
        do { reader = try cache.open(mediaID: resource.rawValue) } catch { throw .cache(error) }
        guard let reader else { throw .cache(.closed) }
        defer { reader.close() }
        beforeExportWrite?()
        do {
            return try exports.export(from: reader, filename: attachment.contentName, placement: placement) { stage in
                if stage == .handingOut { afterExportWrite?() }
                return gate.isCurrent(generation)
            }
        } catch .withdrawn {
            throw .retired
        } catch {
            throw .export(error)
        }
    }

    /// Streams the decrypted file to a user-chosen location ("Save As…").
    public func save(_ attachment: Attachment, to destination: URL) async throws(MediaLoadError) {
        let resource = try uploaded(attachment)
        try await ensureCached(resource, contentType: attachment.contentType, maxBytes: Self.maxFileBytes)
        let reader: MediaReader?
        do { reader = try cache.open(mediaID: resource.rawValue) } catch { throw .cache(error) }
        guard let reader else { throw .cache(.closed) }
        defer { reader.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: destination)
        else { throw .export(.io(code: 0)) }
        defer { try? handle.close() }
        do {
            while let chunk = try reader.next() { try handle.write(contentsOf: chunk) }
        } catch let error as MediaCacheError {
            try? FileManager.default.removeItem(at: destination)
            throw .cache(error)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw .export(.io(code: 0))
        }
    }

    /// Removes the cached and shared exported copies of `mediaIDs`, off the caller's actor. False when some couldn't be
    /// removed now, so the caller keeps them for a later attempt.
    public func forget(_ mediaIDs: [String]) async -> Bool {
        guard !mediaIDs.isEmpty else { return true }
        return await Self.forget(mediaIDs, cache: cache, exports: exports)
    }

    @concurrent
    private static func forget(_ mediaIDs: [String], cache: MediaCache, exports: ExportDirectory) async -> Bool {
        var complete = true
        for id in mediaIDs {
            do throws(MediaCacheError) { try cache.remove(mediaID: id) } catch { complete = false }
        }
        do throws(ExportError) {
            try exports.remove(folders: mediaIDs.map { cache.keyedName(mediaID: $0) })
        } catch {
            complete = false
        }
        return complete
    }

    /// Refuses new exports, waits (bounded) for running ones, then closes the cache. Logout calls this before it
    /// wipes exports; an export still running after the timeout deletes its own file when it sees the retired session.
    public func close(waitingUpTo timeout: Duration = .seconds(10)) async {
        await exportsInFlight.closeAndWait(timeout: timeout)
        cache.close()
    }

    func uploaded(_ attachment: Attachment) throws(MediaLoadError) -> MediaResourceName {
        guard case .uploaded(let resource) = attachment.source else { throw .notUploadedContent }
        return resource
    }

    func read(_ resource: MediaResourceName) throws(MediaLoadError) -> Data {
        let reader: MediaReader?
        do { reader = try cache.open(mediaID: resource.rawValue) } catch { throw .cache(error) }
        guard let reader else { throw .cache(.closed) }
        defer { reader.close() }
        var data = Data()
        data.reserveCapacity(reader.plaintextBytes)
        do {
            while let chunk = try reader.next() { data.append(chunk) }
        } catch {
            throw .cache(error)
        }
        return data
    }

    /// Downloads once even when several views ask at the same time. A caller that allows a larger file than the
    /// download already running waits for it; if that download stops at its smaller limit, a larger attempt takes
    /// over and the caller waits for that one, so an export never fails with a thumbnail's size limit.
    func ensureCached(
        _ resource: MediaResourceName, contentType: String, maxBytes: Int
    ) async throws(MediaLoadError) {
        guard let generation = gate.current else { throw .retired }
        let key = resource.rawValue
        if cache.contains(mediaID: key) { return }
        let joined = inflight.withLock { running -> (download: Download, started: Bool)? in
            if let existing = running[key] {
                existing.link.want(maxBytes)
                return (existing, false)
            }
            // A download can commit and leave the table between the check above and this lock. It commits before
            // it leaves, so looking again here never starts a second download of a cached file.
            if cache.contains(mediaID: key) { return nil }
            let download = startDownload(resource, contentType: contentType, maxBytes: maxBytes, generation)
            running[key] = download
            return (download, true)
        }
        guard var (download, started) = joined else { return }
        while true {
            if !started { await onWaitForDownload?() }
            switch await download.task.result {
            case .success:
                return
            case .failure(let error as MediaLoadError):
                // Stopped at a limit smaller than this caller's. The larger attempt that took over is followed
                // directly, so its result arrives here even if it has already finished and left the table.
                guard error == .api(.transport(.responseTooLarge)), download.maxBytes < maxBytes else { throw error }
                guard let next = download.link.next else { throw gate.isCurrent(generation) ? error : .retired }
                download = next
                started = false
            case .failure:
                throw .retired
            }
        }
    }

    /// Starts a download for the caller to put in the table while still holding `inflight`. The download leaves
    /// the table itself as it finishes, so nobody joins a finished one. If it stops at its limit while a caller
    /// waiting on it allows more, a larger attempt takes its place in the same step, so nothing smaller can start
    /// in between.
    private func startDownload(
        _ resource: MediaResourceName, contentType: String, maxBytes: Int, _ generation: Generation
    ) -> Download {
        let key = resource.rawValue
        let link = DownloadLink(wanted: maxBytes)
        let task = Task { [self] in
            var failure: MediaLoadError?
            do throws(MediaLoadError) {
                try await self.download(resource, contentType: contentType, maxBytes: maxBytes, generation)
            } catch {
                failure = error
            }
            inflight.withLock { running in
                guard running[key]?.link === link else { return }
                let wanted = link.wanted
                if failure == .api(.transport(.responseTooLarge)), wanted > maxBytes, gate.isCurrent(generation) {
                    let next = startDownload(resource, contentType: contentType, maxBytes: wanted, generation)
                    link.hand(to: next)
                    running[key] = next
                } else {
                    running[key] = nil
                }
            }
            afterDownloadSettles?(maxBytes)
            if let failure { throw failure }
        }
        return Download(maxBytes: maxBytes, task: task, link: link)
    }

    func download(
        _ resource: MediaResourceName, contentType: String, maxBytes: Int, _ generation: Generation
    ) async throws(MediaLoadError) {
        let writer: MediaWriter
        do { writer = try cache.beginWrite(mediaID: resource.rawValue, contentType: contentType) } catch {
            throw .cache(error)
        }
        let result: MediaDownload
        do throws(ChatAPIError) {
            result = try await media.downloadMedia(resource, maxBytes: maxBytes) { chunk in try writer.append(chunk) }
        } catch {
            writer.abort()
            throw .api(error)
        }
        if let redirect = result.redirect {
            // The redirected copy is fetched without credentials; SafeFetcher's host allowlist decides if it's allowed.
            let cap = min(maxBytes, Self.maxImageBytes)
            let admission: EncodedAdmission
            do { admission = try await pipeline.reserveEncoded(byteCount: cap) } catch {
                writer.abort()
                throw .image(error)
            }
            let data: Data
            do { data = try await fetcher.fetch(redirect, maxBytes: cap, admission: admission).0 } catch {
                writer.abort()
                throw .transport(error)
            }
            do { try writer.append(data) } catch {
                writer.abort()
                throw .cache(error)
            }
        }
        do {
            try gate.commit(generation) { () throws(MediaCacheError) in try writer.commit() }
        } catch is GateClosed {
            writer.abort()
            throw .retired
        } catch let error as MediaCacheError {
            throw .cache(error)
        } catch {
            throw .retired
        }
    }
}

final class ExportGuard: Sendable {
    enum CloseOutcome: Sendable, Equatable {
        /// No export was running, or the last one ended.
        case exportsEnded
        case timedOut
    }

    /// A `closeAndWait` call that is waiting, and the timer that ends its wait.
    private struct Waiter {
        let continuation: CheckedContinuation<CloseOutcome, Never>
        let timer: Task<Void, Never>
    }

    private struct State {
        var active = 0
        var closed = false
        var lastWaiter = 0
        var waiters: [Int: Waiter] = [:]
        var closeOutcome: CloseOutcome?
    }

    private let state = Mutex(State())
    private let sleep: @Sendable (Duration) async throws -> Void

    /// `sleep` is how a close waits out its timeout; it throws when its task is cancelled.
    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// `isCurrent` is evaluated under the lock, so a closed guard or retired session never admits a new export.
    func begin(isCurrent: () -> Bool) -> Bool {
        state.withLock { state in
            guard !state.closed, isCurrent() else { return false }
            state.active += 1
            return true
        }
    }

    func end() {
        let waiters = state.withLock { state -> [Waiter] in
            state.active -= 1
            guard state.active == 0, !state.waiters.isEmpty else { return [] }
            state.closeOutcome = .exportsEnded
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters {
            waiter.timer.cancel()
            waiter.continuation.resume(returning: .exportsEnded)
        }
    }

    var activeCount: Int { state.withLock { $0.active } }
    var waiterCount: Int { state.withLock { $0.waiters.count } }
    var closeOutcome: CloseOutcome? { state.withLock { $0.closeOutcome } }

    /// Refuses new exports and waits until the running ones have ended or `timeout` has passed, whichever comes
    /// first. Each call waits on its own: the last export ending answers every waiting call, a timeout only its own.
    @discardableResult
    func closeAndWait(timeout: Duration) async -> CloseOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<CloseOutcome, Never>) in
            let idle = state.withLock { state -> Bool in
                state.closed = true
                guard state.active > 0 else {
                    state.closeOutcome = .exportsEnded
                    return true
                }
                state.lastWaiter += 1
                let id = state.lastWaiter
                // Started under the lock that registers the waiter, so whoever claims the waiter has its timer too.
                // The guard is held only weakly: neither a waiter nor its timer keeps it alive.
                let timer = Task { [weak self, sleep] in
                    do { try await sleep(timeout) } catch { return }
                    let expired = self?.expire(id)
                    expired?.resume(returning: .timedOut)
                }
                state.waiters[id] = Waiter(continuation: continuation, timer: timer)
                return false
            }
            if idle { continuation.resume(returning: .exportsEnded) }
        }
    }

    /// Takes the waiter out when its timeout comes first; nil when the exports ended before it.
    private func expire(_ id: Int) -> CheckedContinuation<CloseOutcome, Never>? {
        state.withLock { state in
            guard let waiter = state.waiters.removeValue(forKey: id) else { return nil }
            state.closeOutcome = .timedOut
            return waiter.continuation
        }
    }
}
