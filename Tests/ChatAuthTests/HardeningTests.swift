import ChatKeychain
import ChatModel
import ChatNet
import Foundation
import GoogleChat
import Network
import Synchronization
import Testing

@testable import ChatAuth

/// Sign-in and token lifecycle regression tests.
extension OAuthNetworkTests {
    @Suite struct SignInHardeningTests {
        let harness = OAuthHarness()
        let store = InMemorySecretStore()
        let gate = SessionGate()
        let account = AccountID()

        var fake: FakeGoogleOAuth { harness.fake }
        var vault: CredentialVault { CredentialVault(secrets: store) }

        func provider() throws -> OAuthTokenProvider {
            fake.seedRefreshToken("rt-seed")
            let credentials = StoredCredentials(
                client: fake.client, refreshToken: "rt-seed", grantedScope: FakeGoogleOAuth.allScopes,
                identity: .init(subject: "42", email: "ada@example.com", name: nil))
            try vault.saveInitial(credentials, for: account)
            return OAuthTokenProvider(
                account: account, credentials: credentials, endpoints: harness.endpoints, vault: vault, gate: gate,
                clock: harness.clock.reader)
        }

        // A2: overlapping callers share one refresh, and the next refresh stores the token it rotated to.
        @Test func overlappingRefreshesApplyInOrder() async throws {
            fake.configure { $0.rotateRefreshTokens = true }
            fake.holdTokens()
            defer { fake.releaseTokens() }
            let provider = try provider()
            let a = Recorded { await fetchToken(provider) }
            let b = Recorded { await fetchToken(provider) }
            try #require(await eventually { await provider.refreshWaiters == 2 })
            try #require(await eventually { fake.parkedTokenResponses == 1 })
            fake.releaseTokens()
            let first = try #require(await a.settled()).get()
            #expect(try #require(await b.settled()).get() == first)
            #expect(fake.tokenRequests().count == 1)

            await provider.invalidate(first)
            let second = try await fetchToken(provider).get()
            #expect(second != first)
            #expect(try vault.load(account)?.refreshToken == (await provider.refreshToken))
            #expect(fake.tokenRequests().count == 2)
        }

        // A5: a refresh that reports fewer scopes forces re-consent instead of failing on every API call.
        @Test func refreshWithMissingScopesNeedsReconsent() async throws {
            let provider = try provider()
            fake.configure { $0.scopeOverride = "openid email" }
            #expect(await fetchToken(provider) == .failure(.noCredentials))
            #expect(await provider.needsReconsent)
            #expect(try vault.load(account)?.grantedScope == "openid email")
            let requests = fake.tokenRequests().count
            #expect(await fetchToken(provider) == .failure(.noCredentials))
            #expect(fake.tokenRequests().count == requests)
        }

        @Test func refreshWithoutScopeKeepsTheStoredGrant() async throws {
            let provider = try provider()
            fake.configure { $0.omitScopeOnRefresh = true }
            _ = try await fetchToken(provider).get()
            #expect(try vault.load(account)?.grantedScope == FakeGoogleOAuth.allScopes)
        }

        @Test func refreshWithExplicitEmptyScopeNeedsReconsent() async throws {
            let provider = try provider()
            fake.configure { $0.scopeOverride = "" }
            #expect(await fetchToken(provider) == .failure(.noCredentials))
            #expect(await provider.needsReconsent)
        }
    }
}

/// A6: revoke ends at its deadline or with the response, whichever comes first, and cancels the other.
@Suite struct RevokeDeadlineTests {
    /// Answers only once `release` opens, ignoring cancellation apart from reporting it, with no timeout of its own.
    struct GatedTransport: HTTPTransport {
        let arrived = Gate()
        let release = Gate()
        let cancelled = Gate()
        let completed = Gate()

        func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse {
            arrived.open()
            await withTaskCancellationHandler {
                await release.waitThroughCancellation()
            } onCancel: {
                cancelled.open()
            }
            completed.open()
            return HTTPResponse(status: 200)
        }
    }

    final class Race: Sendable {
        let transport = GatedTransport()
        let asked = Mutex<[Duration]>([])
        let sleeping = Gate()
        let deadline = Gate()
        let sleepCancelled = Gate()
        let returned = Gate()
        private let reported = Mutex<[OAuthEndpoints.RevokeOutcome]>([])

        var outcomes: [OAuthEndpoints.RevokeOutcome] { reported.withLock { $0 } }

        func start() -> Task<Void, Never> {
            var endpoints = OAuthEndpoints(
                transport: transport, client: OAuthClientConfig(clientID: "id", clientSecret: "secret"))
            endpoints.sleep = { [self] duration in
                asked.withLock { $0.append(duration) }
                sleeping.open()
                await withTaskCancellationHandler {
                    await deadline.waitThroughCancellation()
                } onCancel: {
                    sleepCancelled.open()
                }
            }
            endpoints.onRevokeOutcome = { [self] outcome in reported.withLock { $0.append(outcome) } }
            return Task { [self, endpoints] in
                await endpoints.revoke("rt-seed")
                returned.open()
            }
        }

        func releaseAll() {
            transport.release.open()
            deadline.open()
        }
    }

    @Test func revokeReturnsAtTheDeadlineWhileTheResponseIsHeld() async throws {
        let race = Race()
        defer { race.releaseAll() }
        _ = race.start()
        try #require(await race.transport.arrived.opened())
        try #require(await race.sleeping.opened())

        #expect(race.asked.withLock { $0 } == [OAuthEndpoints.revokeDeadline])
        race.deadline.open()
        try #require(await race.returned.opened())
        #expect(race.outcomes == [.deadline])
        #expect(await race.transport.cancelled.opened())
    }

    /// A second task waiting to hear that the deadline passed would give a late response one more chance to win.
    @Test func theDeadlineIsClaimedByTheTaskThatWaitedForIt() async throws {
        let transport = GatedTransport()
        defer { transport.release.open() }
        let slept = Mutex<Int?>(nil)
        let claimed = Mutex<Int?>(nil)
        var endpoints = OAuthEndpoints(
            transport: transport, client: OAuthClientConfig(clientID: "id", clientSecret: "secret"))
        endpoints.sleep = { _ in slept.withLock { $0 = withUnsafeCurrentTask { $0?.hashValue } } }
        endpoints.onRevokeOutcome = { outcome in
            if outcome == .deadline { claimed.withLock { $0 = withUnsafeCurrentTask { $0?.hashValue } } }
        }
        let revoke = Recorded { [endpoints] in await endpoints.revoke("rt-seed") }
        try #require(await revoke.settled() != nil)
        let sleeper = try #require(slept.withLock { $0 })
        #expect(claimed.withLock { $0 } == sleeper)
    }

    @Test func revokeReturnsWithTheResponseAndStopsWaitingForTheDeadline() async throws {
        let race = Race()
        defer { race.releaseAll() }
        _ = race.start()
        try #require(await race.transport.arrived.opened())
        try #require(await race.sleeping.opened())

        race.transport.release.open()
        try #require(await race.returned.opened())
        #expect(race.outcomes == [.response])
        #expect(race.transport.completed.isOpen)
        #expect(await race.sleepCancelled.opened())
    }
}

/// The header deadlines a listener armed, for the test to run when it chooses.
final class HeaderDeadlines: Sendable {
    private let pending = Mutex<[@Sendable () -> Void]>([])

    var armed: Int { pending.withLock { $0.count } }

    var timer: LoopbackListener.HeaderTimer {
        { expire in self.pending.withLock { $0.append(expire) } }
    }

    func expireAll() {
        for expire in pending.withLock({ $0 }) { expire() }
    }
}

/// A4: idle connections are capped, time out, and are all closed when the flow ends.
@Suite(.timeLimit(.minutes(2))) struct LoopbackConnectionTests {
    func connect(to listener: LoopbackListener) throws -> NWConnection {
        let port = try #require(listener.redirectURI.port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) })
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        connection.start(queue: .global())
        return connection
    }

    @Test func aConnectionThatSendsNothingIsClosedAtItsHeaderDeadline() async throws {
        let deadlines = HeaderDeadlines()
        let listener = try await LoopbackListener.start(expectedState: "s", headerTimer: deadlines.timer)
        defer { listener.cancel() }
        let idle = try connect(to: listener)
        defer { idle.cancel() }
        try #require(await eventually { listener.openConnections == 1 && deadlines.armed == 1 })
        deadlines.expireAll()
        #expect(await eventually { listener.openConnections == 0 })
        #expect(listener.refusedConnections == 0)
    }

    @Test func idleConnectionsAreCappedAndClosedOnFinish() async throws {
        let listener = try await LoopbackListener.start(expectedState: "s", headerTimer: { _ in })
        defer { listener.cancel() }
        let port = try #require(listener.redirectURI.port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) })
        var idle: [NWConnection] = []
        defer { for connection in idle { connection.cancel() } }
        for _ in 0..<(LoopbackListener.maxConnections + 4) {
            let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
            connection.start(queue: .global())
            idle.append(connection)
        }
        let settled = await eventually { listener.openConnections + listener.refusedConnections == idle.count }
        try #require(settled)
        #expect(listener.openConnections == LoopbackListener.maxConnections)
        #expect(listener.refusedConnections == 4)
        listener.cancel()
        #expect(listener.openConnections == 0)
    }

    @Test func singleValuedAndStateChecks() {
        let ok = URLComponents(string: "/oauth2/callback?code=c&state=s")!
        let wrong = URLComponents(string: "/oauth2/callback?code=c&state=x")!
        let twice = URLComponents(string: "/oauth2/callback?code=c&state=s&state=s")!
        let none = URLComponents(string: "/oauth2/callback?code=c")!
        #expect(LoopbackListener.accepts(ok, expectedState: "s"))
        #expect(!LoopbackListener.accepts(wrong, expectedState: "s"))
        #expect(!LoopbackListener.accepts(twice, expectedState: "s"))
        #expect(!LoopbackListener.accepts(none, expectedState: "s"))
        #expect(LoopbackListener.accepts(none, expectedState: nil))
    }
}
