import ChatModel
import ChatNet
import Foundation
import Testing

@testable import GoogleChat

@Suite struct ErrorHandlingTests {
    static let canary = "CANARY-7f3a"

    func unauthorized() -> Result<HTTPResponse, TransportError> {
        .success(HTTPResponse(status: 401, body: Data(#"{"error":{"code":401,"status":"UNAUTHENTICATED"}}"#.utf8)))
    }

    func ok(_ json: String = "{}") -> Result<HTTPResponse, TransportError> {
        .success(HTTPResponse(status: 200, body: Data(json.utf8)))
    }

    // MARK: 401 handling

    @Test func unauthorizedInvalidatesTokenAndRetriesOnce() async throws {
        let transport = StubTransport([unauthorized(), ok(#"{"spaces":[]}"#)])
        let tokens = StubTokens()
        let page = try await makeClient(transport, tokens: tokens).listSpaces(pageSize: 10, pageToken: nil)
        #expect(page.items.isEmpty)
        #expect(tokens.invalidated == ["token-1"])
        #expect(transport.requests.map { $0.headers["Authorization"] } == ["Bearer token-1", "Bearer token-2"])
        #expect(transport.requests[0].url == transport.requests[1].url)
    }

    @Test func secondUnauthorizedSurfaces() async {
        let transport = StubTransport([unauthorized(), unauthorized(), ok()])
        let tokens = StubTokens()
        let error = await thrownError {
            try await makeClient(transport, tokens: tokens).listSpaces(pageSize: 1, pageToken: nil)
        }
        #expect(error == .unauthorized)
        #expect(transport.requests.count == 2)
        #expect(tokens.invalidated == ["token-1"])
    }

    @Test func retriedWriteKeepsBodyAndRequestID() async throws {
        let transport = StubTransport([
            unauthorized(), .success(HTTPResponse(status: 200, body: fixture("message_full"))),
        ])
        let id = UUID()
        _ = try await makeClient(transport).createMessage(NewMessage(space: testSpace, text: "x", requestID: id))
        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].body == transport.requests[1].body)
        #expect(transport.requests[0].url == transport.requests[1].url)
    }

    @Test func noCredentialsSendsNothing() async {
        let transport = StubTransport()
        let error = await thrownError {
            try await makeClient(transport, tokens: StubTokens(failing: true)).listSpaces(pageSize: 1, pageToken: nil)
        }
        #expect(error == .noCredentials)
        #expect(transport.requests.isEmpty)
    }

    @Test func transportErrorsAreWrapped() async {
        let transport = StubTransport([.failure(.offline)])
        let error = await thrownError { try await makeClient(transport).listSpaces(pageSize: 1, pageToken: nil) }
        #expect(error == .transport(.offline))
    }

    // MARK: classification

    @Test func permissionDeniedCarriesErrorInfoReason() async {
        let (client, _) = clientServing("error_403_service_disabled", status: 403)
        let error = await thrownError { try await client.getSpace(testSpace) }
        #expect(
            error
                == .permissionDenied(
                    GoogleErrorInfo(httpStatus: 403, status: "PERMISSION_DENIED", reason: "SERVICE_DISABLED")))
    }

    @Test func rateLimitedHonoursRetryAfter() async {
        let transport = StubTransport(status: 429, headers: ["Retry-After": "7"], body: fixture("error_429_rate"))
        let error = await thrownError { try await makeClient(transport).getSpace(testSpace) }
        #expect(error == .rateLimited(retryAfter: .seconds(7)))
    }

    @Test func rateLimitedWithoutHeader() async {
        let (client, _) = clientServing("error_429_rate", status: 429)
        let error = await thrownError { try await client.getSpace(testSpace) }
        #expect(error == .rateLimited(retryAfter: nil))
    }

    @Test func forbiddenResourceExhaustedIsRateLimited() async {
        let (client, _) = clientServing("error_403_resource_exhausted", status: 403)
        let error = await thrownError { try await client.getSpace(testSpace) }
        #expect(error == .rateLimited(retryAfter: nil))
    }

    @Test func failedPreconditionIsDistinctFromInvalidArgument() async {
        let (client, _) = clientServing("error_400_failed_precondition", status: 400)
        let error = await thrownError { try await client.getSpace(testSpace) }
        #expect(error == .failedPrecondition(GoogleErrorInfo(httpStatus: 400, status: "FAILED_PRECONDITION")))

        let (other, _) = clientServing("error_400_invalid_argument", status: 400)
        let invalid = await thrownError { try await other.getSpace(testSpace) }
        #expect(invalid == .invalidArgument(GoogleErrorInfo(httpStatus: 400, status: "INVALID_ARGUMENT")))
    }

    @Test func serverErrorIsRetryableAndWriteOutcomeUnknown() async throws {
        let (client, _) = clientServing("error_503", status: 503)
        let error = try #require(await thrownError { try await client.getSpace(testSpace) })
        #expect(error == .server(GoogleErrorInfo(httpStatus: 503, status: "UNAVAILABLE")))
        #expect(error.isRetryable)
        #expect(error.writeOutcomeUnknown)
    }

    @Test(arguments: [(404, "error_404"), (409, "error_409")])
    func notFoundAndConflict(status: Int, name: String) async throws {
        let (client, _) = clientServing(name, status: status)
        let error = try #require(await thrownError { try await client.getSpace(testSpace) })
        switch (status, error) {
        case (404, .notFound), (409, .conflict): break
        default: Issue.record("unexpected \(error)")
        }
    }

    @Test func nonJSONErrorBodyStillClassifies() async {
        let transport = StubTransport(status: 502, body: Data("<html>\(Self.canary)</html>".utf8))
        let error = await thrownError { try await makeClient(transport).getSpace(testSpace) }
        #expect(error == .server(GoogleErrorInfo(httpStatus: 502)))
    }

    // MARK: no content leaks

    @Test(
        arguments: [
            (403, "error_403_service_disabled"), (429, "error_429_rate"), (403, "error_403_resource_exhausted"),
            (400, "error_400_failed_precondition"), (400, "error_400_invalid_argument"), (404, "error_404"),
            (409, "error_409"), (503, "error_503"),
        ])
    func errorMessageNeverAppearsInThrownError(status: Int, name: String) async throws {
        let (client, _) = clientServing(name, status: status)
        let error = try #require(await thrownError { try await client.getSpace(testSpace) })
        for text in [String(describing: error), String(reflecting: error), "\(error)"] {
            #expect(!text.contains(Self.canary), "\(text)")
        }
    }

    @Test func decodingErrorsCarryOnlyThePath() async throws {
        let body = Data(#"{"name":"spaces/\#(Self.canary)/x y","spaceType":"SPACE"}"#.utf8)
        let transport = StubTransport(status: 200, body: body)
        let error = try #require(await thrownError { try await makeClient(transport).getSpace(testSpace) })
        #expect(error == .decoding(path: "name"))
        #expect(!String(describing: error).contains(Self.canary))
    }

    @Test func malformedJSONIsADecodingError() async throws {
        let transport = StubTransport(status: 200, body: Data("{\"spaces\": [\(Self.canary)".utf8))
        let error = try #require(
            await thrownError { try await makeClient(transport).listSpaces(pageSize: 1, pageToken: nil) })
        guard case .decoding = error else {
            Issue.record("expected decoding, got \(error)")
            return
        }
        #expect(!String(describing: error).contains(Self.canary))
    }

    @Test func errorInfoClampsHostileStatusAndReason() {
        let body = Data(
            #"{"error":{"status":"CANARY secret text\nwith spaces","details":[{"@type":"x/google.rpc.ErrorInfo","reason":"user@example.com"}]}}"#
                .utf8)
        let info = GoogleErrorInfo(httpStatus: 403, body: body)
        #expect(info.status == "CANARY")
        #expect(info.reason == "")
    }

    @Test func singleResourceDecodingFailureNamesTheField() async {
        let transport = StubTransport(status: 200, body: Data(#"{"name":"spaces/AAAA","spaceType":"HOLOGRAM"}"#.utf8))
        let error = await thrownError { try await makeClient(transport).getSpace(testSpace) }
        #expect(error == .decoding(path: "spaceType"))
    }
}
