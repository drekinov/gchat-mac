import ChatKeychain
import ChatModel
import ChatNet
import Foundation
import GoogleChat
import Network
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

        // A2: waiters of an older refresh never overwrite what a newer refresh stored.
        @Test func overlappingRefreshesApplyInOrder() async throws {
            fake.configure {
                $0.rotateRefreshTokens = true
                $0.latency = .milliseconds(60)
            }
            let provider = try provider()
            async let a = fetchToken(provider)
            async let b = fetchToken(provider)
            let first = try await a.get()
            #expect(try await b.get() == first)
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

        // A6: a stalled revoke gives up at the absolute deadline.
        @Test func revokeHonoursAnAbsoluteDeadline() async {
            fake.configure { $0.latency = .seconds(30) }
            let endpoints = OAuthEndpoints(
                transport: harness.transport, client: fake.client, revokeDeadline: .milliseconds(200))
            let started = ContinuousClock.now
            await endpoints.revoke("rt-seed")
            #expect(ContinuousClock.now - started < .seconds(2))
        }
    }
}

/// A4: idle connections are capped, time out, and are all closed when the flow ends.
struct LoopbackConnectionTests {
    @Test func idleConnectionsAreCappedAndClosedOnFinish() async throws {
        let listener = try await LoopbackListener.start(expectedState: "s")
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
