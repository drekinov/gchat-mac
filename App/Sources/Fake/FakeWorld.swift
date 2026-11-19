import ChatModel
import ChatNet
import ChatStore
import ChatSync
import FakeChatServer
import Foundation
import GoogleChat

struct StaticTokens: TokenProvider {
    let token: String
    func accessToken() async throws(ChatAPIError) -> String { token }
    func invalidate(_ token: String) async {}
}

struct NoopEraser: AccountEraser {
    func wipeExports(_ account: AccountID) throws {}
    func removeNotifications(_ account: AccountID) async {}
    func shredStoreKey(_ account: AccountID) throws {}
    func deleteCredentials(_ account: AccountID) throws {}
    func deleteAccountFiles(_ account: AccountID) throws {}
    func unregister(_ account: AccountID) throws {}
}

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Reads fake-mode attachment bookmarks: security-scoped first, plain paths as the fallback.
struct FakeModeFileAccess: FileAccess {
    func withFile<T: Sendable>(_ bookmark: Data, _ body: (URL) async throws -> T) async throws -> T {
        do {
            return try await SecurityScopedFileAccess().withFile(bookmark, body)
        } catch FileAccessError.unavailable {
            return try await PathFileAccess().withFile(bookmark, body)
        }
    }
}

/// A fake Chat backend per org (so each can behave differently), a ticking clock and background traffic, wired to
/// real sessions with encrypted SQLite stores and media caches under a temporary root.
final class FakeWorld: Sendable {
    struct Entry: Sendable {
        let info: AccountInfo
        let session: AccountSession
    }

    struct Target: Sendable {
        let account: FakeAccount
        let server: FakeChatServer
        let space: SpaceName
        let senders: [User]
        let isBot: Bool
        let roots: [ThreadName]
    }

    /// Org whose server answers media downloads with a redirect to an unauthenticated host.
    static let redirectOrgIndex = 1
    static let mediaHosts: Set<String> = ["media.fake.example", "fake-emoji.example"]

    let servers: [FakeChatServer]
    let entries: [Entry]
    let tasks: [Task<Void, Never>]
    let root: URL

    init(servers: [FakeChatServer], entries: [Entry], tasks: [Task<Void, Never>], root: URL) {
        self.servers = servers
        self.entries = entries
        self.tasks = tasks
        self.root = root
    }

    func stop() {
        for task in tasks { task.cancel() }
    }

    static func timing() -> SessionTiming {
        var timing = SessionTiming()
        timing.sidebarInterval = .seconds(10)
        timing.inactiveSidebarInterval = .seconds(10)
        timing.liveSidebarInterval = .seconds(10)
        timing.focusInterval = 4...6
        timing.titlesPerTick = 12
        return timing
    }

    private static let cleanup: Void = {
        try? FileManager.default.removeItem(at: baseDirectory)
    }()

    private static var baseDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "gchat-fake", directoryHint: .isDirectory)
    }

    @concurrent
    static func build(
        accounts count: Int, traffic: Bool, trafficRange: ClosedRange<Double>? = nil,
        notifications: (any NotificationPoster)? = nil,
        timing: SessionTiming = FakeWorld.timing()
    ) async -> FakeWorld {
        _ = cleanup
        let realNow = Timestamp(Date())
        let root = baseDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? ExportDirectory.wipeAll(root: root)
        let tombstones = LogoutTombstones(root: root)
        let budget = MemoryBudget(capacity: 48 << 20)
        let pipeline = ImagePipeline(budget: budget)
        let fetcher = SafeFetcher(allowedHosts: mediaHosts, protocolClasses: [FakeGifHost.self, FakeMediaHost.self])
        let library = FakeLibrary.shared

        var servers: [FakeChatServer] = []
        var targets: [[Target]] = []
        var accounts: [(FakeAccount, AccountInfo, FakeChatServer)] = []
        for index in 0..<count {
            let org = FakeScript.org(index)
            let server = FakeChatServer(start: realNow.adding(.seconds(-2 * 86_400)))
            if index == redirectOrgIndex { server.mediaRedirectHost = "media.fake.example" }
            let emoji = FakeSeeder.CustomEmojis(
                shipit: server.addCustomEmoji(shortcode: "shipit"), lgtm: server.addCustomEmoji(shortcode: "lgtm"),
                parrot: server.addCustomEmoji(shortcode: "party_parrot"))
            let account = server.addAccount(
                displayName: "Casey Sample", email: "casey@\(FakeScript.emailDomain(org))")
            let info = AccountInfo(id: AccountID(), name: org.name, colorIndex: index, me: account.user.name)
            var random = SeededRandom(state: UInt64(0xC0FFEE + index * 7919))
            targets.append(
                FakeSeeder.seed(
                    org: org, orgIndex: index, account: account, server: server, now: realNow, emoji: emoji,
                    library: library, &random))
            servers.append(server)
            accounts.append((account, info, server))
        }
        for server in servers { advance(server, to: Timestamp(Date())) }

        var entries: [Entry] = []
        for (account, info, server) in accounts {
            let client = GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: account.token))
            let gate = SessionGate()
            let directory = AccountDirectory(root: root, account: info.id)
            let key = StoreKey.random(for: info.id)
            var store: any AccountStore = InMemoryAccountStore()
            var loader: MediaLoader?
            if let sqlite = try? SQLiteAccountStore.open(directory: directory, key: key),
                let cache = try? MediaCache(directory: directory, key: key)
            {
                store = sqlite
                loader = MediaLoader(
                    media: client, cache: cache, exports: ExportDirectory(directory: directory), pipeline: pipeline,
                    fetcher: fetcher, gate: gate)
            }
            let session = AccountSession(
                account: info.id, me: account.user.name, api: client, store: store, clock: SystemClock(),
                logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: tombstones), directory: client,
                gate: gate, timing: timing, notifications: notifications, media: client, files: FakeModeFileAccess(),
                mediaLoader: loader)
            await session.start()
            entries.append(Entry(info: info, session: session))
        }

        let clocked = servers
        let clockTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                for server in clocked { advance(server, to: Timestamp(Date())) }
            }
        }
        let flat = targets
        let trafficTask = Task {
            var random = SeededRandom(state: UInt64(Date().timeIntervalSince1970))
            while !Task.isCancelled {
                let range = trafficRange ?? trafficInterval()
                try? await Task.sleep(for: .seconds(Double.random(in: range, using: &random)))
                guard !Task.isCancelled, traffic, trafficRange != nil || trafficEnabled(),
                    let group = flat.randomElement(using: &random),
                    let target = group.randomElement(using: &random)
                else { continue }
                postTraffic(target, &random)
            }
        }
        return FakeWorld(servers: servers, entries: entries, tasks: [clockTask, trafficTask], root: root)
    }

    /// Developer settings are read on every tick, so they take effect without a relaunch.
    private static func trafficEnabled() -> Bool {
        UserDefaults.standard.object(forKey: "fakeTrafficEnabled") as? Bool ?? true
    }

    private static func trafficInterval() -> ClosedRange<Double> {
        let low = UserDefaults.standard.object(forKey: "fakeTrafficMin") as? Double ?? 20
        let high = UserDefaults.standard.object(forKey: "fakeTrafficMax") as? Double ?? 40
        return max(1, min(low, high))...max(1, max(low, high))
    }

    private static func advance(_ server: FakeChatServer, to real: Timestamp) {
        let now = server.now
        guard now < real else { return }
        server.advance(.seconds(real.date.timeIntervalSince(now.date)))
    }

    private static func postTraffic(_ target: Target, _ random: inout SeededRandom) {
        guard let sender = target.senders.randomElement(using: &random) else { return }
        let pool = target.isBot ? FakeScript.botLines : FakeScript.chatter
        let text = pool.randomElement(using: &random) ?? "ok"
        let thread = Double.random(in: 0...1, using: &random) < 0.4 ? target.roots.randomElement(using: &random) : nil
        target.server.post(text, in: target.space, from: target.isBot ? .bot(sender) : .user(sender), thread: thread)
    }
}
