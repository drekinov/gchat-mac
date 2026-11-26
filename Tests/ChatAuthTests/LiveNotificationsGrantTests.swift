import ChatKeychain
import ChatModel
import Foundation
import Testing

@testable import ChatAuth

extension OAuthNetworkTests {
    @Suite struct LiveNotificationsGrantTests {
        let harness = OAuthHarness()
        let store = InMemorySecretStore()
        let account = AccountID()
        let me = UserName(unchecked: "users/112233445566778899001")
        var fake: FakeGoogleOAuth { harness.fake }
        var vault: CredentialVault { CredentialVault(secrets: store) }

        /// A flow that takes no time of its own: no timeout and no header deadline can end it.
        func flow(_ browser: TestBrowser? = nil) -> SignInFlow {
            var flow = SignInFlow(
                endpoints: harness.endpoints, browser: browser ?? TestBrowser(fake: fake, behavior: .approve))
            flow.sleep = ManualTimeout().sleep
            flow.headerTimer = { _ in }
            return flow
        }

        func seedOld() throws -> StoredCredentials {
            let old = StoredCredentials(
                client: fake.client, refreshToken: "rt-old", grantedScope: FakeGoogleOAuth.allScopes,
                identity: .init(subject: "112233445566778899001", email: "ada@example.com", name: nil))
            try vault.saveInitial(old, for: account)
            return old
        }

        /// What the app does: the new credentials are written only when the grant verified.
        func grant(as account: UserName? = nil) async -> Result<SignInResult, AuthError> {
            let flow = flow()
            let account = account ?? me
            let granted = await settle { () async throws(AuthError) in
                try await flow.grantLiveNotifications(account: account, loginHint: nil)
            }
            do {
                let result = try granted.get()
                try vault.saveInitial(result.credentials, for: self.account)
                return .success(result)
            } catch {
                return .failure(error)
            }
        }

        func requestedScopes(_ url: URL?) -> Set<String> {
            let query = percentDecodedForm(
                url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery } ?? "")
            return Set((query["scope"] ?? "").split(separator: " ").map(String.init))
        }

        @Test func ordinarySignInNeverAsksForPubSub() async throws {
            let browser = TestBrowser(fake: fake, behavior: .approve)
            let result = try await runSignIn(flow(browser)).get()
            #expect(!requestedScopes(browser.urls.first).contains(OAuthScopes.pubsub))
            #expect(!OAuthScopes.hasPubSub(result.credentials.grantedScope))
            #expect(!OAuthScopes.required.contains(OAuthScopes.pubsub))
            #expect(!OAuthScopes.optional.contains(OAuthScopes.pubsub))
        }

        @Test func theGrantIsAFreshConsentForTheWholeSetPlusPubSub() async throws {
            let browser = TestBrowser(fake: fake, behavior: .approve)
            let flow = flow(browser)
            let me = me
            _ = try await settle { () async throws(AuthError) in
                try await flow.grantLiveNotifications(account: me, loginHint: "ada@example.com")
            }.get()
            let url = try #require(browser.urls.first)
            let query = percentDecodedForm(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
            #expect(
                requestedScopes(url) == Set(OAuthScopes.required + OAuthScopes.optional + [OAuthScopes.pubsub]))
            #expect(query["include_granted_scopes"] == "false")
            #expect(query["prompt"]?.contains("consent") == true)
            #expect(query["login_hint"] == "ada@example.com")
        }

        @Test func aMatchingGrantReplacesTheStoredCredentials() async throws {
            let old = try seedOld()
            let result = try await grant().get()
            let stored = try #require(try vault.load(account))
            #expect(stored == result.credentials)
            #expect(stored.refreshToken != old.refreshToken)
            #expect(OAuthScopes.hasPubSub(stored.grantedScope))
            #expect(!stored.needsReconsent)
        }

        @Test func aGrantWithoutPubSubKeepsTheOldCredentials() async throws {
            let old = try seedOld()
            fake.configure { $0.scopeOverride = FakeGoogleOAuth.allScopes }
            #expect(await grant() == .failure(.insufficientScopes(missing: [OAuthScopes.pubsub])))
            #expect(try vault.load(account) == old)
            #expect(fake.revokeRequests.isEmpty, "the account's existing grant is never revoked")
        }

        @Test func aGrantMissingARegularScopeKeepsTheOldCredentials() async throws {
            let old = try seedOld()
            let partial = (OAuthScopes.required.dropLast() + [OAuthScopes.pubsub]).joined(separator: " ")
            fake.configure { $0.scopeOverride = partial }
            #expect(await grant() == .failure(.insufficientScopes(missing: [OAuthScopes.required.last!])))
            #expect(try vault.load(account) == old)
        }

        @Test func aGrantForAnotherAccountKeepsTheOldCredentials() async throws {
            let old = try seedOld()
            fake.configure { $0.subject = "998877665544332211009" }
            #expect(await grant() == .failure(.wrongAccount))
            #expect(try vault.load(account) == old)
        }
    }
}
