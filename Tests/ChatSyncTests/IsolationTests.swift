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
    let world: SimWorld
    let server: FakeChatServer
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
    /// A's own, so the test can move A's time while B's stands still.
    let clockA: SimClock
    let zed = User(name: UserName(unchecked: "users/777"), displayName: "Zed")

    init(_ world: SimWorld) {
        self.world = world
        server = world.server
        a = server.addAccount(displayName: "Alice")
        b = server.addAccount(displayName: "Bob")
        spaceA = server.addSpace(.space, displayName: "A space", members: [a])
        spaceB = server.addSpace(.space, displayName: "B space", members: [b])
        server.post("seed A", in: spaceA, from: .user(zed))
        server.post("seed B", in: spaceB, from: .user(zed))
        server.advance(.seconds(5))

        clockA = world.clock()
        let scratch = ScratchDirectory()
        sessionA = world.syncSession(a, store: storeA, clock: clockA, timing: .syncPolling, scratch: scratch)
        sessionB = world.syncSession(b, store: storeB, timing: .syncPolling, scratch: scratch)
        recA = SnapshotRecorder(sessionA.snapshots.values, in: world)
        recB = SnapshotRecorder(sessionB.snapshots.values, in: world)
    }

    /// Runs `body` in a world where both accounts have finished their first sync.
    static func run(_ body: @escaping @Sendable (IsolationRig) async throws -> Void) async throws {
        try await SimWorld.run { world in
            let rig = IsolationRig(world)
            await rig.sessionA.start()
            await rig.sessionB.start()
            let (spaceA, spaceB) = (rig.spaceA, rig.spaceB)
            let a = await rig.recA.wait(in: world) { $0.status == .ok && $0.spaces.contains { $0.name == spaceA } }
            let b = await rig.recB.wait(in: world) { $0.status == .ok && $0.spaces.contains { $0.name == spaceB } }
            try #require(a != nil && b != nil, "both accounts sync before any failure is scripted")
            await world.settle()
            try await body(rig)
        }
    }

    func requests(of account: FakeAccount) -> [RecordedRequest] {
        server.requests.filter { $0.account == account }
    }

    func listings(of account: FakeAccount) -> Int { world.syncRequests(of: account, "GET", suffix: "/spaces") }

    /// Walks A's clock alone through a back-off. A wake while it stands asks for a catch-up but calls nothing, and
    /// the call comes when the deadline arrives.
    func expectAWaitsOutItsBackoff() async throws {
        await world.settle()
        let until = try #require(await sessionA.retryUntil, "A never settled into a backoff")
        try #require(until > clockA.now())
        let before = requests(of: a).count

        await clockA.advance(by: until.interval(since: clockA.now()) - .milliseconds(1))
        await sessionA.systemDidWake()
        await world.settle()
        #expect(await sessionA.catchUpPending)
        #expect(requests(of: a).count == before, "A kept calling the API during its backoff")

        await clockA.advance(by: .milliseconds(1))
        #expect(requests(of: a).count > before, "A never called again after its backoff")
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
            let world = rig.world
            let response = try #require(failure.response)
            rig.server.fail(FailureRule(account: rig.a, route: .any, times: nil, response: response))

            rig.postAndAdvance("ping B", in: rig.spaceB)
            rig.postAndAdvance("ping A", in: rig.spaceA)

            let updated = await rig.recB.wait(in: world, where: rig.previewShows("ping B", in: rig.spaceB))
            #expect(updated != nil, "B did not see its new message while A was failing with \(failure)")
            #expect(
                await world.run { rig.requests(of: rig.a).contains { $0.status == failure.statusCode } },
                "the scripted failure was never hit")

            if failure == .unauthorized {
                let needsLogin = await rig.recA.wait(in: world) { $0.status == .needsLogin }
                #expect(needsLogin != nil)
                #expect(needsLogin?.spaces.contains { $0.name == rig.spaceA } == true, "A's cached spaces vanished")
            }

            if failure.backsOff {
                try await rig.expectAWaitsOutItsBackoff()
                await world.settle()
                if case .backingOff = rig.recA.latest?.status {
                } else {
                    Issue.record("the UI doesn't see A backing off: \(String(describing: rig.recA.latest?.status))")
                }
            }

            // Both accounts go on polling, A failing every time.
            let (pollsA, pollsB) = (rig.listings(of: rig.a), rig.listings(of: rig.b))
            #expect(await world.run { rig.listings(of: rig.b) >= pollsB + 3 }, "B stopped polling")
            if failure != .unauthorized { #expect(rig.listings(of: rig.a) > pollsA, "A stopped polling") }
            let aStatuses = rig.recA.history.map(\.status)
            if failure != .unauthorized { #expect(!aStatuses.contains(.needsLogin)) }
            #expect(!aStatuses.contains(.closing))
            #expect(rig.recA.latest?.spaces.contains { $0.name == rig.spaceA } == true, "A's cached spaces vanished")
            #expect(rig.recA.latest?.spaces.first { $0.name == rig.spaceA }?.lastMessagePreview == "seed A")

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
            let recovered = await rig.recA.wait(in: world, where: rig.previewShows("ping A", in: rig.spaceA))
            #expect(recovered != nil, "A did not recover after the failure was cleared")
        }
    }

    @Test func aWriteOnly403FailsTheSendButTheSpaceStaysVisible() async throws {
        try await IsolationRig.run { rig in
            let world = rig.world
            rig.server.fail(
                .permissionDenied(route: .createMessage, account: rig.a, space: rig.spaceA, times: nil))

            let item = try await rig.sessionA.send("announcement", in: rig.spaceA, thread: nil)
            await world.settle()

            let sent = try rig.sessionA.outbox(in: rig.spaceA).first { $0.id == item.id }
            #expect(sent?.state == .failed(reason: "permissionDenied"))
            let draft = try rig.sessionA.draft(space: rig.spaceA, thread: nil)
            #expect(draft?.text == "announcement")
            #expect(rig.server.messages(in: rig.spaceA).allSatisfy { $0.text != "announcement" })

            rig.postAndAdvance("still readable", in: rig.spaceA)
            let readable = await rig.recA.wait(in: world, where: rig.previewShows("still readable", in: rig.spaceA))
            #expect(readable != nil)
            let stored = try rig.sessionA.storedSpace(rig.spaceA)
            #expect(stored?.isHidden == false)
            #expect(rig.recA.history.allSatisfy { $0.status != .needsLogin })
            #expect(rig.recA.latest?.spaces.contains { $0.name == rig.spaceA } == true)
        }
    }

    @Test func a403OnReadStateDisablesOnlyThatFeature() async throws {
        try await IsolationRig.run { rig in
            let world = rig.world
            rig.server.fail(
                .permissionDenied(route: .getSpaceReadState, account: rig.a, space: rig.spaceA, times: nil))

            rig.postAndAdvance("after 403", in: rig.spaceA)

            let synced = await rig.recA.wait(in: world, where: rig.previewShows("after 403", in: rig.spaceA))
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
            let world = rig.world
            rig.server.fail(.permissionDenied(route: .listMessages, account: rig.a, space: rig.spaceA, times: nil))
            rig.postAndAdvance("unreadable", in: rig.spaceA)

            let hit = await world.run {
                rig.requests(of: rig.a).contains { $0.path.hasSuffix("/messages") && $0.status == 403 }
            }
            #expect(hit, "the scripted 403 was never hit")
            let listings = rig.listings(of: rig.a)
            #expect(await world.run { rig.listings(of: rig.a) >= listings + 3 }, "A stopped polling")
            let visible = try rig.sessionA.storedSpace(rig.spaceA)
            #expect(visible?.isHidden == false, "hidden on a 403 alone")
            #expect(rig.recA.latest?.spaces.contains { $0.name == rig.spaceA } == true)

            let seen = rig.recA.history.count
            rig.server.removeMember(rig.a, from: rig.spaceA)
            let gone = await rig.recA.wait(in: world, since: seen) { !$0.spaces.contains { $0.name == rig.spaceA } }
            #expect(gone != nil, "the space stayed after a complete listing no longer contained it")
            let hidden = try rig.sessionA.storedSpace(rig.spaceA)
            #expect(hidden?.isHidden == true)

            rig.postAndAdvance("B unaffected", in: rig.spaceB)
            #expect(await rig.recB.wait(in: world, where: rig.previewShows("B unaffected", in: rig.spaceB)) != nil)
        }
    }
}
