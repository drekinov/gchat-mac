import ChatModel
import ChatNet
import Foundation
import Testing

@testable import ChatAuth

extension OAuthNetworkTests {
    @Suite struct EndpointsTests {
        let harness = OAuthHarness()
        var fake: FakeGoogleOAuth { harness.fake }
        var endpoints: OAuthEndpoints { harness.endpoints }
        let redirect = URL(string: "http://127.0.0.1:50000/oauth2/callback")!

        func authorizedCode(_ pkce: PKCE) throws -> String {
            let url = endpoints.authorizationURL(pkce: pkce, redirectURI: redirect, loginHint: nil)
            return try fake.issueCode(for: url).get()
        }

        func exchange(
            _ code: String, _ pkce: PKCE, redirect: URL? = nil
        ) async -> Result<TokenGrant, AuthError> {
            do {
                return .success(
                    try await endpoints.exchange(code: code, pkce: pkce, redirectURI: redirect ?? self.redirect))
            } catch { return .failure(error) }
        }

        func refresh(_ token: String) async -> Result<TokenGrant, AuthError> {
            do { return .success(try await endpoints.refresh(token)) } catch { return .failure(error) }
        }

        @Test func exchangeReturnsGrantWithExpiryCountedFromRequestStart() async throws {
            let pkce = PKCE()
            let code = try authorizedCode(pkce)
            let grant = try await exchange(code, pkce).get()
            #expect(grant.accessToken.hasPrefix("at-"))
            #expect(grant.refreshToken?.hasPrefix("rt-") == true)
            #expect(grant.scope == FakeGoogleOAuth.allScopes)
            #expect(grant.expiresAt == TestClock.start.adding(.seconds(3540)))
        }

        @Test func exchangeRequestShape() async throws {
            let pkce = PKCE()
            _ = await exchange(try authorizedCode(pkce), pkce)
            let request = try #require(fake.tokenRequests(.authorizationCode).first)
            #expect(request.method == "POST")
            #expect(request.host == "oauth2.googleapis.com")
            #expect(request.headers["content-type"] == "application/x-www-form-urlencoded")
            #expect(request.headers["authorization"] == nil)
            #expect(request.form["client_id"] == fake.clientID)
            #expect(request.form["client_secret"] == fake.clientSecret)
            #expect(request.form["code_verifier"] == pkce.verifier)
            #expect(request.form["redirect_uri"] == redirect.absoluteString)
        }

        @Test func formEncodingRoundTripsReservedCharacters() async {
            let weird = "a&b=c+d e%20f/é"
            _ = await exchange(weird, PKCE())
            #expect(fake.tokenRequests().first?.form["code"] == weird)
        }

        @Test func codeIsSingleUse() async throws {
            let pkce = PKCE()
            let code = try authorizedCode(pkce)
            _ = try await exchange(code, pkce).get()
            let second = await exchange(code, pkce)
            #expect(second == .failure(.tokenEndpoint(status: 400, code: "invalid_grant")))
        }

        @Test func wrongVerifierIsRejected() async throws {
            let pkce = PKCE()
            let code = try authorizedCode(pkce)
            let result = await exchange(code, PKCE())
            #expect(result == .failure(.tokenEndpoint(status: 400, code: "invalid_grant")))
        }

        @Test func redirectURIMismatchIsRejected() async throws {
            let pkce = PKCE()
            let code = try authorizedCode(pkce)
            let result = await exchange(code, pkce, redirect: URL(string: "http://127.0.0.1:1/oauth2/callback")!)
            #expect(result == .failure(.tokenEndpoint(status: 400, code: "redirect_uri_mismatch")))
        }

        @Test func wrongClientSecretIsInvalidClient() async throws {
            let wrong = OAuthEndpoints(
                transport: harness.transport, client: OAuthClientConfig(clientID: fake.clientID, clientSecret: "nope"),
                clock: harness.clock.reader)
            let result: Result<TokenGrant, AuthError>
            do { result = .success(try await wrong.refresh(fake.seedRefreshToken())) } catch {
                result = .failure(error)
            }
            #expect(result == .failure(.tokenEndpoint(status: 401, code: "invalid_client")))
        }

        @Test func refreshReturnsAccessTokenWithoutRefreshTokenByDefault() async throws {
            let token = fake.seedRefreshToken()
            let grant = try await refresh(token).get()
            #expect(grant.refreshToken == nil)
            #expect(fake.tokenRequests(.refreshToken).first?.form["refresh_token"] == token)
        }

        @Test func refreshRotationSurfacesTheNewToken() async throws {
            fake.configure { $0.rotateRefreshTokens = true }
            let grant = try await refresh(fake.seedRefreshToken()).get()
            #expect(grant.refreshToken != nil)
            #expect(grant.refreshToken != "rt-seed")
        }

        @Test func revokedRefreshTokenIsInvalidGrant() async {
            let token = fake.seedRefreshToken()
            fake.revokeRefreshToken(token)
            #expect(await refresh(token) == .failure(.tokenEndpoint(status: 400, code: "invalid_grant")))
        }

        @Test func exchangeWithoutRefreshTokenIsMalformed() async throws {
            let pkce = PKCE()
            let code = try authorizedCode(pkce)
            fake.script(
                .raw(
                    status: 200,
                    body: #"{"access_token":"a","expires_in":3600,"scope":"x","token_type":"Bearer"}"#))
            #expect(await exchange(code, pkce) == .failure(.malformedResponse("refresh_token")))
        }

        @Test(arguments: [
            #"{"expires_in":3600,"token_type":"Bearer"}"#,
            #"{"access_token":"","expires_in":3600,"token_type":"Bearer"}"#,
            #"{"access_token":"a","expires_in":3600,"token_type":"MAC"}"#,
            #"{"access_token":"a","expires_in":3600}"#,
            #"{"access_token":"a","token_type":"Bearer"}"#,
            #"{"access_token":"a","expires_in":0,"token_type":"Bearer"}"#,
            #"{"access_token":"a","expires_in":-5,"token_type":"Bearer"}"#,
            #"{"access_token":"a","expires_in":"3600","token_type":"Bearer"}"#,
            "<html>oops</html>", "", "[]",
        ])
        func malformedSuccessBodiesAreRejected(body: String) async {
            fake.script(.raw(status: 200, body: body))
            #expect(await refresh("rt") == .failure(.malformedResponse("token")))
        }

        @Test func bearerTokenTypeIsCaseInsensitive() async throws {
            fake.script(
                .raw(status: 200, body: #"{"access_token":"a","expires_in":100,"token_type":"bearer","scope":"s"}"#))
            #expect(try await refresh("rt").get().accessToken == "a")
        }

        @Test func shortLivedTokenExpiresImmediately() async throws {
            fake.configure { $0.expiresIn = 30 }
            let grant = try await refresh(fake.seedRefreshToken()).get()
            #expect(grant.expiresAt == TestClock.start)
        }

        @Test func nonJSONErrorBodyGivesNilCode() async {
            fake.script(.raw(status: 503, body: "<html>Service Unavailable</html>"))
            #expect(await refresh("rt") == .failure(.tokenEndpoint(status: 503, code: nil)))
        }

        @Test func errorDescriptionNeverReachesTheError() async {
            fake.script(.oauthError(code: "invalid_grant", description: "CANARY-secret-detail"))
            let result = await refresh("rt")
            #expect(result == .failure(.tokenEndpoint(status: 400, code: "invalid_grant")))
            #expect(!String(describing: result).contains("CANARY"))
        }

        @Test func errorCodeIsSanitizedAndBounded() async {
            fake.script(.oauthError(code: "Inv<script>alid GRANT_" + String(repeating: "x", count: 100)))
            guard case .failure(.tokenEndpoint(_, let code?)) = await refresh("rt") else {
                Issue.record("expected tokenEndpoint failure")
                return
            }
            #expect(code.count <= 40)
            #expect(code.allSatisfy { ("a"..."z").contains($0) || $0 == "_" })
        }

        @Test func redirectIsATransportErrorWithoutTheLocation() async {
            fake.script(.redirect(location: "https://evil.example/steal?code=SECRET"))
            let result = await refresh("rt")
            #expect(result == .failure(.transport("redirected302")))
            #expect(!String(describing: result).contains("evil"))
            #expect(fake.seen.allSatisfy { $0.host != "evil.example" })
        }

        @Test func oversizedBodyIsATransportError() async {
            fake.script(.raw(status: 200, body: String(repeating: "x", count: 70_000)))
            guard case .failure(.transport) = await refresh("rt") else {
                Issue.record("expected transport failure")
                return
            }
        }

        @Test func networkFailureIsATransportError() async {
            fake.script(.network(.notConnectedToInternet))
            guard case .failure(.transport(let detail)) = await refresh("rt") else {
                Issue.record("expected transport failure")
                return
            }
            #expect(detail.contains("offline"))
        }

        @Test func revokeMarksTheTokenRevoked() async {
            let token = fake.seedRefreshToken()
            await endpoints.revoke(token)
            #expect(fake.isRevoked(token))
            let request = fake.revokeRequests.first
            #expect(request?.method == "POST")
            #expect(request?.form["token"] == token)
            #expect(request?.host == "oauth2.googleapis.com")
        }

        @Test func revokeSwallowsFailures() async {
            await endpoints.revoke("unknown-token")
            let offline = OAuthEndpoints(
                transport: AuthTransport(allowedHosts: []), client: fake.client, clock: harness.clock.reader)
            await offline.revoke("anything")
            #expect(fake.revokeRequests.count == 1)
        }

        @Test func userinfoSendsBearerAndParsesIdentity() async throws {
            let pkce = PKCE()
            let grant = try await exchange(try authorizedCode(pkce), pkce).get()
            let identity = try await endpoints.userinfo(accessToken: grant.accessToken)
            #expect(identity.subject == "112233445566778899001")
            #expect(identity.email == "ada@example.com")
            #expect(identity.name == "Ada Lovelace")
            #expect(identity.chatUser?.rawValue == "users/112233445566778899001")
            let request = fake.userinfoRequests.first
            #expect(request?.headers["authorization"] == "Bearer \(grant.accessToken)")
            #expect(request?.host == "openidconnect.googleapis.com")
        }

        @Test func userinfoRejectsUnknownToken() async {
            do {
                _ = try await endpoints.userinfo(accessToken: "bogus")
                Issue.record("expected failure")
            } catch {
                #expect(error == .tokenEndpoint(status: 401, code: nil))
            }
        }

        @Test func userinfoMissingEmailIsMalformed() async throws {
            fake.scriptUserinfo(.raw(status: 200, body: #"{"sub":"123"}"#))
            do {
                _ = try await endpoints.userinfo(accessToken: "x")
                Issue.record("expected failure")
            } catch {
                #expect(error == .malformedResponse("userinfo"))
            }
        }
    }
}
