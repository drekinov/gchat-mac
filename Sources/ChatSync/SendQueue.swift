import ChatModel
import ChatStore
import Foundation
import GoogleChat
import Synchronization

public enum SendOutcome: Sendable, Equatable {
    case sent(MessageName)
    case willRetry(at: Timestamp)
    case failed(reason: String)
    case needsLogin
    case retired
    /// The request never left the device; the item keeps its state and attempt count.
    case offline
    /// Admission closed before the request was sent; the item keeps its state.
    case notAdmitted
}

/// Durable sends. One serialized queue per space, writes at least `spacing` apart (1 write/s per space), and the
/// same `requestID` on every attempt, so a lost response resolves to the original message instead of a duplicate.
public final class SendQueue: Sendable {
    public static let spacing = Duration.seconds(1)

    let api: any ChatAPI
    let media: (any ChatMediaAPI)?
    let files: any FileAccess
    let store: any AccountStore
    let gate: SessionGate
    let clock: any SyncClock
    let backoff = Backoff()
    private let lastWrite = Mutex<[SpaceName: Timestamp]>([:])
    private let drains = DrainLock()
    private let lastCreated = Mutex<Timestamp?>(nil)

    /// Strictly increasing, so items enqueued in the same clock instant keep their order.
    func nextCreated() -> Timestamp {
        let now = clock.now()
        return lastCreated.withLock { last in
            let created = last.map { now > $0 ? now : $0.adding(.nanoseconds(1)) } ?? now
            last = created
            return created
        }
    }

    public init(
        api: any ChatAPI, store: any AccountStore, gate: SessionGate, clock: any SyncClock,
        media: (any ChatMediaAPI)? = nil, files: any FileAccess = SecurityScopedFileAccess()
    ) {
        self.api = api
        self.media = media
        self.files = files
        self.store = store
        self.gate = gate
        self.clock = clock
    }

    /// Persists the send and clears the composer's draft in the same commit.
    public func enqueue(
        text: String, space: SpaceName, thread: ThreadName?, attachments: [PendingAttachment] = [],
        _ generation: Generation
    ) throws(SyncError) -> OutboxItem {
        let item = OutboxItem(
            space: space, payload: OutboxPayload(text: text, thread: thread, attachments: attachments),
            created: nextCreated())
        let draftKey = Draft(space: space, thread: thread, text: "", updated: item.created).key
        do {
            try store.write(gate: gate, generation: generation) { batch in
                batch.append(.putOutbox(item))
                batch.append(.deleteDraft(key: draftKey))
            }
        } catch .gateClosed {
            throw .retired
        } catch {
            throw .store(error)
        }
        return item
    }

    /// Items left `sending` by a crash may have reached the server, so they become `unknown`.
    public func recoverInterrupted(_ generation: Generation) throws(SyncError) {
        let items = try outbox()
        let interrupted = items.filter { $0.state == .sending }
        guard !interrupted.isEmpty else { return }
        try commit(generation) { batch in
            for var item in interrupted {
                item.state = .unknown
                batch.append(.putOutbox(item))
            }
        }
    }

    public typealias Admission = @Sendable () async -> Bool

    /// Sends due items of `space` in creation order. Stops at the first item that must wait, so order is kept.
    /// Returns the outcome per attempted item; `nil` when another drain of the space is running, in which case
    /// that drain runs another pass before it finishes, so nothing enqueued meanwhile is left behind.
    /// `admit` is checked before every outgoing request.
    public func drain(
        _ space: SpaceName, _ generation: Generation, admit: @escaping Admission = { true }
    ) async throws(SyncError) -> [UUID: SendOutcome]? {
        guard drains.begin(space) else { return nil }
        var outcomes: [UUID: SendOutcome] = [:]
        repeat {
            do {
                outcomes.merge(try await drainOnce(space, generation, admit)) { _, new in new }
            } catch {
                drains.release(space)
                throw error
            }
        } while drains.continueOrRelease(space)
        return outcomes
    }

    func drainOnce(
        _ space: SpaceName, _ generation: Generation, _ admit: Admission
    ) async throws(SyncError) -> [UUID: SendOutcome] {
        var outcomes: [UUID: SendOutcome] = [:]
        let items = try outbox().filter { $0.space == space }.sorted { $0.created < $1.created }
        for item in items {
            guard case .committed(let name) = item.state else { continue }
            guard await admit() else {
                outcomes[item.id] = .notAdmitted
                return outcomes
            }
            try await hydrate(item, name, generation)
        }
        for item in items where !item.state.isTerminal {
            if let next = item.nextAttempt, next > clock.now() {
                outcomes[item.id] = .willRetry(at: next)
                break
            }
            guard await admit() else {
                outcomes[item.id] = .notAdmitted
                break
            }
            let outcome = try await send(item, generation, admit)
            outcomes[item.id] = outcome
            if case .sent = outcome { continue }
            if case .failed = outcome { continue }
            break
        }
        return outcomes
    }

    func send(_ original: OutboxItem, _ generation: Generation, _ admit: Admission) async throws(SyncError)
        -> SendOutcome
    {
        var item = original
        item.attempts += 1
        if item.state == .queued { item.state = .sending }
        let sending = item
        try commit(generation) { $0.append(.putOutbox(sending)) }

        if item.payload.allUploadTokens == nil {
            switch try await upload(&item, original, generation, admit) {
            case .done: break
            case .stop(let outcome): return outcome
            }
        }
        try await pace(item.space)
        guard await admit() else { return try unclaim(item, original, .notAdmitted, generation) }
        let request = NewMessage(
            space: item.space, text: item.payload.text, reply: item.payload.thread.map { .thread($0) } ?? .newThread,
            requestID: item.requestID, attachmentUploadTokens: item.payload.allUploadTokens ?? [])
        let created: CreatedMessage
        do throws(ChatAPIError) {
            created = try await api.createMessage(request)
        } catch {
            markWrite(item.space)
            return try handle(error, for: item, generation)
        }
        markWrite(item.space)
        if let message = created.message {
            try commit(generation) { batch in
                batch.append(.upsertMessages([message]))
                batch.append(.deleteOutbox(item.id))
            }
        } else {
            var committed = item
            committed.state = .committed(created.name)
            committed.nextAttempt = nil
            let durable = committed
            try commit(generation) { $0.append(.putOutbox(durable)) }
            try await hydrate(durable, created.name, generation)
        }
        return .sent(created.name)
    }

    enum UploadResult {
        case done
        case stop(SendOutcome)
    }

    /// Uploads attachments that have no token yet, saving each token as soon as it arrives. Uploads aren't
    /// idempotent, but an orphaned upload is harmless, so an unknown outcome simply uploads again later.
    func upload(
        _ item: inout OutboxItem, _ original: OutboxItem, _ generation: Generation, _ admit: Admission
    ) async throws(SyncError) -> UploadResult {
        guard let media else { return .stop(try fail(item, reason: "attachmentsUnsupported", generation)) }
        for index in item.payload.attachments.indices where item.payload.attachments[index].uploadToken == nil {
            let attachment = item.payload.attachments[index]
            try await pace(item.space)
            guard await admit() else { return .stop(try unclaim(item, original, .notAdmitted, generation)) }
            let result: Result<UploadedAttachment, ChatAPIError>
            do {
                result = try await files.withFile(attachment.bookmark) { url in
                    do throws(ChatAPIError) {
                        return .success(
                            try await media.uploadAttachment(
                                to: item.space, file: url, filename: attachment.filename,
                                contentType: attachment.contentType))
                    } catch {
                        return .failure(error)
                    }
                }
            } catch {
                return .stop(try fail(item, reason: "fileUnavailable", generation))
            }
            markWrite(item.space)
            switch result {
            case .success(let uploaded):
                item.payload.attachments[index].uploadToken = uploaded.uploadToken
                let saved = item
                try commit(generation) { $0.append(.putOutbox(saved)) }
            case .failure(.transport(.offline)):
                return .stop(try unclaim(item, original, .offline, generation))
            case .failure(.transport(.requestBodyUnavailable)):
                return .stop(try fail(item, reason: "fileUnavailable", generation))
            case .failure(.invalidArgument(let info)) where info.status == "CLIENT_FILE_TOO_LARGE":
                return .stop(try fail(item, reason: "fileTooLarge", generation))
            case .failure(let error):
                return .stop(try handle(error, for: item, generation))
            }
        }
        return .done
    }

    /// Fetches a committed message's metadata. A failure keeps the item `committed` for a later pass.
    func hydrate(_ item: OutboxItem, _ name: MessageName, _ generation: Generation) async throws(SyncError) {
        let message: Message
        do throws(ChatAPIError) {
            message = try await api.getMessage(name)
        } catch {
            return
        }
        try commit(generation) { batch in
            batch.append(.upsertMessages([message]))
            batch.append(.deleteOutbox(item.id))
        }
    }

    func handle(_ error: ChatAPIError, for original: OutboxItem, _ generation: Generation) throws(SyncError)
        -> SendOutcome
    {
        var item = original
        switch error {
        case .unauthorized, .noCredentials:
            // Rejected before processing; an earlier attempt may still have landed, so `unknown` is kept.
            item.state = original.state == .unknown ? .unknown : .queued
            let restored = item
            try commit(generation) { $0.append(.putOutbox(restored)) }
            return .needsLogin
        case .notFound where item.payload.thread != nil, .failedPrecondition where item.payload.thread != nil:
            return try fail(item, reason: "threadGone", generation)
        case .transport(.offline):
            item.state = original.state == .unknown ? .unknown : .queued
            item.attempts -= 1
            let restored = item
            try commit(generation) { $0.append(.putOutbox(restored)) }
            return .offline
        case .transport(.cancelled):
            // Cancellation doesn't prove the request went unprocessed; the same request ID resolves it later.
            item.state = .unknown
            let unknown = item
            try commit(generation) { $0.append(.putOutbox(unknown)) }
            return .willRetry(at: clock.now())
        case _ where error.isRetryable || error.writeOutcomeUnknown:
            let unknown = error.writeOutcomeUnknown || original.state == .unknown
            item.state = unknown ? .unknown : .queued
            let next = clock.now().adding(backoff.delay(attempt: item.attempts - 1, after: error))
            item.nextAttempt = next
            let retry = item
            try commit(generation) { $0.append(.putOutbox(retry)) }
            return .willRetry(at: next)
        default:
            return try fail(item, reason: Self.reason(for: error), generation)
        }
    }

    /// Returns a claimed item to its state before this attempt, keeping any upload tokens it gained.
    func unclaim(
        _ item: OutboxItem, _ original: OutboxItem, _ outcome: SendOutcome, _ generation: Generation
    ) throws(SyncError) -> SendOutcome {
        var restored = item
        restored.state = original.state
        restored.attempts = original.attempts
        restored.nextAttempt = original.nextAttempt
        let durable = restored
        try commit(generation) { $0.append(.putOutbox(durable)) }
        return outcome
    }

    /// Terminal failure: the text goes back into the composer unless the user already started a new draft.
    func fail(_ original: OutboxItem, reason: String, _ generation: Generation) throws(SyncError) -> SendOutcome {
        var item = original
        item.state = .failed(reason: reason)
        let failed = item
        let draft = Draft(
            space: item.space, thread: item.payload.thread, text: item.payload.text, updated: clock.now())
        let hasDraft: Bool
        do {
            hasDraft = try store.drafts().contains { $0.key == draft.key && !$0.text.isEmpty }
        } catch {
            throw .store(error)
        }
        try commit(generation) { batch in
            batch.append(.putOutbox(failed))
            if !hasDraft { batch.append(.putDraft(draft)) }
        }
        return .failed(reason: reason)
    }

    /// Removes a failed item, e.g. after "Post as new message" re-enqueued its text.
    public func discard(_ id: UUID, _ generation: Generation) throws(SyncError) {
        try commit(generation) { $0.append(.deleteOutbox(id)) }
    }

    static func reason(for error: ChatAPIError) -> String {
        switch error {
        case .permissionDenied: "permissionDenied"
        case .invalidArgument(let info): info.status == "CLIENT_TEXT_TOO_LONG" ? "tooLong" : "invalid"
        case .notFound: "notFound"
        case .conflict: "conflict"
        default: "rejected"
        }
    }

    func pace(_ space: SpaceName) async throws(SyncError) {
        guard let last = lastWrite.withLock({ $0[space] }) else { return }
        let ready = last.adding(Self.spacing)
        let now = clock.now()
        guard ready > now else { return }
        let wait = Duration.seconds(ready.seconds - now.seconds) + .nanoseconds(Int64(ready.nanos) - Int64(now.nanos))
        do { try await clock.sleep(for: wait) } catch { throw .retired }
    }

    func markWrite(_ space: SpaceName) {
        let now = clock.now()
        lastWrite.withLock { $0[space] = now }
    }

    func outbox() throws(SyncError) -> [OutboxItem] {
        do { return try store.outbox() } catch { throw .store(error) }
    }

    func commit(_ generation: Generation, _ build: (inout StoreWrite) -> Void) throws(SyncError) {
        do {
            try store.write(gate: gate, generation: generation, build)
        } catch .gateClosed {
            throw .retired
        } catch {
            throw .store(error)
        }
    }
}

/// Per-space drain ownership with a pending flag, so a drain request that arrives mid-drain triggers another pass.
final class DrainLock: Sendable {
    private let state = Mutex<[SpaceName: Bool]>([:])

    func begin(_ space: SpaceName) -> Bool {
        state.withLock { running in
            if running[space] != nil {
                running[space] = true
                return false
            }
            running[space] = false
            return true
        }
    }

    func continueOrRelease(_ space: SpaceName) -> Bool {
        state.withLock { running in
            if running[space] == true {
                running[space] = false
                return true
            }
            running[space] = nil
            return false
        }
    }

    func release(_ space: SpaceName) {
        _ = state.withLock { $0.removeValue(forKey: space) }
    }
}
