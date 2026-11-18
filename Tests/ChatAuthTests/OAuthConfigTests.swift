import ChatNet
import Foundation
import Testing

@testable import ChatAuth

struct OAuthClientConfigTests {
    static let clientID = "1234-abc.apps.googleusercontent.com"

    static func json(
        client: String? = clientID, secret: String? = "sample",
        auth: String? = "https://accounts.google.com/o/oauth2/auth",
        token: String? = "https://oauth2.googleapis.com/token", key: String = "installed"
    ) -> Data {
        var fields: [String: Any] = ["project_id": "proj-1", "redirect_uris": ["http://localhost"]]
        if let client { fields["client_id"] = client }
        if let secret { fields["client_secret"] = secret }
        if let auth { fields["auth_uri"] = auth }
        if let token { fields["token_uri"] = token }
        return try! JSONSerialization.data(withJSONObject: [key: fields])
    }

    static func failure(_ data: Data) -> AuthError? {
        do {
            _ = try OAuthClientConfig(json: data)
            return nil
        } catch { return error }
    }

    @Test func importsInstalledClient() throws {
        let config = try OAuthClientConfig(json: Self.json())
        #expect(config.clientID == Self.clientID)
        #expect(config.clientSecret == "sample")
        #expect(config.projectID == "proj-1")
    }

    @Test func endpointsAreOptionalInTheFileAndAlwaysTheConstants() throws {
        let config = try OAuthClientConfig(json: Self.json(auth: nil, token: nil))
        #expect(config.clientID == Self.clientID)
        #expect(OAuthClientConfig.tokenEndpoint.host() == "oauth2.googleapis.com")
        #expect(OAuthClientConfig.authorizationEndpoint.host() == "accounts.google.com")
    }

    @Test func rejectsWebClient() {
        #expect(Self.failure(Self.json(key: "web")) == .invalidClientConfig("webClient"))
    }

    @Test func rejectsFileWithNeitherKey() {
        #expect(Self.failure(Self.json(key: "other")) == .invalidClientConfig("notDesktopClient"))
        #expect(Self.failure(Data("{}".utf8)) == .invalidClientConfig("notDesktopClient"))
    }

    @Test(
        arguments: [
            nil, "", "plain-id", "1234.apps.googleusercontent.com.evil", "bad id.apps.googleusercontent.com",
            "1234_x.apps.googleusercontent.com", "\u{0661}\u{0662}.apps.googleusercontent.com",
            "é.apps.googleusercontent.com", String(repeating: "a", count: 260) + ".apps.googleusercontent.com",
        ] as [String?])
    func rejectsBadClientID(id: String?) {
        #expect(Self.failure(Self.json(client: id)) == .invalidClientConfig("clientID"))
    }

    @Test(arguments: [nil, "", String(repeating: "s", count: 256)] as [String?])
    func rejectsBadClientSecret(secret: String?) {
        #expect(Self.failure(Self.json(secret: secret)) == .invalidClientConfig("clientSecret"))
    }

    @Test(arguments: [
        "https://evil.example/o/oauth2/auth", "https://accounts.google.com.evil.example/auth",
        "https://evil.example/?h=accounts.google.com", "not a url", "",
    ])
    func rejectsForeignAuthURI(uri: String) {
        #expect(Self.failure(Self.json(auth: uri)) == .invalidClientConfig("authURI"))
    }

    @Test(arguments: [
        "https://evil.example/token", "https://oauth2.googleapis.com.evil.example/token",
        "https://evil.example/?h=oauth2.googleapis.com", "not a url", "",
    ])
    func rejectsForeignTokenURI(uri: String) {
        #expect(Self.failure(Self.json(token: uri)) == .invalidClientConfig("tokenURI"))
    }

    @Test(arguments: ["hello", "", "[]", "{\"installed\": ", "\"installed\"", "null"])
    func rejectsNonJSON(text: String) {
        #expect(Self.failure(Data(text.utf8)) == .invalidClientConfig("notJSON"))
    }

    @Test func rejectsInstalledWithWrongFieldTypes() {
        let data = Data(#"{"installed":{"client_id":12,"client_secret":"x"}}"#.utf8)
        #expect(Self.failure(data) == .invalidClientConfig("notJSON"))
    }

    @Test func enforcesSixtyFourKilobyteLimit() throws {
        let base = Self.json()
        let over = base + Data(repeating: 0x20, count: 64 * 1024 + 1 - base.count)
        #expect(over.count > 64 * 1024)
        #expect(Self.failure(over) == .invalidClientConfig("notJSON"))
        let under = base + Data(repeating: 0x20, count: 64 * 1024 - 10 - base.count)
        #expect(Self.failure(under) == nil)
    }

    @Test func errorsNeverCarryTheSecret() {
        let canary = UUID().uuidString
        let error = Self.failure(Self.json(client: "bad", secret: canary))
        #expect(!String(describing: error).contains(canary))
    }
}

struct PKCETests {
    @Test func challengeMatchesRFC7636AppendixB() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierHasRFCLengthAndUnreservedCharset() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for _ in 0..<200 {
            let pkce = PKCE()
            #expect((43...128).contains(pkce.verifier.count))
            #expect(pkce.verifier.allSatisfy { allowed.contains($0) })
            #expect(pkce.challenge.count == 43)
            #expect(!pkce.challenge.contains("="))
            #expect(pkce.challenge != pkce.verifier)
            #expect(pkce.challenge == FakeGoogleOAuth.challenge(for: pkce.verifier))
        }
    }

    @Test func statesAndVerifiersAreUnique() {
        let flows = (0..<2000).map { _ in PKCE() }
        #expect(Set(flows.map(\.state)).count == flows.count)
        #expect(Set(flows.map(\.verifier)).count == flows.count)
        #expect(flows.allSatisfy { $0.state != $0.verifier && $0.state.count >= 32 })
    }

    @Test func matchesOnlyTheExactState() {
        let pkce = PKCE()
        #expect(pkce.matches(state: pkce.state))
        var flipped = Array(pkce.state)
        flipped[flipped.count - 1] = flipped.last == "A" ? "B" : "A"
        #expect(!pkce.matches(state: String(flipped)))
        #expect(!pkce.matches(state: PKCE().state))
    }

    @Test func matchesRejectsDifferentLengths() {
        let pkce = PKCE(verifier: "v", state: "abcdef")
        #expect(!pkce.matches(state: ""))
        #expect(!pkce.matches(state: "abcde"))
        #expect(!pkce.matches(state: "abcdefg"))
        #expect(!pkce.matches(state: "abcdef "))
        #expect(!pkce.matches(state: "abcdéf"))
        #expect(PKCE(verifier: "v", state: "").matches(state: ""))
    }
}

struct OAuthScopesTests {
    static let all = OAuthScopes.required.joined(separator: " ")

    @Test func requiredScopesIncludeIdentityAndChat() {
        #expect(OAuthScopes.required.contains("openid"))
        #expect(OAuthScopes.required.contains("email"))
        #expect(OAuthScopes.required.contains("https://www.googleapis.com/auth/chat.messages.create"))
        #expect(Set(OAuthScopes.required).count == OAuthScopes.required.count)
    }

    @Test func nothingMissingWhenAllGranted() {
        #expect(OAuthScopes.missing(from: Self.all).isEmpty)
    }

    @Test func everythingMissingFromEmpty() {
        #expect(OAuthScopes.missing(from: "") == OAuthScopes.required)
    }

    @Test func reportsExactlyTheMissingOnes() {
        let dropped = ["openid", "https://www.googleapis.com/auth/chat.messages.reactions"]
        let granted = OAuthScopes.required.filter { !dropped.contains($0) }.joined(separator: " ")
        #expect(OAuthScopes.missing(from: granted) == dropped)
    }

    @Test func emailURLAliasCountsAsEmail() {
        let granted = OAuthScopes.required.map {
            $0 == "email" ? "https://www.googleapis.com/auth/userinfo.email" : $0
        }.joined(separator: " ")
        #expect(OAuthScopes.missing(from: granted).isEmpty)
    }

    @Test func extraScopesAreIgnored() {
        let granted = Self.all + " https://www.googleapis.com/auth/drive profile"
        #expect(OAuthScopes.missing(from: granted).isEmpty)
    }

    @Test func toleratesRepeatedSpaces() {
        let granted = OAuthScopes.required.joined(separator: "  ") + " "
        #expect(OAuthScopes.missing(from: granted).isEmpty)
    }

    @Test func similarLookingScopesDoNotCount() {
        let granted = Self.all.replacingOccurrences(of: "chat.messages.create", with: "chat.messages.created")
        #expect(OAuthScopes.missing(from: granted) == ["https://www.googleapis.com/auth/chat.messages.create"])
    }
}

struct AuthorizationURLTests {
    static let redirect = URL(string: "http://127.0.0.1:54321/oauth2/callback")!
    let endpoints = OAuthEndpoints(
        transport: AuthTransport(allowedHosts: []),
        client: OAuthClientConfig(clientID: "1234-abc.apps.googleusercontent.com", clientSecret: "s"))

    func items(_ url: URL) -> [String: String] {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        return percentDecodedForm(query)
    }

    @Test func carriesEveryRequiredParameterOnce() throws {
        let pkce = PKCE()
        let url = endpoints.authorizationURL(pkce: pkce, redirectURI: Self.redirect, loginHint: nil)
        #expect(url.scheme == "https")
        #expect(url.host() == "accounts.google.com")
        #expect(url.path == "/o/oauth2/v2/auth")
        let names = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map(\.name)
        #expect(Set(names).count == names.count)

        let query = items(url)
        #expect(query["client_id"] == "1234-abc.apps.googleusercontent.com")
        #expect(query["redirect_uri"] == Self.redirect.absoluteString)
        #expect(query["response_type"] == "code")
        #expect(query["scope"] == (OAuthScopes.required + OAuthScopes.optional).joined(separator: " "))
        #expect(query["state"] == pkce.state)
        #expect(query["code_challenge"] == pkce.challenge)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["access_type"] == "offline")
        #expect(query["prompt"] == "select_account consent")
        #expect(query["login_hint"] == nil)
    }

    @Test func neverIncludesTheVerifierOrSecret() {
        let pkce = PKCE()
        let url = endpoints.authorizationURL(pkce: pkce, redirectURI: Self.redirect, loginHint: nil)
        #expect(!url.absoluteString.contains(pkce.verifier))
        #expect(!url.absoluteString.contains("client_secret"))
    }

    @Test func includesLoginHintWhenGiven() {
        let url = endpoints.authorizationURL(pkce: PKCE(), redirectURI: Self.redirect, loginHint: "ada@example.com")
        #expect(items(url)["login_hint"] == "ada@example.com")
    }

    @Test func plusInLoginHintSurvivesFormDecoding() {
        let url = endpoints.authorizationURL(
            pkce: PKCE(), redirectURI: Self.redirect, loginHint: "ada+chat@example.com")
        #expect(items(url)["login_hint"] == "ada+chat@example.com")
    }

    @Test func ampersandAndEqualsInLoginHintDoNotInjectParameters() {
        let url = endpoints.authorizationURL(
            pkce: PKCE(), redirectURI: Self.redirect, loginHint: "a@b.c&redirect_uri=http://evil.example/")
        #expect(items(url)["redirect_uri"] == Self.redirect.absoluteString)
        #expect(items(url)["login_hint"] == "a@b.c&redirect_uri=http://evil.example/")
    }
}
