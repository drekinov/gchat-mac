import ChatKeychain
import ChatModel
import Foundation
import GoogleChat
import Testing

@testable import ChatAuth

extension OAuthNetworkTests {
    @Suite struct TokenProviderTests {
        let harness = OAuthHarness()
        let store = InMemorySecretStore()
        let gate = SessionGate()
        let account = AccountID()
        let refreshToken = "rt-seed"

        var fake: FakeGoogleOAuth { harness.fake }
        var clock: TestClock { harness.clock }
        var vault: CredentialVault { CredentialVault(secrets: store) }

        func credentials(scope: String = FakeGoogleOAuth.allScopes) -> StoredCredentials {
            StoredCredentials(
                client: fake.client, refreshToken: refreshToken, grantedScope: scope,
                identity: .init(subject: "42", email: "ada@example.com", name: nil))
        }

        func provider(scope: String = FakeGoogleOAuth.allScopes, seed: Bool = true) throws -> OAuthTokenProvider {
            if seed { fake.seedRefreshToken(refreshToken) }
            try vault.saveInitial(credentials(scope: scope), for: account)
            return OAuthTokenProvider(
                account: account, credentials: credentials(scope: scope), endpoints: harness.endpoints, vault: vault,
                gate: gate, clock: clock.reader)
        }

        func storedRefreshToken() throws -> String? { try vault.load(account)?.refreshToken }

        @Test func firstCallRefreshesAndSecondIsCached() async throws {
            let provider = try provider()
            let first = try await fetchToken(provider).get()
            let second = try await fetchToken(provider).get()
            #expect(first == second)
            #expect(fake.tokenRequests(.refreshToken).count == 1)
            #expect(fake.tokenRequests(.refreshToken).first?.form["refresh_token"] == refreshToken)
        }

        @Test func primedGrantNeedsNoRefresh() async throws {
            let provider = try provider()
            await provider.prime(
                TokenGrant(
                    accessToken: "primed", expiresAt: clock.now.adding(.seconds(100)), refreshToken: nil, scope: ""))
            #expect(try await fetchToken(provider).get() == "primed")
            #expect(fake.tokenRequests().isEmpty)
        }

        @Test func tokenIsRefreshedAtTheExpiryMarginBoundary() async throws {
            let provider = try provider()
            let first = try await fetchToken(provider).get()
            clock.advance(seconds: 3539)
            #expect(try await fetchToken(provider).get() == first)
            #expect(fake.tokenRequests().count == 1)
            clock.advance(seconds: 1)
            let renewed = try await fetchToken(provider).get()
            #expect(renewed != first)
            #expect(fake.tokenRequests().count == 2)
        }

        @Test func expiryCountsFromRequestStartNotResponseArrival() async throws {
            fake.holdTokens()
            defer { fake.releaseTokens() }
            let provider = try provider()
            let pending = Task { await fetchToken(provider) }
            try #require(await eventually { fake.parkedTokenResponses == 1 })
            clock.advance(seconds: 200)
            fake.releaseTokens()
            let first = try await pending.value.get()
            clock.advance(seconds: 3339)
            #expect(try await fetchToken(provider).get() == first)
            clock.advance(seconds: 1)
            #expect(try await fetchToken(provider).get() != first)
        }

        @Test func tokenWithLifetimeUnderTheMarginIsNeverCached() async throws {
            fake.configure { $0.expiresIn = 45 }
            let provider = try provider()
            _ = try await fetchToken(provider).get()
            _ = try await fetchToken(provider).get()
            #expect(fake.tokenRequests().count == 2)
        }

        @Test func concurrentCallsShareOneRefresh() async throws {
            fake.holdTokens()
            defer { fake.releaseTokens() }
            let provider = try provider()
            let (joined, tokens) = await withTaskGroup(of: Result<String, ChatAPIError>.self) { group in
                for _ in 0..<12 { group.addTask { await fetchToken(provider) } }
                let joined = await eventually { await provider.refreshWaiters == 12 }
                fake.releaseTokens()
                var all: [Result<String, ChatAPIError>] = []
                for await result in group { all.append(result) }
                return (joined, all)
            }
            try #require(joined)
            let values = try tokens.map { try $0.get() }
            #expect(values.count == 12)
            #expect(Set(values).count == 1)
            #expect(fake.tokenRequests().count == 1)
        }

        @Test func concurrentCallsAllFailTogetherAndAllowALaterRetry() async throws {
            fake.holdTokens()
            defer { fake.releaseTokens() }
            let provider = try provider()
            fake.script(.network(.networkConnectionLost))
            let (joined, results) = await withTaskGroup(of: Result<String, ChatAPIError>.self) { group in
                for _ in 0..<5 { group.addTask { await fetchToken(provider) } }
                let joined = await eventually { await provider.refreshWaiters == 5 }
                fake.releaseTokens()
                var all: [Result<String, ChatAPIError>] = []
                for await result in group { all.append(result) }
                return (joined, all)
            }
            try #require(joined)
            #expect(results.allSatisfy { $0 == .failure(.transport(.connectionLost)) })
            #expect(fake.tokenRequests().count == 1)
            #expect(try await fetchToken(provider).get().hasPrefix("at-"))
            #expect(fake.tokenRequests().count == 2)
        }

        @Test func invalidateForcesARefresh() async throws {
            let provider = try provider()
            let first = try await fetchToken(provider).get()
            await provider.invalidate("some-other-token")
            #expect(try await fetchToken(provider).get() == first)
            #expect(fake.tokenRequests().count == 1)
            await provider.invalidate(first)
            let second = try await fetchToken(provider).get()
            #expect(second != first)
            #expect(fake.tokenRequests().count == 2)
        }

        @Test func invalidGrantIsPermanentNoCredentials() async throws {
            let provider = try provider()
            fake.revokeRefreshToken(refreshToken)
            #expect(await fetchToken(provider) == .failure(.noCredentials))
            #expect(await provider.isRevoked)
            let before = fake.seen.count
            for _ in 0..<3 { #expect(await fetchToken(provider) == .failure(.noCredentials)) }
            #expect(fake.seen.count == before)
        }

        @Test func invalidGrantErrorDescriptionDoesNotLeak() async throws {
            let provider = try provider()
            fake.script(.oauthError(code: "invalid_grant", description: "CANARY"))
            let result = await fetchToken(provider)
            #expect(result == .failure(.noCredentials))
            #expect(!String(describing: result).contains("CANARY"))
        }

        @Test(arguments: [
            (400, "unauthorized_client"), (401, "invalid_client"), (401, "invalid_grant"), (400, "invalid_request"),
            (400, "invalid_scope"),
        ])
        func otherPermanentRejectionsAlsoStopRefreshing(status: Int, code: String) async throws {
            let provider = try provider()
            fake.script(.oauthError(status: status, code: code))
            #expect(await fetchToken(provider) == .failure(.noCredentials))
            #expect(await provider.isRevoked)
            #expect(await fetchToken(provider) == .failure(.noCredentials))
            #expect(fake.tokenRequests().count == 1)
        }

        @Test(arguments: [
            FakeGoogleOAuth.Reply.raw(status: 500, body: "<html>"),
            .raw(status: 503, body: #"{"error":"backend_error"}"#),
            .oauthError(status: 429, code: "invalid_grant"),
            .oauthError(status: 500, code: "invalid_grant"),
            .raw(status: 200, body: "not json"),
            .redirect(location: "https://evil.example/"),
        ])
        func transientFailuresAreRetryableAndNotPermanent(reply: FakeGoogleOAuth.Reply) async throws {
            let provider = try provider()
            fake.script(reply)
            let result = await fetchToken(provider)
            guard case .failure(.transport) = result else {
                Issue.record("expected transport failure, got \(result)")
                return
            }
            #expect(!(await provider.isRevoked))
            #expect(try await fetchToken(provider).get().hasPrefix("at-"))
        }

        @Test func networkFailureIsTransportAndRecovers() async throws {
            let provider = try provider()
            fake.script(.network(.notConnectedToInternet))
            #expect(await fetchToken(provider) == .failure(.transport(.connectionLost)))
            let token = try await fetchToken(provider).get()
            #expect(token.hasPrefix("at-"))
            #expect(try await fetchToken(provider).get() == token)
        }

        @Test func rotationIsPersistedToTheVaultAndUsedNext() async throws {
            fake.configure { $0.rotateRefreshTokens = true }
            let provider = try provider()
            _ = try await fetchToken(provider).get()
            let rotated = try #require(try storedRefreshToken())
            #expect(rotated != refreshToken)
            #expect(await provider.refreshToken == rotated)
            #expect(try vault.load(account)?.identity.email == "ada@example.com")

            clock.advance(seconds: 4000)
            _ = try await fetchToken(provider).get()
            #expect(fake.tokenRequests().last?.form["refresh_token"] == rotated)
            #expect(try storedRefreshToken() != rotated)
        }

        @Test func unchangedRefreshTokenIsNotRewritten() async throws {
            let provider = try provider()
            store.setFailure(.interactionNotAllowed, for: CredentialVault.secretID(for: account))
            #expect(try await fetchToken(provider).get().hasPrefix("at-"))
        }

        @Test func rotationSurvivesAVaultWriteFailureInMemory() async throws {
            fake.configure { $0.rotateRefreshTokens = true }
            let provider = try provider()
            store.setFailure(.interactionNotAllowed, for: CredentialVault.secretID(for: account))
            let token = try await fetchToken(provider).get()
            #expect(token.hasPrefix("at-"))
            let rotated = await provider.refreshToken
            #expect(rotated != refreshToken)
            store.setFailure(nil, for: CredentialVault.secretID(for: account))
            #expect(try storedRefreshToken() == refreshToken)
            clock.advance(seconds: 4000)
            _ = try await fetchToken(provider).get()
            #expect(fake.tokenRequests().last?.form["refresh_token"] == rotated)
        }

        @Test func retiredGateRefusesWithoutNetwork() async throws {
            let provider = try provider()
            gate.retire()
            #expect(await fetchToken(provider) == .failure(.noCredentials))
            #expect(fake.seen.isEmpty)
        }

        @Test func retiredGateRefusesEvenACachedToken() async throws {
            let provider = try provider()
            _ = try await fetchToken(provider).get()
            gate.retire()
            #expect(await fetchToken(provider) == .failure(.noCredentials))
        }

        @Test func oldProviderStaysDeadAfterRelogin() async throws {
            let provider = try provider()
            gate.retire()
            _ = gate.activate()
            #expect(await fetchToken(provider) == .failure(.noCredentials))
            #expect(fake.seen.isEmpty)
        }

        @Test func providerCreatedOnInactiveGateNeverWorks() async throws {
            gate.retire()
            let provider = try provider()
            _ = gate.activate()
            #expect(await fetchToken(provider) == .failure(.noCredentials))
        }

        @Test func rotationArrivingAfterRetireIsNotWritten() async throws {
            fake.configure { $0.rotateRefreshTokens = true }
            fake.holdTokens()
            defer { fake.releaseTokens() }
            let provider = try provider()
            let pending = Task { await fetchToken(provider) }
            try #require(await eventually { fake.parkedTokenResponses == 1 })
            gate.retire()
            fake.releaseTokens()
            #expect(await pending.value == .failure(.noCredentials))
            #expect(try storedRefreshToken() == refreshToken)
            #expect(await provider.refreshToken == refreshToken)
        }

        @Test func retireDuringRefreshAfterLogoutDeleteDoesNotResurrectTheEntry() async throws {
            fake.configure { $0.rotateRefreshTokens = true }
            fake.holdTokens()
            defer { fake.releaseTokens() }
            let provider = try provider()
            let pending = Task { await fetchToken(provider) }
            try #require(await eventually { fake.parkedTokenResponses == 1 })
            gate.retire()
            try vault.delete(account)
            fake.releaseTokens()
            _ = await pending.value
            #expect(try vault.load(account) == nil)
            #expect(store.storedIDs.isEmpty)
        }

        @Test func needsReconsentCredentialsNeverTouchTheNetwork() async throws {
            let provider = try provider(scope: "openid email")
            #expect(await fetchToken(provider) == .failure(.noCredentials))
            #expect(fake.seen.isEmpty)
        }

        @Test func primedTokenIsIgnoredWhenReconsentIsNeeded() async throws {
            let provider = try provider(scope: "openid")
            await provider.prime(
                TokenGrant(
                    accessToken: "primed", expiresAt: clock.now.adding(.seconds(100)), refreshToken: nil, scope: ""))
            #expect(await fetchToken(provider) == .failure(.noCredentials))
        }
    }
}
