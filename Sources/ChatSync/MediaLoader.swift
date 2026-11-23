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
    private let inflight = Mutex<[String: Task<Void, any Error>]>([:])
    private let exportHook = Mutex<(@Sendable () -> Void)?>(nil)
    private let exportsInFlight = ExportGuard()

    private let beforeHook = Mutex<(@Sendable () -> Void)?>(nil)

    /// Test seam: runs after the export is registered and its reader opened, before any file is created.
    var beforeExportWrite: (@Sendable () -> Void)? {
        get { beforeHook.withLock { $0 } }
        set { beforeHook.withLock { $0 = newValue } }
    }

    /// Test seam: runs between writing an export and re-checking the session.
    var afterExportWrite: (@Sendable () -> Void)? {
        get { exportHook.withLock { $0 } }
        set { exportHook.withLock { $0 = newValue } }
    }

    public init(
        media: any ChatMediaAPI, cache: MediaCache, exports: ExportDirectory, pipeline: ImagePipeline,
        fetcher: SafeFetcher, gate: SessionGate
    ) {
        self.media = media
        self.cache = cache
        self.exports = exports
        self.pipeline = pipeline
        self.fetcher = fetcher
        self.gate = gate
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

    /// Decrypts into the account's quarantined exports directory for opening in another app. If the session is
    /// retired while the file is written, the file is removed again: plaintext never outlives logout's wipe.
    public func export(_ attachment: Attachment) async throws(MediaLoadError) -> URL {
        guard let generation = gate.current else { throw .retired }
        let resource = try uploaded(attachment)
        try await ensureCached(resource, contentType: attachment.contentType, maxBytes: Self.maxFileBytes)
        // Registered before any plaintext exists; `close` refuses new exports and waits for this one, so logout's
        // wipe always runs after it.
        guard exportsInFlight.begin(isCurrent: { gate.isCurrent(generation) }) else { throw .retired }
        defer { exportsInFlight.end() }
        let reader: MediaReader?
        do { reader = try cache.open(mediaID: resource.rawValue) } catch { throw .cache(error) }
        guard let reader else { throw .cache(.closed) }
        defer { reader.close() }
        beforeExportWrite?()
        let url: URL
        do { url = try exports.export(from: reader, filename: attachment.contentName) } catch { throw .export(error) }
        afterExportWrite?()
        guard gate.isCurrent(generation) else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw .retired
        }
        return url
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

    /// Downloads once even when several views ask at the same time.
    func ensureCached(
        _ resource: MediaResourceName, contentType: String, maxBytes: Int
    ) async throws(MediaLoadError) {
        guard let generation = gate.current else { throw .retired }
        if cache.contains(mediaID: resource.rawValue) { return }
        let key = resource.rawValue
        let task = inflight.withLock { running -> Task<Void, any Error> in
            if let existing = running[key] { return existing }
            let task = Task { [self] in
                try await self.download(resource, contentType: contentType, maxBytes: maxBytes, generation)
            }
            running[key] = task
            return task
        }
        defer { inflight.withLock { if $0[key] == task { $0[key] = nil } } }
        do {
            try await task.value
        } catch let error as MediaLoadError {
            throw error
        } catch {
            throw .retired
        }
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
    private struct State {
        var active = 0
        var closed = false
        var waiters: [@Sendable () -> Void] = []
    }

    private let state = Mutex(State())

    /// `isCurrent` is evaluated under the lock, so a closed guard or retired session never admits a new export.
    func begin(isCurrent: () -> Bool) -> Bool {
        state.withLock { state in
            guard !state.closed, isCurrent() else { return false }
            state.active += 1
            return true
        }
    }

    func end() {
        let waiters = state.withLock { state -> [@Sendable () -> Void] in
            state.active -= 1
            guard state.active == 0 else { return [] }
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter() }
    }

    func closeAndWait(timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            let resume: @Sendable () -> Void = { if once.claim() { continuation.resume() } }
            let idle = state.withLock { state -> Bool in
                state.closed = true
                guard state.active > 0 else { return true }
                state.waiters.append(resume)
                return false
            }
            if idle { return resume() }
            Task {
                try? await Task.sleep(for: timeout)
                resume()
            }
        }
    }
}
