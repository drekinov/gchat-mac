import ChatKeychain
import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatSync

// MARK: Clocks

/// Time moves only when the test says so or when something sleeps; sleeping advances it without waiting.
final class ManualClock: SyncClock {
    private struct State {
        var now: Timestamp
        var sleeps: [Duration] = []
    }

    private let state: Mutex<State>

    init(start: Timestamp) { state = Mutex(State(now: start)) }

    func now() -> Timestamp { state.withLock { $0.now } }

    func advance(_ duration: Duration) {
        state.withLock { $0.now = $0.now.adding(duration) }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock { state in
            state.sleeps.append(duration)
            state.now = state.now.adding(duration)
        }
    }

    var sleeps: [Duration] { state.withLock { $0.sleeps } }
}

/// Server time plus virtual time that runs ahead by every sleep, so polling loops tick fast. While held, only
/// `advance` moves it, and sleeps still return.
final class SteppingClock: SyncClock {
    private struct State {
        var drift = Duration.zero
        var held = false
        var sleepsBegun = 0
    }

    let server: FakeChatServer
    private let state = Mutex(State())

    init(server: FakeChatServer) { self.server = server }

    func now() -> Timestamp { server.now.adding(state.withLock { $0.drift }) }

    func sleep(for duration: Duration) async throws {
        state.withLock { $0.sleepsBegun += 1 }
        try await Task.sleep(for: .milliseconds(1))
        state.withLock { if !$0.held { $0.drift += duration } }
    }

    var sleepsBegun: Int { state.withLock { $0.sleepsBegun } }
    func hold() { state.withLock { $0.held = true } }
    func release() { state.withLock { $0.held = false } }
    func advance(_ duration: Duration) { state.withLock { $0.drift += duration } }
}

/// Server time, with sleeps that really wait.
struct RealSleepClock: SyncClock {
    let server: FakeChatServer
    func now() -> Timestamp { server.now }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

extension Timestamp {
    func offset(from other: Timestamp) -> Duration {
        .seconds(seconds - other.seconds) + .nanoseconds(Int64(nanos) - Int64(other.nanos))
    }
}

// MARK: Scratch space and recorders

final class ScratchDirectory: Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gchat-hardening-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

final class Recorder<Element: Sendable>: Sendable {
    private let items = Mutex<[Element]>([])

    init() {}

    func append(_ element: Element) { items.withLock { $0.append(element) } }
    var all: [Element] { items.withLock { $0 } }
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

func poll(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

// MARK: Barrier and instrumented API

/// Parks calls that reach `pass()` while armed, so a test can act between a network await and the commit.
final class Barrier: Sendable {
    private struct State {
        var armed = false
        var arrivals = 0
        var parked: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func arm() {
        state.withLock { state in
            state.armed = true
            state.arrivals = 0
        }
    }

    func pass() async {
        if state.withLock({ !$0.armed }) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                guard state.armed else { return true }
                state.parked.append(continuation)
                state.arrivals += 1
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    var arrivals: Int { state.withLock { $0.arrivals } }

    func waitForArrival(_ count: Int = 1, timeout: Duration = .seconds(5)) async -> Bool {
        await poll(timeout: timeout) { self.arrivals >= count }
    }

    /// Wakes every parked call; later calls pass straight through until `arm()`.
    func release() {
        let parked = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.armed = false
            defer { state.parked = [] }
            return state.parked
        }
        for continuation in parked { continuation.resume() }
    }
}

final class CallLog: Sendable {
    struct Entry: Sendable {
        var name: String
        var time: Timestamp
    }

    private let entries = Mutex<[Entry]>([])

    func record(_ name: String, at time: Timestamp) { entries.withLock { $0.append(Entry(name: name, time: time)) } }
    func times(_ name: String) -> [Timestamp] { entries.withLock { $0.filter { $0.name == name }.map(\.time) } }
    func count(_ name: String) -> Int { entries.withLock { $0.filter { $0.name == name }.count } }
}

/// Marks list pages as having skipped malformed records, as the client does when a record fails to map.
final class PageTamper: Sendable {
    private let skipped = Mutex(0)
    private let dropMessage = Mutex(false)

    func setDropCreatedMessage(_ drop: Bool) { dropMessage.withLock { $0 = drop } }

    func apply(_ created: CreatedMessage) -> CreatedMessage {
        dropMessage.withLock { $0 } ? CreatedMessage(name: created.name, message: nil) : created
    }

    func setSkipped(_ count: Int) { skipped.withLock { $0 = count } }

    func apply<Item: Sendable>(_ page: Page<Item>) -> Page<Item> {
        var page = page
        page.skipped = skipped.withLock { $0 }
        return page
    }
}

/// Wraps a real client: the real call (and its server-side effects) happens, then the response waits at the barrier.
struct BarrierAPI: ChatAPI {
    let base: any ChatAPI
    let barrier: Barrier
    let log: CallLog
    let clock: any SyncClock
    var tamper = PageTamper()

    private func held<T: Sendable>(
        _ name: String, _ body: () async throws(ChatAPIError) -> T
    ) async throws(ChatAPIError) -> T {
        log.record(name, at: clock.now())
        let result: Result<T, ChatAPIError>
        do throws(ChatAPIError) {
            result = .success(try await body())
        } catch {
            result = .failure(error)
        }
        await barrier.pass()
        return try result.get()
    }

    func listSpaces(pageSize: Int, pageToken: String?) async throws(ChatAPIError) -> Page<Space> {
        let page = try await held("listSpaces") { () async throws(ChatAPIError) in
            try await base.listSpaces(pageSize: pageSize, pageToken: pageToken)
        }
        return tamper.apply(page)
    }

    func getSpace(_ space: SpaceName) async throws(ChatAPIError) -> Space {
        try await held("getSpace") { () async throws(ChatAPIError) in try await base.getSpace(space) }
    }

    func listMessages(
        in space: SpaceName, window: CreateTimeWindow, thread: ThreadName?, order: MessageOrder, pageSize: Int,
        showDeleted: Bool, pageToken: String?
    ) async throws(ChatAPIError) -> Page<Message> {
        let page = try await held("listMessages") { () async throws(ChatAPIError) in
            try await base.listMessages(
                in: space, window: window, thread: thread, order: order, pageSize: pageSize, showDeleted: showDeleted,
                pageToken: pageToken)
        }
        return tamper.apply(page)
    }

    func getMessage(_ message: MessageName) async throws(ChatAPIError) -> Message {
        try await held("getMessage") { () async throws(ChatAPIError) in try await base.getMessage(message) }
    }

    func listSpaceEvents(
        in space: SpaceName, types: [String], start: Timestamp, end: Timestamp, pageToken: String?
    ) async throws(ChatAPIError) -> Page<TimedSpaceEvent> {
        let page = try await held("listSpaceEvents") { () async throws(ChatAPIError) in
            try await base.listSpaceEvents(in: space, types: types, start: start, end: end, pageToken: pageToken)
        }
        return tamper.apply(page)
    }

    func listMemberships(in space: SpaceName, pageToken: String?) async throws(ChatAPIError) -> Page<Membership> {
        try await held("listMemberships") { () async throws(ChatAPIError) in
            try await base.listMemberships(in: space, pageToken: pageToken)
        }
    }

    func getSpaceReadState(_ space: SpaceName) async throws(ChatAPIError) -> Timestamp? {
        try await held("getSpaceReadState") { () async throws(ChatAPIError) in
            try await base.getSpaceReadState(space)
        }
    }

    func updateSpaceReadState(
        _ space: SpaceName, lastReadTime: Timestamp
    ) async throws(ChatAPIError) -> Timestamp? {
        try await held("updateSpaceReadState") { () async throws(ChatAPIError) in
            try await base.updateSpaceReadState(space, lastReadTime: lastReadTime)
        }
    }

    func getThreadReadState(_ thread: ThreadName) async throws(ChatAPIError) -> Timestamp? {
        try await held("getThreadReadState") { () async throws(ChatAPIError) in
            try await base.getThreadReadState(thread)
        }
    }

    func updateThreadReadState(_ thread: ThreadName, lastReadTime: Timestamp) async throws(ChatAPIError) -> Timestamp? {
        try await held("updateThreadReadState") { () async throws(ChatAPIError) in
            try await base.updateThreadReadState(thread, lastReadTime: lastReadTime)
        }
    }

    func searchMessages(
        _ query: String, pageSize: Int, pageToken: String?
    ) async throws(ChatAPIError) -> Page<Message> {
        try await base.searchMessages(query, pageSize: pageSize, pageToken: pageToken)
    }

    func getNotificationSetting(_ space: SpaceName) async throws(ChatAPIError) -> SpaceNotificationSetting {
        try await held("getNotificationSetting") { () async throws(ChatAPIError) in
            try await base.getNotificationSetting(space)
        }
    }

    func listCustomEmojis(pageToken: String?) async throws(ChatAPIError) -> Page<CustomEmoji> {
        try await held("listCustomEmojis") { () async throws(ChatAPIError) in
            try await base.listCustomEmojis(pageToken: pageToken)
        }
    }

    func createMessage(_ message: NewMessage) async throws(ChatAPIError) -> CreatedMessage {
        let created = try await held("createMessage") { () async throws(ChatAPIError) in
            try await base.createMessage(message)
        }
        return tamper.apply(created)
    }

    func getEditableMessage(_ message: MessageName) async throws(ChatAPIError) -> EditableMessage {
        try await held("getEditableMessage") { () async throws(ChatAPIError) in
            try await base.getEditableMessage(message)
        }
    }

    func updateMessageText(_ message: MessageName, text: String) async throws(ChatAPIError) -> Message {
        try await held("updateMessageText") { () async throws(ChatAPIError) in
            try await base.updateMessageText(message, text: text)
        }
    }

    func deleteMessage(_ message: MessageName, force: Bool) async throws(ChatAPIError) {
        try await held("deleteMessage") { () async throws(ChatAPIError) in
            try await base.deleteMessage(message, force: force)
        }
    }

    func setUpDirectMessage(with member: DirectMessageMember) async throws(ChatAPIError) -> Space {
        try await held("setUpDirectMessage") { () async throws(ChatAPIError) in
            try await base.setUpDirectMessage(with: member)
        }
    }

    func createReaction(on message: MessageName, emoji: Emoji) async throws(ChatAPIError) -> Reaction {
        try await held("createReaction") { () async throws(ChatAPIError) in
            try await base.createReaction(on: message, emoji: emoji)
        }
    }

    func deleteReaction(_ reaction: ReactionName) async throws(ChatAPIError) {
        try await held("deleteReaction") { () async throws(ChatAPIError) in try await base.deleteReaction(reaction) }
    }

    func listReactions(
        on message: MessageName, user: UserName?, pageToken: String?
    ) async throws(ChatAPIError) -> Page<Reaction> {
        try await held("listReactions") { () async throws(ChatAPIError) in
            try await base.listReactions(on: message, user: user, pageToken: pageToken)
        }
    }
}

// MARK: Store dump

/// Everything observable in a store, for before/after equality.
struct StoreDump: Equatable {
    var spaces: [StoredSpace] = []
    var messages: [SpaceName: [Message]] = [:]
    var checkpoints: [String: Timestamp] = [:]
    var members: [SpaceName: [Membership]] = [:]
    var threadReads: [ThreadName: Timestamp] = [:]
    var drafts: [Draft] = []
    var outbox: [OutboxItem] = []
    var meta: [String: String] = [:]

    init(_ store: any AccountStore, threads: [ThreadName] = []) throws {
        spaces = try store.spaces()
        for stored in spaces {
            let name = stored.space.name
            messages[name] = try store.messages(in: name, before: nil, limit: 100_000)
            members[name] = try store.members(in: name)
            for stream in SyncStream.allCases {
                if let value = try store.checkpoint(name, stream) { checkpoints["\(name)|\(stream.rawValue)"] = value }
            }
        }
        for thread in threads {
            if let value = try store.threadReadState(thread) { threadReads[thread] = value }
        }
        drafts = try store.drafts()
        outbox = try store.outbox()
        for key in ["firstSyncCompleted"] {
            if let value = try store.meta(key) { meta[key] = value }
        }
    }
}

// MARK: Sync rig

enum StoreKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case memory
    case sqlite

    var testDescription: String { rawValue }
}

/// One account against the fake server, a real client wrapped by a barrier, and either kind of store.
struct SyncRig: Sendable {
    let server = FakeChatServer()
    let alice: FakeAccount
    let bob: FakeAccount
    let anonymous = User(name: UserName(unchecked: "users/9001"), displayName: nil, isAnonymous: true)
    let scratch = ScratchDirectory()
    let store: any AccountStore
    let gate = SessionGate()
    let barrier = Barrier()
    let calls = CallLog()
    let tamper = PageTamper()
    let clock: ServerClock
    let engine: SyncEngine
    let sends: SendQueue
    let team: SpaceName
    let dm: SpaceName
    let first: Message
    let thread: ThreadName

    init(store kind: StoreKind = .memory) throws {
        alice = server.addAccount(displayName: "Alice")
        bob = server.addAccount(displayName: "Bob")
        switch kind {
        case .memory:
            store = InMemoryAccountStore()
        case .sqlite:
            let account = AccountID()
            store = try SQLiteAccountStore.open(
                directory: AccountDirectory(root: scratch.url, account: account), key: StoreKey.random(for: account))
        }
        clock = ServerClock(server: server)
        let client = GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token))
        let api = BarrierAPI(base: client, barrier: barrier, log: calls, clock: clock, tamper: tamper)
        engine = SyncEngine(api: api, store: store, gate: gate, clock: clock, me: alice.user.name)
        sends = SendQueue(api: api, store: store, gate: gate, clock: clock)

        team = server.addSpace(.space, displayName: "Team", members: [alice, bob])
        dm = server.addSpace(.directMessage, members: [alice], users: [anonymous])
        first = server.post("hello", in: team, from: .account(bob))
        thread = first.thread!
        server.advance(.seconds(5))
    }

    var generation: Generation { gate.current! }

    func dump() throws -> StoreDump { try StoreDump(store, threads: [thread]) }

    func close() { (store as? SQLiteAccountStore)?.close() }

    func syncSpaces() async throws {
        _ = try await engine.syncSpaces(generation)
    }
}

// MARK: Snapshots

/// Consumes a session's snapshot stream (single consumer) and keeps every snapshot it saw.
final class SnapshotRecorder: Sendable {
    private final class Storage: Sendable {
        let history = Mutex<[AccountSnapshot]>([])
        let finished = Mutex(false)
    }

    private let storage: Storage
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<AccountSnapshot>) {
        let storage = Storage()
        self.storage = storage
        task = Task {
            for await snapshot in stream { storage.history.withLock { $0.append(snapshot) } }
            storage.finished.withLock { $0 = true }
        }
    }

    /// The consumer is a task of `world`, so at every settled point it has recorded all that was sent.
    init(_ stream: AsyncStream<AccountSnapshot>, in world: SimWorld) {
        let storage = Storage()
        self.storage = storage
        task =
            world.start {
                for await snapshot in stream { storage.history.withLock { $0.append(snapshot) } }
                storage.finished.withLock { $0 = true }
            }.task
    }

    var history: [AccountSnapshot] { storage.history.withLock { $0 } }
    var latest: AccountSnapshot? { storage.history.withLock { $0.last } }
    var isFinished: Bool { storage.finished.withLock { $0 } }

    func cancel() { task.cancel() }

    /// The first snapshot at or after position `since` in the history that satisfies `predicate`.
    func wait(
        since: Int = 0, timeout: Duration = .seconds(5), where predicate: @escaping @Sendable (AccountSnapshot) -> Bool
    ) async -> AccountSnapshot? {
        let found = await poll(timeout: timeout) { self.history.dropFirst(since).contains(where: predicate) }
        return found ? history.dropFirst(since).first(where: predicate) : nil
    }

    func waitForFinish(timeout: Duration = .seconds(5)) async -> Bool {
        await poll(timeout: timeout) { self.isFinished }
    }
}

// MARK: Logout doubles

struct Observation: Sendable, Equatable {
    var name: String
    var tombstonePending: Bool
    var gate: SessionState
    var accountFilesExist: Bool
}

struct StepFailureError: Error, Equatable {}

/// Does the real deletions and records, at every call, what the world looked like.
final class TestEraser: AccountEraser {
    let directory: AccountDirectory
    let secrets: InMemorySecretStore
    let lifecycle: StoreKeyLifecycle
    let tombstones: LogoutTombstones
    let credentialID: SecretID
    let observations: Recorder<Observation>
    let gate: SessionGate?
    private let failing = Mutex<Set<LogoutStep>>([])

    init(
        directory: AccountDirectory, secrets: InMemorySecretStore, tombstones: LogoutTombstones,
        observations: Recorder<Observation> = Recorder(), gate: SessionGate? = nil
    ) {
        self.directory = directory
        self.secrets = secrets
        lifecycle = StoreKeyLifecycle(secrets: secrets)
        self.tombstones = tombstones
        credentialID = Self.credentialID(for: directory.account)
        self.observations = observations
        self.gate = gate
    }

    static func credentialID(for account: AccountID) -> SecretID {
        SecretID(service: "io.github.drekinov.gchat-mac.credentials", account: account.description)
    }

    func setFailing(_ steps: Set<LogoutStep>) { failing.withLock { $0 = steps } }

    private func enter(_ step: LogoutStep) throws {
        observe(step.rawValue)
        if failing.withLock({ $0.contains(step) }) { throw StepFailureError() }
    }

    func observe(_ name: String) {
        observations.append(
            Observation(
                name: name, tombstonePending: tombstones.isPending(directory.account),
                gate: gate?.snapshot.1 ?? .active, accountFilesExist: exists(directory.accountURL)))
    }

    func wipeExports(_ account: AccountID) throws {
        try enter(.wipeExports)
        try directory.wipeExports()
    }

    func removeNotifications(_ account: AccountID) async {
        observe(LogoutStep.removeNotifications.rawValue)
    }

    func shredStoreKey(_ account: AccountID) throws {
        try enter(.shredStoreKey)
        try lifecycle.shred(account)
    }

    func deleteCredentials(_ account: AccountID) throws {
        try enter(.deleteCredentials)
        try secrets.delete(credentialID)
    }

    func deleteAccountFiles(_ account: AccountID) throws {
        try enter(.deleteAccountFiles)
        try directory.deleteAccountFiles()
    }

    func unregister(_ account: AccountID) throws {
        try enter(.unregister)
        try AccountRegistry(secrets: secrets).remove(account)
    }

    func perform(_ step: LogoutStep) async throws {
        switch step {
        case .wipeExports: try wipeExports(directory.account)
        case .removeNotifications: await removeNotifications(directory.account)
        case .shredStoreKey: try shredStoreKey(directory.account)
        case .deleteCredentials: try deleteCredentials(directory.account)
        case .deleteAccountFiles: try deleteAccountFiles(directory.account)
        case .unregister: try unregister(directory.account)
        }
    }
}

struct NoopEraser: AccountEraser {
    func wipeExports(_ account: AccountID) throws {}
    func removeNotifications(_ account: AccountID) async {}
    func shredStoreKey(_ account: AccountID) throws {}
    func deleteCredentials(_ account: AccountID) throws {}
    func deleteAccountFiles(_ account: AccountID) throws {}
    func unregister(_ account: AccountID) throws {}
}

final class RecordingRevoker: TokenRevoker {
    let eraser: TestEraser
    let tokens = Recorder<String>()

    init(eraser: TestEraser) { self.eraser = eraser }

    func revoke(_ token: String) async {
        tokens.append(token)
        eraser.observe("revoke")
    }
}

/// A wait that ignores cancellation until `release()` (or a 60 s safety net).
final class UncancellableWait: Sendable {
    private struct State {
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    init() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [self] in release() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.released { return true }
                state.waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.released = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}

extension AccountSession {
    @discardableResult
    func spawnRegistered(_ body: @escaping @Sendable () async -> Void) -> Bool {
        work.spawn(body)
    }
}

extension SessionTiming {
    static var fast: SessionTiming {
        var timing = SessionTiming()
        timing.sidebarInterval = .milliseconds(50)
        timing.inactiveSidebarInterval = .milliseconds(50)
        timing.liveSidebarInterval = .milliseconds(50)
        timing.focusInterval = 0.01...0.02
        timing.idleSleep = .milliseconds(10)
        timing.logoutDrain = .milliseconds(200)
        return timing
    }
}
