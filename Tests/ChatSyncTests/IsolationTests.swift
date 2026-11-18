import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

enum AccountFailure: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case unauthorized
    case rateLimited
    case unavailable
    case forbiddenPlain
    case forbiddenServiceDisabled
    case forbiddenScopeInsufficient
    case forbiddenRateLimitReason
    case forbiddenResourceExhausted
    case malformedJSON

    var testDescription: String { rawValue }

    var response: FailureRule.Response? {
        switch self {
        case .unauthorized: .http(status: 401, googleStatus: "UNAUTHENTICATED")
        case .rateLimited:
            .http(status: 429, googleStatus: "RESOURCE_EXHAUSTED", reason: "RATE_LIMIT_EXCEEDED", retryAfterSeconds: 4)
        case .unavailable: .http(status: 503, googleStatus: "UNAVAILABLE")
        case .forbiddenPlain: .http(status: 403, googleStatus: "PERMISSION_DENIED")
        case .forbiddenServiceDisabled:
            .http(status: 403, googleStatus: "PERMISSION_DENIED", reason: "SERVICE_DISABLED")
        case .forbiddenScopeInsufficient:
            .http(status: 403, googleStatus: "PERMISSION_DENIED", reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT")
        case .forbiddenRateLimitReason:
            .http(status: 403, googleStatus: "PERMISSION_DENIED", reason: "RATE_LIMIT_EXCEEDED")
        case .forbiddenResourceExhausted: .http(status: 403, googleStatus: "RESOURCE_EXHAUSTED")
        case .malformedJSON: .malformedJSON
        }
    }

    var statusCode: Int? {
        switch self {
        case .unauthorized: 401
        case .rateLimited: 429
        case .unavailable: 503
        case .forbiddenPlain, .forbiddenServiceDisabled, .forbiddenScopeInsufficient, .forbiddenRateLimitReason,
            .forbiddenResourceExhausted:
            403
        case .malformedJSON: 200
        }
    }

    /// Treated as transient: the account stops calling until the backoff ends.
    var backsOff: Bool {
        switch self {
        case .rateLimited, .unavailable, .forbiddenRateLimitReason, .forbiddenResourceExhausted: true
        default: false
        }
    }
}

struct IsolationRig: Sendable {
    let server = FakeChatServer()
    let a: FakeAccount
    let b: FakeAccount
    let spaceA: SpaceName
    let spaceB: SpaceName
    let storeA = InMemoryAccountStore()
    let storeB = InMemoryAccountStore()
    let sessionA: AccountSession
    let sessionB: AccountSession
    let recA: SnapshotRecorder
    let recB: SnapshotRecorder
    let scratch = ScratchDirectory()
    let zed = User(name: UserName(unchecked: "users/777"), displayName: "Zed")

    init() {
        a = server.addAccount(displayName: "Alice")
        b = server.addAccount(displayName: "Bob")
        spaceA = server.addSpace(.space, displayName: "A space", members: [a])
        spaceB = server.addSpace(.space, displayName: "B space", members: [b])
        server.post("seed A", in: spaceA, from: .user(zed))
        server.post("seed B", in: spaceB, from: .user(zed))
        server.advance(.seconds(5))

        let clock = SteppingClock(server: server)
        let tombstones = LogoutTombstones(root: scratch.url)
        let (sessionA, sessionB) = (
            Self.makeSession(server, a, storeA, clock, tombstones),
            Self.makeSession(server, b, storeB, clock, tombstones)
        )
        self.sessionA = sessionA
        self.sessionB = sessionB
        recA = SnapshotRecorder(sessionA.snapshots.values)
        recB = SnapshotRecorder(sessionB.snapshots.values)
    }

    private static func makeSession(
        _ server: FakeChatServer, _ account: FakeAccount, _ store: InMemoryAccountStore, _ clock: SteppingClock,
        _ tombstones: LogoutTombstones
    ) -> AccountSession {
        AccountSession(
            account: AccountID(), me: account.user.name,
            api: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: account.token)),
            store: store, clock: clock, logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: tombstones),
            timing: .fast)
    }

    static func run(_ body: (IsolationRig) async throws -> Void) async throws {
        let rig = IsolationRig()
        await rig.sessionA.start()
        await rig.sessionB.start()
        do {
            let (spaceA, spaceB) = (rig.spaceA, rig.spaceB)
            let a = await rig.recA.wait { $0.status == .ok && $0.spaces.contains { $0.name == spaceA } }
            let b = await rig.recB.wait { $0.status == .ok && $0.spaces.contains { $0.name == spaceB } }
            #expect(a != nil && b != nil, "both accounts should sync before any failure is scripted")
            try await body(rig)
        } catch {
            await rig.shutdown()
            throw error
        }
        await rig.shutdown()
    }

    func shutdown() async {
        _ = await sessionA.logout(refreshToken: nil)
        _ = await sessionB.logout(refreshToken: nil)
    }

    func requests(of account: FakeAccount) -> [RecordedRequest] {
        server.requests.filter { $0.account == account }
    }

    func postAndAdvance(_ text: String, in space: SpaceName) {
        server.post(text, in: space, from: .user(zed))
        server.advance(.seconds(5))
    }

    func previewShows(_ text: String, in space: SpaceName) -> @Sendable (AccountSnapshot) -> Bool {
        { $0.spaces.first { $0.name == space }?.lastMessagePreview == text }
    }
}

struct IsolationTests {
    @Test(arguments: AccountFailure.allCases)
    func oneAccountFailingNeverAffectsTheOther(failure: AccountFailure) async throws {
        try await IsolationRig.run { rig in
            let response = try #require(failure.response)
            rig.server.fail(FailureRule(account: rig.a, route: .any, times: nil, response: response))

            rig.postAndAdvance("ping B", in: rig.spaceB)
            rig.postAndAdvance("ping A", in: rig.spaceA)

            let updated = await rig.recB.wait(where: rig.previewShows("ping B", in: rig.spaceB))
            #expect(updated != nil, "B did not see its new message while A was failing with \(failure)")

            switch failure {
            case .unauthorized:
                let needsLogin = await rig.recA.wait { $0.status == .needsLogin }
                #expect(needsLogin != nil)
                #expect(needsLogin?.spaces.contains { $0.name == rig.spaceA } == true, "A's cached spaces vanished")
            default:
                break
            }

            if failure.backsOff {
                let failed = await poll { rig.requests(of: rig.a).contains { $0.status == failure.statusCode } }
                #expect(failed)
                let before = rig.requests(of: rig.a).count
                try await Task.sleep(for: .milliseconds(40))
                #expect(rig.requests(of: rig.a).count == before, "A kept calling the API during its backoff")
                let published = rig.recA.history.contains {
                    if case .backingOff = $0.status { true } else { false }
                }
                #expect(published, "the UI never sees A as backing off")
            }

            let aStatuses = rig.recA.history.map(\.status)
            if failure != .unauthorized { #expect(!aStatuses.contains(.needsLogin)) }
            #expect(!aStatuses.contains(.closing))
            #expect(rig.recA.latest?.spaces.contains { $0.name == rig.spaceA } == true, "A's cached spaces vanished")
            #expect(rig.recA.latest?.spaces.first { $0.name == rig.spaceA }?.lastMessagePreview != "ping A")

            for status in rig.recB.history.map(\.status) {
                switch status {
                case .ok, .syncing, .starting: break
                default: Issue.record("B reported \(status) while only A was failing")
                }
            }
            #expect(rig.requests(of: rig.b).allSatisfy { $0.status == 200 })
            let storedA = try rig.storeA.spaces().map(\.space.name)
            let storedB = try rig.storeB.spaces().map(\.space.name)
            #expect(storedA == [rig.spaceA])
            #expect(storedB == [rig.spaceB])

            rig.server.clearFailures()
            if failure == .unauthorized { await rig.sessionA.resumeAfterLogin() }
            let recovered = await rig.recA.wait(where: rig.previewShows("ping A", in: rig.spaceA))
            #expect(recovered != nil, "A did not recover after the failure was cleared")
        }
    }

    @Test func aWriteOnly403FailsTheSendButTheSpaceStaysVisible() async throws {
        try await IsolationRig.run { rig in
            rig.server.fail(
                .permissionDenied(route: .createMessage, account: rig.a, space: rig.spaceA, times: nil))

            let item = try await rig.sessionA.send("announcement", in: rig.spaceA, thread: nil)

            let failed = await poll {
                (try? rig.sessionA.outbox(in: rig.spaceA))?.first { $0.id == item.id }?.state
                    == .failed(reason: "permissionDenied")
            }
            #expect(failed)
            let draft = try rig.sessionA.draft(space: rig.spaceA, thread: nil)
            #expect(draft?.text == "announcement")
            #expect(rig.server.messages(in: rig.spaceA).allSatisfy { $0.text != "announcement" })

            rig.postAndAdvance("still readable", in: rig.spaceA)
            let readable = await rig.recA.wait(where: rig.previewShows("still readable", in: rig.spaceA))
            #expect(readable != nil)
            let stored = try rig.sessionA.storedSpace(rig.spaceA)
            #expect(stored?.isHidden == false)
            #expect(rig.recA.history.allSatisfy { $0.status != .needsLogin })
            #expect(rig.recA.latest?.spaces.contains { $0.name == rig.spaceA } == true)
        }
    }

    @Test func a403OnReadStateDisablesOnlyThatFeature() async throws {
        try await IsolationRig.run { rig in
            rig.server.fail(
                .permissionDenied(route: .getSpaceReadState, account: rig.a, space: rig.spaceA, times: nil))

            rig.postAndAdvance("after 403", in: rig.spaceA)

            let synced = await rig.recA.wait(where: rig.previewShows("after 403", in: rig.spaceA))
            #expect(synced != nil, "messages stopped syncing after a read-state 403")
            let denied = rig.requests(of: rig.a).filter { $0.path.contains("spaceReadState") && $0.status == 403 }
            #expect(!denied.isEmpty, "the scripted 403 was never hit")
            let stored = try rig.sessionA.storedSpace(rig.spaceA)
            #expect(stored?.isHidden == false)
            #expect(rig.recA.history.allSatisfy { $0.status != .needsLogin })
            #expect(rig.recA.latest?.spaces.contains { $0.name == rig.spaceA } == true)
        }
    }

    @Test func a403OnAMessageReadKeepsTheSpaceUntilTheListingDropsIt() async throws {
        try await IsolationRig.run { rig in
            rig.server.fail(.permissionDenied(route: .listMessages, account: rig.a, space: rig.spaceA, times: nil))
            rig.postAndAdvance("unreadable", in: rig.spaceA)

            let hit = await poll {
                rig.requests(of: rig.a).contains { $0.path.hasSuffix("/messages") && $0.status == 403 }
            }
            #expect(hit, "the scripted 403 was never hit")
            let listings = rig.requests(of: rig.a).filter { $0.path.hasSuffix("/spaces") }.count
            let ticked = await poll {
                rig.requests(of: rig.a).filter { $0.path.hasSuffix("/spaces") }.count >= listings + 3
            }
            #expect(ticked, "A stopped polling")
            let visible = try rig.sessionA.storedSpace(rig.spaceA)
            #expect(visible?.isHidden == false, "hidden on a 403 alone")
            #expect(rig.recA.latest?.spaces.contains { $0.name == rig.spaceA } == true)

            let seen = rig.recA.history.count
            rig.server.removeMember(rig.a, from: rig.spaceA)
            let gone = await rig.recA.wait(since: seen) { !$0.spaces.contains { $0.name == rig.spaceA } }
            #expect(gone != nil, "the space stayed after a complete listing no longer contained it")
            let hidden = try rig.sessionA.storedSpace(rig.spaceA)
            #expect(hidden?.isHidden == true)

            rig.postAndAdvance("B unaffected", in: rig.spaceB)
            #expect(await rig.recB.wait(where: rig.previewShows("B unaffected", in: rig.spaceB)) != nil)
        }
    }
}
