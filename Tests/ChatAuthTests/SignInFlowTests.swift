import ChatModel
import Foundation
import Testing

@testable import ChatAuth

extension OAuthNetworkTests {
    @Suite struct SignInFlowTests {
        let harness = OAuthHarness()
        var fake: FakeGoogleOAuth { harness.fake }

        /// A flow whose waits end only when the test ends them: its timeout when `timeout` fires, and no header
        /// deadline.
        func flow(_ browser: TestBrowser, timeout: ManualTimeout = ManualTimeout()) -> SignInFlow {
            var flow = SignInFlow(endpoints: harness.endpoints, browser: browser)
            flow.sleep = timeout.sleep
            flow.headerTimer = { _ in }
            return flow
        }

        func start(_ flow: SignInFlow) -> Recorded<Result<SignInResult, AuthError>> {
            Recorded {
                do throws(AuthError) { return .success(try await flow.run()) } catch { return .failure(error) }
            }
        }

        func browser(_ behavior: TestBrowser.Behavior = .approve) -> TestBrowser {
            TestBrowser(fake: fake, behavior: behavior)
        }

        @Test func happyPathReturnsCredentialsAndIdentity() async throws {
            let browser = browser()
            let result = try await runSignIn(flow(browser)).get()
            await browser.settle()

            let issued = try #require(fake.refreshTokensIssued.first)
            #expect(result.credentials.refreshToken == issued)
            #expect(result.credentials.grantedScope == FakeGoogleOAuth.allScopes)
            #expect(result.credentials.identity.subject == "112233445566778899001")
            #expect(result.credentials.identity.email == "ada@example.com")
            #expect(result.credentials.identity.name == "Ada Lovelace")
            #expect(result.credentials.client == fake.client)
            #expect(!result.credentials.needsReconsent)
            #expect(result.grant.accessToken.hasPrefix("at-"))
            #expect(result.grant.refreshToken == issued)
            #expect(browser.rejections.isEmpty)
            #expect(browser.redirectStatuses == [200])
        }

        @Test func fakeSawTheVerifierMatchingTheChallengeAndRedirect() async throws {
            let browser = browser()
            _ = try await runSignIn(flow(browser)).get()
            let url = try #require(browser.urls.first)
            let query = percentDecodedForm(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
            let exchange = try #require(fake.exchanges.first)
            #expect(FakeGoogleOAuth.challenge(for: exchange.verifier) == query["code_challenge"])
            #expect(exchange.redirectURI == query["redirect_uri"])
            #expect(query["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        }

        @Test func passesLoginHintToTheAuthorizationURL() async throws {
            let browser = browser()
            _ = try await runSignIn(flow(browser), loginHint: "ada@example.com").get()
            let query = percentDecodedForm(
                URLComponents(url: try #require(browser.urls.first), resolvingAgainstBaseURL: false)?
                    .percentEncodedQuery ?? "")
            #expect(query["login_hint"] == "ada@example.com")
        }

        @Test func eachRunUsesFreshStateVerifierAndPort() async throws {
            let first = browser()
            let second = browser()
            _ = try await runSignIn(flow(first)).get()
            _ = try await runSignIn(flow(second)).get()
            let queries = [first, second].map {
                percentDecodedForm(
                    URLComponents(url: $0.urls[0], resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
            }
            #expect(queries[0]["state"] != queries[1]["state"])
            #expect(queries[0]["code_challenge"] != queries[1]["code_challenge"])
            #expect(fake.exchanges.count == 2)
            #expect(fake.exchanges[0].verifier != fake.exchanges[1].verifier)
        }

        @Test func emailScopeURLAliasIsAccepted() async throws {
            let alias = OAuthScopes.required.map {
                $0 == "email" ? "https://www.googleapis.com/auth/userinfo.email" : $0
            }.joined(separator: " ")
            fake.configure { $0.scopeOverride = alias }
            let result = try await runSignIn(flow(browser())).get()
            #expect(result.credentials.grantedScope == alias)
            #expect(!result.credentials.needsReconsent)
        }

        @Test func denyIsAuthorizationDenied() async {
            let result = await runSignIn(flow(browser(.deny("access_denied"))))
            #expect(result == .failure(.authorizationDenied("access_denied")))
            #expect(fake.tokenRequests().isEmpty)
        }

        @Test func adminPolicyDenialKeepsItsCode() async {
            let result = await runSignIn(flow(browser(.deny("admin_policy_enforced"))))
            #expect(result == .failure(.authorizationDenied("admin_policy_enforced")))
        }

        @Test func denialCodeIsSanitized() async {
            let result = await runSignIn(
                flow(browser(.deny("Access Denied <b>!!" + String(repeating: "x", count: 100)))))
            guard case .failure(.authorizationDenied(let code)) = result else {
                Issue.record("expected denial, got \(result)")
                return
            }
            #expect(code.count <= 40)
            #expect(code.allSatisfy { ("a"..."z").contains($0) || $0 == "_" })
        }

        /// A wrong-state callback is refused at the listener and waiting continues, so only the timeout, fired here
        /// once the refusal has been answered, ends it.
        @Test func wrongStateIsRefusedWithoutExchangingTheCode() async throws {
            let browser = browser(.wrongState)
            let timeout = ManualTimeout()
            let signIn = start(flow(browser, timeout: timeout))
            defer { signIn.cancel() }
            try #require(await eventually { browser.redirectStatuses.count == 1 })
            #expect(browser.redirectStatuses == [400])
            timeout.fire()
            #expect(await signIn.settled() == .some(.failure(.timedOut)))
            #expect(fake.tokenRequests().isEmpty)
            #expect(fake.userinfoRequests.isEmpty)
        }

        @Test func duplicateStateIsRefusedWithoutExchangingTheCode() async throws {
            let browser = browser(.duplicateState)
            let timeout = ManualTimeout()
            let signIn = start(flow(browser, timeout: timeout))
            defer { signIn.cancel() }
            try #require(await eventually { browser.redirectStatuses.count == 1 })
            #expect(browser.redirectStatuses == [400])
            timeout.fire()
            #expect(await signIn.settled() == .some(.failure(.timedOut)))
            #expect(fake.tokenRequests().isEmpty)
        }

        @Test func forgedCallbacksBeforeTheRealOneDontAbortSignIn() async throws {
            let browser = browser(.forgedFirst)
            let result = try await runSignIn(flow(browser)).get()
            #expect(result.credentials.refreshToken.hasPrefix("rt-"))
            await browser.settle()
            #expect(browser.redirectStatuses == [400, 400, 400, 200])
        }

        @Test func missingCodeIsRejected() async {
            let result = await runSignIn(flow(browser(.missingCode)))
            #expect(result == .failure(.missingCode))
            #expect(fake.tokenRequests().isEmpty)
        }

        @Test func timesOutWhenNothingRedirects() async throws {
            let timeout = ManualTimeout()
            let signIn = start(flow(browser(.neverRedirect), timeout: timeout))
            defer { signIn.cancel() }
            try #require(await eventually { timeout.asked == [SignInFlow.defaultTimeout] })
            timeout.fire()
            #expect(await signIn.settled() == .some(.failure(.timedOut)))
            #expect(fake.tokenRequests().isEmpty)
        }

        @Test func browserThatCannotOpenIsUnavailable() async {
            let result = await runSignIn(flow(browser(.openFails)))
            #expect(result == .failure(.browserUnavailable))
            #expect(fake.tokenRequests().isEmpty)
        }

        @Test func cancellingTheTaskCancelsTheFlow() async throws {
            let browser = browser(.neverRedirect)
            let signIn = start(flow(browser))
            defer { signIn.cancel() }
            try #require(await eventually { !browser.urls.isEmpty })
            signIn.cancel()
            #expect(await signIn.settled() == .some(.failure(.cancelled)))
            #expect(fake.tokenRequests().isEmpty)
        }

        @Test func cancellationBeforeStartDoesNotHang() async {
            let flow = flow(browser(.neverRedirect))
            let signIn = Recorded { () async -> Result<SignInResult, AuthError> in
                withUnsafeCurrentTask { $0?.cancel() }
                do throws(AuthError) { return .success(try await flow.run()) } catch { return .failure(error) }
            }
            #expect(await signIn.settled() == .some(.failure(.cancelled)))
        }

        @Test func replayedRedirectIsRefusedAndDoesNotChangeTheResult() async throws {
            let browser = browser(.redirectTwice)
            let result = try await runSignIn(flow(browser)).get()
            await browser.settle()
            #expect(browser.redirectStatuses.count == 2)
            #expect(browser.redirectStatuses[0] == 200)
            #expect(browser.redirectStatuses[1] == nil)
            #expect(fake.exchanges.count == 1)
            #expect(result.credentials.refreshToken == fake.refreshTokensIssued.first)
        }

        @Test func tokenEndpointInvalidGrantKeepsOnlyTheCode() async {
            fake.script(
                .oauthError(code: "invalid_grant", description: "CANARY-description-7f3a"), for: .authorizationCode)
            let result = await runSignIn(flow(browser()))
            #expect(result == .failure(.tokenEndpoint(status: 400, code: "invalid_grant")))
            #expect(!String(describing: result).contains("CANARY"))
            #expect(fake.userinfoRequests.isEmpty)
        }

        @Test func tokenEndpointRedirectIsATransportErrorWithoutAURL() async {
            fake.script(.redirect(location: "https://evil.example/collect?c=1"), for: .authorizationCode)
            let result = await runSignIn(flow(browser()))
            guard case .failure(.transport(let detail)) = result else {
                Issue.record("expected transport failure, got \(result)")
                return
            }
            #expect(detail.contains("redirected"))
            #expect(!String(describing: result).contains("evil"))
            #expect(!detail.contains("http"))
            #expect(fake.seen.allSatisfy { $0.host != "evil.example" })
        }

        @Test func missingScopeIsInsufficientAndRevokesTheRefreshToken() async throws {
            let dropped = "https://www.googleapis.com/auth/chat.messages.create"
            let granted = OAuthScopes.required.filter { $0 != dropped }.joined(separator: " ")
            fake.configure { $0.scopeOverride = granted }
            let result = await runSignIn(flow(browser()))
            #expect(result == .failure(.insufficientScopes(missing: [dropped])))
            let issued = try #require(fake.refreshTokensIssued.first)
            #expect(fake.revokeRequests.map { $0.form["token"] } == [issued])
            #expect(fake.isRevoked(issued))
            #expect(fake.userinfoRequests.isEmpty)
        }

        @Test func noScopeInResponseIsInsufficient() async {
            fake.configure { $0.scopeOverride = "" }
            let result = await runSignIn(flow(browser()))
            #expect(result == .failure(.insufficientScopes(missing: OAuthScopes.required)))
        }

        @Test func reconnectRequiresTheSameSubjectAndKeepsAnExistingGrant() async throws {
            func reconnect(_ account: UserName) async -> Result<SignInResult, AuthError> {
                let flow = flow(browser())
                return await settle { () async throws(AuthError) in try await flow.run(reconnecting: account) }
            }
            let wrong = UserName(unchecked: "users/12")
            #expect(await reconnect(wrong) == .failure(.wrongAccount))
            let correct = UserName(unchecked: "users/112233445566778899001")
            let accepted = try await reconnect(correct).get()
            #expect(accepted.credentials.identity.subject == correct.id(at: 0))
            fake.configure { $0.scopeOverride = "" }
            #expect(await reconnect(correct) == .failure(.insufficientScopes(missing: OAuthScopes.required)))
            #expect(fake.revokeRequests.isEmpty)
        }

        @Test(arguments: ["abc", "123abc", "", "12 34", "-5", "1.5"])
        func nonNumericSubjectIsMalformed(sub: String) async {
            fake.configure { $0.subject = sub }
            let result = await runSignIn(flow(browser()))
            #expect(result == .failure(.malformedResponse("userinfo")))
        }

        @Test func nonASCIIDigitSubjectIsMalformed() async {
            fake.configure { $0.subject = "\u{0661}\u{0662}\u{0663}" }
            let result = await runSignIn(flow(browser()))
            #expect(result == .failure(.malformedResponse("userinfo")))
        }

        @Test func unverifiedEmailIsMalformed() async {
            fake.configure { $0.emailVerified = false }
            let result = await runSignIn(flow(browser()))
            #expect(result == .failure(.malformedResponse("userinfo")))
        }

        @Test func absentEmailVerifiedIsTolerated() async throws {
            fake.configure { $0.emailVerified = nil }
            let result = try await runSignIn(flow(browser())).get()
            #expect(result.credentials.identity.email == "ada@example.com")
        }

        @Test func userinfoFailureFailsTheFlow() async {
            fake.scriptUserinfo(.oauthError(status: 401, code: "invalid_token"))
            let result = await runSignIn(flow(browser()))
            #expect(result == .failure(.tokenEndpoint(status: 401, code: nil)))
        }
    }
}
