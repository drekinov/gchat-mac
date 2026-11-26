import ChatModel
import Foundation
import Observation

/// One composer: a space's own, or one of its threads'.
public struct DraftKey: Hashable, Sendable {
    public let space: SpaceName
    public let thread: ThreadName?

    public init(space: SpaceName, thread: ThreadName?) {
        self.space = space
        self.thread = thread
    }
}

/// Where an account's drafts are read and written.
public protocol DraftStorage: Sendable {
    func draft(_ key: DraftKey) async throws -> Draft?
    func drafts() async throws -> [Draft]
    func save(_ draft: Draft) async throws
}

/// What a composer shows. It takes no edits until its stored draft has loaded, so nothing typed or attached early
/// can replace it.
@MainActor @Observable
public final class ComposerDraft {
    public fileprivate(set) var text = ""
    public fileprivate(set) var attachments: [PendingAttachment] = []
    public fileprivate(set) var hydrated = false
    public fileprivate(set) var loadFailed = false

    @ObservationIgnored fileprivate var dirty = false
    @ObservationIgnored fileprivate var revision: UInt64 = 0
    /// A send owns the stored row until its enqueue commits.
    @ObservationIgnored fileprivate var claimed = false
    @ObservationIgnored fileprivate var debounce: Task<Void, Never>?

    public var isEmpty: Bool { text.isEmpty && attachments.isEmpty }

    fileprivate func changed() {
        revision += 1
        dirty = true
    }
}

/// An account's composer drafts: the only writer of its `drafts` rows besides a failed send's recovery. Loads, saves
/// and sends run one at a time in call order, and a save writes the state as it is when it runs.
@MainActor @Observable
public final class ComposerDrafts {
    /// Composers with a draft, for the sidebar; reassigned only when one gains or loses its draft.
    public private(set) var drafted: Set<DraftKey> = []
    /// Set while the app is quitting: composers take no edits until it's cancelled.
    public var isQuitting = false

    @ObservationIgnored private var entries: [DraftKey: ComposerDraft] = [:]
    @ObservationIgnored private var stored: Set<DraftKey> = []
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var queued = 0
    @ObservationIgnored private let storage: @MainActor () -> (any DraftStorage)?
    @ObservationIgnored private let adopt: @MainActor ([PendingAttachment]) -> [PendingAttachment]
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    /// `storage` is resolved for every operation, so a reconnected session takes over. `adopt` fixes up stored
    /// attachments as they load (dropping missing copies, moving old ones to durable storage).
    public convenience init(
        saveDelay: Duration = .milliseconds(600),
        adopt: @escaping @MainActor ([PendingAttachment]) -> [PendingAttachment] = { $0 },
        storage: @escaping @MainActor () -> (any DraftStorage)?
    ) {
        self.init(saveDelay: saveDelay, adopt: adopt, storage: storage, sleep: { try await Task.sleep(for: $0) })
    }

    /// `sleep` waits out the pause after typing and throws when its task is cancelled.
    init(
        saveDelay: Duration, adopt: @escaping @MainActor ([PendingAttachment]) -> [PendingAttachment],
        storage: @escaping @MainActor () -> (any DraftStorage)?,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.saveDelay = saveDelay
        self.adopt = adopt
        self.storage = storage
        self.sleep = sleep
    }

    public func draft(_ key: DraftKey) -> ComposerDraft {
        if let entry = entries[key] { return entry }
        let entry = ComposerDraft()
        entries[key] = entry
        return entry
    }

    public func isEditable(_ key: DraftKey) -> Bool { draft(key).hydrated && !isQuitting }

    public func hasDraft(in space: SpaceName) -> Bool { drafted.contains { $0.space == space } }

    /// Loads the stored draft once; `false` if it couldn't be read.
    @discardableResult
    public func hydrate(_ key: DraftKey) async -> Bool {
        let entry = draft(key)
        if entry.hydrated { return true }
        await run { [self] in
            guard !entry.hydrated else { return }
            guard let storage = storage() else {
                entry.loadFailed = true
                return
            }
            do {
                let saved = try await storage.draft(key)
                let attachments = adopt(saved?.attachments ?? [])
                entry.text = saved?.text ?? ""
                entry.attachments = attachments
                entry.hydrated = true
                entry.loadFailed = false
                if attachments != saved?.attachments ?? [] {
                    entry.changed()
                    await save(key, entry)
                }
            } catch {
                entry.loadFailed = true
            }
            refreshDrafted()
        }
        return entry.hydrated
    }

    /// Records an edit; it's saved after a short pause, or by `flush`.
    public func setText(_ text: String, for key: DraftKey) {
        let entry = draft(key)
        guard entry.hydrated, !isQuitting, entry.text != text else { return }
        entry.text = text
        entry.changed()
        entry.debounce?.cancel()
        entry.debounce = Task { [weak self, saveDelay, sleep] in
            do { try await sleep(saveDelay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.enqueue { await self.save(key, entry) }
        }
        refreshDrafted()
    }

    /// Replaces the attachments and saves them straight away; `false` if the composer takes no edits now.
    @discardableResult
    public func setAttachments(_ attachments: [PendingAttachment], for key: DraftKey) -> Bool {
        let entry = draft(key)
        guard entry.hydrated, !isQuitting else { return false }
        guard entry.attachments != attachments else { return true }
        entry.attachments = attachments
        entry.changed()
        entry.debounce?.cancel()
        enqueue { [self] in await save(key, entry) }
        refreshDrafted()
        return true
    }

    /// Clears the composer at once and runs `perform` with its attachments in turn after earlier saves. The stored
    /// draft stays until `perform` commits the send (which deletes it); on failure the text and files come back,
    /// ahead of anything added since. The task's result is `false` if nothing was sent; `nil` if nothing was taken.
    public func send(
        _ key: DraftKey, _ perform: @escaping @MainActor ([PendingAttachment]) async -> Bool
    ) -> Task<Bool, Never>? {
        let entry = draft(key)
        guard entry.hydrated, !isQuitting, !entry.claimed else { return nil }
        let text = entry.text
        let attachments = entry.attachments
        entry.debounce?.cancel()
        entry.text = ""
        entry.attachments = []
        entry.changed()
        entry.claimed = true
        let submitted = entry.revision
        refreshDrafted()
        return schedule { [self] in
            let sent = await perform(attachments)
            entry.claimed = false
            if sent {
                stored.remove(key)
                entry.dirty = entry.revision != submitted
            } else {
                entry.attachments = attachments + entry.attachments
                entry.text = entry.text.isEmpty ? text : text.isEmpty ? entry.text : text + "\n" + entry.text
                entry.changed()
            }
            await save(key, entry)
            refreshDrafted()
            return sent
        }
    }

    /// Saves every unsaved change now and waits for all queued work; `false` if anything is still unsaved.
    public func flush() async -> Bool {
        for entry in entries.values { entry.debounce?.cancel() }
        await run { [self] in
            for (key, entry) in entries where entry.dirty { await save(key, entry) }
        }
        return entries.values.allSatisfy { !$0.dirty }
    }

    /// Retries unsaved changes, for a reconnected session.
    public func retryUnsaved() {
        enqueue { [self] in
            for (key, entry) in entries where entry.dirty { await save(key, entry) }
        }
    }

    /// Re-reads which composers have stored drafts, and gives a loaded, untouched, empty composer the draft the
    /// session wrote for it (a failed send's text). Drafts of composers not loaded yet get their files readied too.
    public func reload() {
        enqueue { [self] in
            guard let storage = storage(), let all = try? await storage.drafts() else { return }
            stored = Set(all.map { DraftKey(space: $0.space, thread: $0.thread) })
            for saved in all {
                let key = DraftKey(space: saved.space, thread: saved.thread)
                guard let entry = entries[key], entry.hydrated else {
                    var readied = saved
                    readied.attachments = adopt(saved.attachments)
                    if readied.attachments != saved.attachments { try? await storage.save(readied) }
                    continue
                }
                guard !entry.dirty, !entry.claimed, entry.isEmpty else { continue }
                let attachments = adopt(saved.attachments)
                entry.text = saved.text
                entry.attachments = attachments
                if attachments != saved.attachments {
                    entry.changed()
                    await save(key, entry)
                }
            }
            refreshDrafted()
        }
    }

    /// Nothing unsaved, typed or queued: quitting now loses nothing.
    public var isSettled: Bool {
        queued == 0 && entries.values.allSatisfy { !$0.dirty && !$0.claimed }
    }

    /// Waits for everything queued so far.
    public func settle() async {
        await run {}
    }

    // MARK: Queue

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        _ = schedule(operation)
    }

    private func schedule<T: Sendable>(_ operation: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = tail
        queued += 1
        let task = Task { @MainActor [weak self] in
            await previous?.value
            defer { self?.queued -= 1 }
            return await operation()
        }
        tail = Task { _ = await task.value }
        return task
    }

    private func run<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        await schedule(operation).value
    }

    /// Only from the queue. A claimed composer's row belongs to its send.
    private func save(_ key: DraftKey, _ entry: ComposerDraft) async {
        guard entry.dirty, !entry.claimed, let storage = storage() else { return }
        let revision = entry.revision
        let draft = Draft(
            space: key.space, thread: key.thread, text: entry.text, attachments: entry.attachments,
            updated: Timestamp(Date()))
        do {
            try await storage.save(draft)
        } catch {
            return
        }
        if entry.revision == revision { entry.dirty = false }
        if draft.isEmpty { stored.remove(key) } else { stored.insert(key) }
        refreshDrafted()
    }

    private func refreshDrafted() {
        var keys = Set<DraftKey>()
        for key in stored where !(entries[key]?.hydrated ?? false) { keys.insert(key) }
        for (key, entry) in entries where entry.hydrated && !entry.isEmpty { keys.insert(key) }
        if keys != drafted { drafted = keys }
    }
}
