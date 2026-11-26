import ChatModel
import Foundation
import Testing

@testable import ChatSync

/// Draft rows by key, with loads and saves that can be held or made to fail.
actor TestDraftStorage: DraftStorage {
    var rows: [String: Draft] = [:]
    var failLoads = false
    var failSaves = false
    private(set) var saves = 0
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Operations waiting at the hold.
    var parked: Int { waiting.count }

    func hold() { held = true }

    func release() {
        held = false
        for waiter in waiting { waiter.resume() }
        waiting = []
    }

    func set(failLoads: Bool? = nil, failSaves: Bool? = nil) {
        if let failLoads { self.failLoads = failLoads }
        if let failSaves { self.failSaves = failSaves }
    }

    func put(_ draft: Draft) { rows[draft.key] = draft }

    func delete(_ key: DraftKey) { rows[key.thread?.rawValue ?? key.space.rawValue] = nil }

    func row(_ key: DraftKey) -> Draft? { rows[key.thread?.rawValue ?? key.space.rawValue] }

    private func pass() async {
        guard held else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func draft(_ key: DraftKey) async throws -> Draft? {
        await pass()
        if failLoads { throw StorageFailure() }
        return row(key)
    }

    func drafts() async throws -> [Draft] {
        await pass()
        if failLoads { throw StorageFailure() }
        return Array(rows.values)
    }

    func save(_ draft: Draft) async throws {
        await pass()
        if failSaves { throw StorageFailure() }
        saves += 1
        rows[draft.key] = draft.isEmpty ? nil : draft
    }
}

struct StorageFailure: Error {}

@MainActor
struct ComposerDraftsTests {
    static let room = SpaceName(unchecked: "spaces/ROOM")
    static let other = SpaceName(unchecked: "spaces/OTHER")
    let key = DraftKey(space: room, thread: nil)
    let thread = DraftKey(space: room, thread: ThreadName(unchecked: "spaces/ROOM/threads/T1"))
    static let saveDelay: Duration = .seconds(7)
    let storage = TestDraftStorage()
    /// The pauses after typing; one ends only when a test fires it.
    let pauses = Pauses()
    let drafts: ComposerDrafts

    init() {
        drafts = Self.make(storage: { [storage] in storage }, pauses: pauses)
    }

    static func make(
        adopt: @escaping @MainActor ([PendingAttachment]) -> [PendingAttachment] = { $0 },
        storage: @escaping @MainActor () -> (any DraftStorage)?, pauses: Pauses
    ) -> ComposerDrafts {
        ComposerDrafts(saveDelay: saveDelay, adopt: adopt, storage: storage, sleep: pauses.sleep)
    }

    func stored(_ text: String, files: [PendingAttachment] = [], at key: DraftKey? = nil) -> Draft {
        let key = key ?? self.key
        return Draft(space: key.space, thread: key.thread, text: text, attachments: files, updated: Timestamp(Date()))
    }

    /// Simulates the outbox insert that deletes the stored draft in the same commit.
    func enqueue(succeeds: Bool = true) -> @MainActor ([PendingAttachment]) async -> Bool {
        { [storage, key] _ in
            guard succeeds else { return false }
            await storage.delete(key)
            return true
        }
    }

    @Test func aComposerTakesNoEditsUntilItsDraftLoads() async throws {
        await storage.put(stored("kept", files: [draftFile("a.pdf")]))
        await storage.hold()
        let loading = Running { [drafts, key] in await drafts.hydrate(key) }
        let parked = await eventually { await storage.parked == 1 }
        #expect(parked)

        drafts.setText("typed early", for: key)
        #expect(!drafts.setAttachments([draftFile("b.pdf")], for: key))
        #expect(!drafts.isEditable(key))

        await storage.release()
        #expect(await loading.settled() == true)
        #expect(drafts.draft(key).text == "kept")
        #expect(drafts.draft(key).attachments.map(\.filename) == ["a.pdf"])
        #expect(await storage.row(key)?.text == "kept")
    }

    @Test func aFailedLoadWritesNothing() async {
        await storage.put(stored("kept"))
        await storage.set(failLoads: true)

        #expect(await !drafts.hydrate(key))
        drafts.setText("replacement", for: key)
        #expect(await drafts.flush())

        #expect(drafts.draft(key).loadFailed)
        #expect(await storage.row(key)?.text == "kept")
        await storage.set(failLoads: false)
        #expect(await drafts.hydrate(key))
        #expect(drafts.draft(key).text == "kept")
    }

    @Test func attachmentsAndTextAreSavedTogether() async {
        await drafts.hydrate(key)
        drafts.setText("hello", for: key)
        drafts.setAttachments([draftFile("a.pdf")], for: key)
        await drafts.settle()

        let row = await storage.row(key)
        #expect(row?.text == "hello")
        #expect(row?.attachments.map(\.filename) == ["a.pdf"])
        #expect(drafts.hasDraft(in: Self.room))
    }

    @Test func clearingEverythingDeletesTheRow() async {
        await storage.put(stored("old", files: [draftFile("a.pdf")]))
        await drafts.hydrate(key)
        drafts.setText("", for: key)
        drafts.setAttachments([], for: key)
        #expect(await drafts.flush())
        #expect(await storage.row(key) == nil)
        #expect(!drafts.hasDraft(in: Self.room))
    }

    @Test func typingIsSavedOnceItPausesAndRetypingRestartsThePause() async throws {
        await drafts.hydrate(key)
        drafts.setText("he", for: key)
        let paused = await eventually { pauses.asked.count == 1 }
        try #require(paused)
        drafts.setText("hello", for: key)
        let restarted = await eventually { pauses.asked.count == 2 }
        try #require(restarted)
        #expect(pauses.asked == [Self.saveDelay, Self.saveDelay])
        #expect(pauses.endings == [.cancelled, nil])
        await drafts.settle()
        #expect(await storage.saves == 0, "an interrupted pause saved")

        pauses.fire(1)
        let saved = await eventually { await storage.row(key)?.text == "hello" }
        try #require(saved)
        await drafts.settle()
        #expect(await storage.saves == 1)
        #expect(drafts.isSettled)
    }

    @Test func flushSavesTypingWithoutWaitingForThePause() async {
        await drafts.hydrate(key)
        drafts.setText("last words", for: key)

        #expect(await drafts.flush())
        #expect(await storage.row(key)?.text == "last words")
        #expect(await storage.saves == 1)
    }

    @Test func aFailedSaveStaysUnsavedUntilRetried() async {
        await drafts.hydrate(key)
        await storage.set(failSaves: true)
        drafts.setText("pending", for: key)

        #expect(await !drafts.flush())
        await storage.set(failSaves: false)
        drafts.retryUnsaved()
        await drafts.settle()
        #expect(await storage.row(key)?.text == "pending")
        #expect(await drafts.flush())
    }

    @Test func aSaveQueuedBeforeSendDoesNotBringBackTheSentText() async throws {
        await drafts.hydrate(key)
        drafts.setText("outgoing", for: key)
        #expect(await drafts.flush())
        drafts.setText("outgoing!", for: key)
        await storage.hold()
        let flushing = Running { [drafts] in await drafts.flush() }
        let parked = await eventually { await storage.parked == 1 }
        #expect(parked)

        let sending = drafts.send(key, enqueue())
        #expect(sending != nil)
        #expect(drafts.draft(key).text.isEmpty)
        await storage.release()

        let sent = Running { await sending?.value ?? false }
        #expect(await sent.settled() == true)
        #expect(await flushing.settled() != nil)
        #expect(await drafts.flush())
        #expect(await storage.row(key) == nil)
        #expect(!drafts.hasDraft(in: Self.room))
    }

    @Test func theStoredDraftStaysUntilTheSendCommits() async throws {
        await drafts.hydrate(key)
        drafts.setText("outgoing", for: key)
        #expect(await drafts.flush())
        let commit = Hold()
        defer { commit.open() }
        let sending = Running { [drafts, storage, key] in
            await drafts.send(key) { _ in
                await commit.pass()
                await storage.delete(key)
                return true
            }?.value ?? false
        }
        let committing = await eventually { commit.arrived == 1 }
        try #require(committing)

        drafts.setText("typed while sending", for: key)
        #expect(await storage.row(key)?.text == "outgoing")

        commit.open()
        #expect(await sending.settled() == true)
        #expect(await drafts.flush())
        #expect(await storage.row(key)?.text == "typed while sending")
    }

    @Test func aFailedSendPutsTheDraftBackAheadOfNewFiles() async throws {
        await drafts.hydrate(key)
        drafts.setText("outgoing", for: key)
        drafts.setAttachments([draftFile("a.pdf")], for: key)
        let commit = Hold()
        defer { commit.open() }
        let sending = Running { [drafts, key] in
            await drafts.send(key) { _ in
                await commit.pass()
                return false
            }?.value ?? false
        }
        let committing = await eventually { commit.arrived == 1 }
        try #require(committing)
        drafts.setAttachments([draftFile("b.pdf")], for: key)
        commit.open()

        #expect(await sending.settled() == false)
        #expect(drafts.draft(key).text == "outgoing")
        #expect(drafts.draft(key).attachments.map(\.filename) == ["a.pdf", "b.pdf"])
        #expect(await drafts.flush())
        #expect(await storage.row(key)?.attachments.map(\.filename) == ["a.pdf", "b.pdf"])
    }

    @Test func aFailedSendKeepsTextTypedWhileItWasPending() async throws {
        await drafts.hydrate(key)
        drafts.setText("first", for: key)
        let commit = Hold()
        defer { commit.open() }
        let sending = Running { [drafts, key] in
            await drafts.send(key) { _ in
                await commit.pass()
                return false
            }?.value ?? false
        }
        let committing = await eventually { commit.arrived == 1 }
        try #require(committing)
        drafts.setText("second", for: key)
        commit.open()

        #expect(await sending.settled() == false)
        #expect(drafts.draft(key).text == "first\nsecond")
    }

    @Test func reloadReadiesTheFilesOfDraftsNotOpenedYet() async {
        await storage.put(stored("waiting", files: [draftFile("gone.pdf"), draftFile("kept.pdf")], at: thread))
        let drafts = Self.make(
            adopt: { $0.filter { $0.filename != "gone.pdf" } }, storage: { [storage] in storage }, pauses: pauses)

        drafts.reload()
        await drafts.settle()

        #expect(await storage.row(thread)?.attachments.map(\.filename) == ["kept.pdf"])
        #expect(drafts.hasDraft(in: Self.room))
    }

    @Test func settledOnlyWithNothingUnsavedOrQueued() async {
        await drafts.hydrate(key)
        #expect(drafts.isSettled)
        drafts.setText("typing", for: key)
        #expect(!drafts.isSettled)
        #expect(await drafts.flush())
        #expect(drafts.isSettled)
    }

    @Test func reloadGivesAnOpenEmptyComposerItsRecoveredDraft() async {
        await drafts.hydrate(key)
        await drafts.hydrate(thread)
        drafts.setText("busy", for: thread)
        await storage.put(stored("recovered", files: [draftFile("a.pdf")]))
        await storage.put(stored("recovered reply", at: thread))

        drafts.reload()
        await drafts.settle()

        #expect(drafts.draft(key).text == "recovered")
        #expect(drafts.draft(key).attachments.map(\.filename) == ["a.pdf"])
        #expect(drafts.draft(thread).text == "busy")
    }

    @Test func theSidebarSeesStoredDraftsAndLocalClears() async {
        await storage.put(stored("waiting", at: thread))
        drafts.reload()
        await drafts.settle()
        #expect(drafts.hasDraft(in: Self.room))
        #expect(!drafts.hasDraft(in: Self.other))

        await drafts.hydrate(thread)
        drafts.setText("", for: thread)
        #expect(!drafts.hasDraft(in: Self.room))
        #expect(await drafts.flush())
        drafts.reload()
        await drafts.settle()
        #expect(!drafts.hasDraft(in: Self.room))
    }

    @Test func aSlowReloadCannotResurrectADraftSentAfterIt() async throws {
        await storage.put(stored("about to send"))
        await drafts.hydrate(key)
        await storage.hold()
        drafts.reload()
        let parked = await eventually { await storage.parked == 1 }
        #expect(parked)
        let sending = drafts.send(key, enqueue())
        #expect(sending != nil)
        await storage.release()

        let sent = Running { await sending?.value ?? false }
        #expect(await sent.settled() == true)
        await drafts.settle()
        #expect(!drafts.hasDraft(in: Self.room))
    }

    @Test func quittingStopsEdits() async {
        await drafts.hydrate(key)
        drafts.isQuitting = true

        drafts.setText("late", for: key)
        #expect(!drafts.setAttachments([draftFile("a.pdf")], for: key))
        #expect(drafts.send(key, enqueue()) == nil)
        #expect(drafts.draft(key).isEmpty)

        drafts.isQuitting = false
        drafts.setText("after cancel", for: key)
        #expect(drafts.draft(key).text == "after cancel")
    }

    @Test func aNewSessionTakesOverUnsavedDrafts() async {
        let replacement = TestDraftStorage()
        var current: TestDraftStorage? = storage
        let drafts = Self.make(storage: { current }, pauses: pauses)
        await drafts.hydrate(key)
        drafts.setText("across reconnect", for: key)

        current = nil
        #expect(await !drafts.flush())
        current = replacement
        drafts.retryUnsaved()
        await drafts.settle()

        #expect(await replacement.row(key)?.text == "across reconnect")
    }

    @Test func adoptedAttachmentsAreSavedBack() async {
        await storage.put(stored("", files: [draftFile("gone.pdf"), draftFile("kept.pdf")]))
        let drafts = Self.make(
            adopt: { $0.filter { $0.filename != "gone.pdf" } }, storage: { [storage] in storage }, pauses: pauses)

        await drafts.hydrate(key)
        await drafts.settle()

        #expect(drafts.draft(key).attachments.map(\.filename) == ["kept.pdf"])
        #expect(await storage.row(key)?.attachments.map(\.filename) == ["kept.pdf"])
    }
}
