import ChatModel
import ChatNet
import Foundation
import Testing

@testable import FakeChatServer

struct FailureRuleTests {
    let h = Harness()

    func details(_ call: Call) -> [String: Any]? {
        ((call.json["error"] as? [String: Any])?["details"] as? [[String: Any]])?.first
    }

    @Test func httpFailureUsesTheGoogleEnvelope() async throws {
        h.server.fail(
            FailureRule(
                route: .listSpaces,
                response: .http(
                    status: 403, googleStatus: "PERMISSION_DENIED", reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT")))
        let call = try await h.get("spaces", as: h.alice)
        #expect(call.status == 403)
        #expect(call.errorStatus == "PERMISSION_DENIED")
        let error = try #require(call.json["error"] as? [String: Any])
        #expect(error["code"] as? Int == 403)
        let detail = try #require(details(call))
        #expect(detail["@type"] as? String == "type.googleapis.com/google.rpc.ErrorInfo")
        #expect(detail["reason"] as? String == "ACCESS_TOKEN_SCOPE_INSUFFICIENT")
        #expect(detail["domain"] as? String == "googleapis.com")
        #expect(call.headers["retry-after"] == nil)
    }

    @Test func httpFailureWithoutReasonHasNoDetails() async throws {
        h.server.fail(.unavailable())
        let call = try await h.get("spaces", as: h.alice)
        #expect(call.status == 503)
        #expect(call.errorStatus == "UNAVAILABLE")
        #expect(details(call) == nil)
    }

    @Test func rateLimitCarriesRetryAfter() async throws {
        h.server.fail(.rateLimited(route: .listMessages, retryAfter: 7))
        let call = try await h.listMessages()
        #expect(call.status == 429)
        #expect(call.errorStatus == "RESOURCE_EXHAUSTED")
        #expect(call.headers["retry-after"] == "7")
    }

    @Test func malformedJSONIs200WithATruncatedBody() async throws {
        h.seed(2)
        h.server.fail(.malformedJSON(route: .listMessages))
        let call = try await h.listMessages()
        #expect(call.status == 200)
        #expect(!call.body.isEmpty)
        #expect((try? JSONSerialization.jsonObject(with: call.body)) == nil)
        #expect(try await h.listMessages().items("messages").count == 2)
    }

    @Test func networkErrorSurfacesAsATransportErrorAndCommitsNothing() async throws {
        h.server.fail(.networkError(.timedOut, route: .createMessage))
        await #expect(throws: TransportError.timedOut) { try await h.create("hello") }
        #expect(h.server.messages(in: h.space).isEmpty)
        #expect(h.server.requests.last?.status == nil)

        h.server.fail(.networkError(.notConnectedToInternet))
        await #expect(throws: TransportError.offline) { try await h.get("spaces", as: h.alice) }
    }

    @Test func commitThenNetworkErrorReallyCommits() async throws {
        h.server.fail(.lostResponse(.networkConnectionLost))
        await #expect(throws: TransportError.connectionLost) {
            try await h.create("hello", query: ["requestId": "r1"])
        }
        let committed = h.server.messages(in: h.space)
        #expect(committed.map(\.text) == ["hello"])

        let retry = try await h.create("hello", query: ["requestId": "r1"])
        #expect(retry.status == 200)
        #expect(retry.json["name"] as? String == committed[0].name.rawValue)
        #expect(h.server.messages(in: h.space).count == 1)
    }

    @Test func timesLimitsHowOftenARuleFires() async throws {
        h.server.fail(
            FailureRule(route: .listSpaces, times: 2, response: .http(status: 503, googleStatus: "UNAVAILABLE")))
        var statuses: [Int] = []
        for _ in 0..<4 { statuses.append(try await h.get("spaces", as: h.alice).status) }
        #expect(statuses == [503, 503, 200, 200])
    }

    @Test func defaultTimesIsOneAndNilIsForever() async throws {
        h.server.fail(.unavailable(route: .listSpaces))
        #expect(try await h.get("spaces", as: h.alice).status == 503)
        #expect(try await h.get("spaces", as: h.alice).status == 200)

        h.server.fail(.unavailable(route: .listSpaces, times: nil))
        for _ in 0..<5 { #expect(try await h.get("spaces", as: h.alice).status == 503) }
        h.server.clearFailures()
        #expect(try await h.get("spaces", as: h.alice).status == 200)
    }

    @Test func onlyWithPageTokenFailsPageTwoButNotPageOne() async throws {
        h.seed(5)
        h.server.fail(.unavailable(route: .listMessages, onlyWithPageToken: true))
        let first = try await h.listMessages(["pageSize": "2"])
        #expect(first.status == 200)
        let token = try #require(first.nextPageToken)
        #expect(try await h.listMessages(["pageSize": "2", "pageToken": token]).status == 503)
        #expect(try await h.listMessages(["pageSize": "2", "pageToken": token]).status == 200)
    }

    @Test func rulesCanTargetOneAccountAndOneSpace() async throws {
        let other = h.server.addSpace(.space, members: [h.alice, h.bob])
        h.server.fail(.permissionDenied(route: .listMessages, reason: "R", account: h.alice, space: other, times: nil))

        #expect(try await h.get("\(other.rawValue)/messages", as: h.alice).status == 403)
        #expect(try await h.get("\(other.rawValue)/messages", as: h.bob).status == 200)
        #expect(try await h.listMessages().status == 200)
        #expect(try await h.get("\(other.rawValue)", as: h.alice).status == 200)
    }

    @Test func ruleAppliesToARenewedToken() async throws {
        h.server.fail(.rateLimited(account: h.alice, times: nil))
        let renewed = h.server.revokeToken(h.alice)
        #expect(try await h.get("spaces", as: renewed).status == 429)
        #expect(try await h.get("spaces", as: h.bob).status == 200)
    }

    @Test func firstMatchingRuleInInsertionOrderFires() async throws {
        h.server.fail(.rateLimited(route: .listSpaces))
        h.server.fail(.unavailable(route: .listSpaces))
        h.server.fail(.permissionDenied(route: .getSpace))
        #expect(try await h.get("spaces", as: h.alice).status == 429)
        #expect(try await h.get("spaces", as: h.alice).status == 503)
        #expect(try await h.get(h.space.rawValue, as: h.alice).status == 403)
    }

    @Test func anyRouteMatchesUnknownRoutesToo() async throws {
        h.server.fail(.unavailable())
        #expect(try await h.get("somethingElse", as: h.alice).status == 503)
    }

    @Test(arguments: [
        (FailureRule.Route.listSpaces, "spaces"), (.getSpace, "SPACE"), (.listMessages, "SPACE/messages"),
        (.listSpaceEvents, "SPACE/spaceEvents"), (.listMembers, "SPACE/members"),
        (.getSpaceReadState, "users/me/SPACE/spaceReadState"),
        (.getNotificationSetting, "users/me/SPACE/spaceNotificationSetting"), (.listCustomEmojis, "customEmojis"),
    ])
    func everyReadRouteCanBeFailed(route: FailureRule.Route, path: String) async throws {
        h.server.fail(.unavailable(route: route))
        let resolved = path.replacingOccurrences(of: "SPACE", with: h.space.rawValue)
        let query = route == .listSpaceEvents ? ["filter": h.eventsFilter()] : [:]
        #expect(try await h.get(resolved, query, as: h.alice).status == 503)
        #expect(try await h.get(resolved, query, as: h.alice).status == 200)
    }

    @Test func messageAndThreadAndWriteRoutesCanBeFailed() async throws {
        let message = h.seed(1)[0]
        let thread = try #require(message.thread)
        h.server.fail(.unavailable(route: .getMessage))
        h.server.fail(.unavailable(route: .getThreadReadState))
        h.server.fail(.unavailable(route: .updateSpaceReadState))
        h.server.fail(.unavailable(route: .createMessage))
        #expect(try await h.get(message.name.rawValue, as: h.alice).status == 503)
        let threadPath = "users/me/\(h.space.rawValue)/threads/\(thread.id(at: 1))/threadReadState"
        #expect(try await h.get(threadPath, as: h.alice).status == 503)
        let patch = try await h.call(
            .patch, "users/me/\(h.space.rawValue)/spaceReadState", query: ["updateMask": "lastReadTime"],
            body: ["lastReadTime": "2026-01-01T00:00:00Z"], as: h.alice)
        #expect(patch.status == 503)
        #expect(try await h.create("x").status == 503)
        #expect(h.server.messages(in: h.space).count == 1)
    }

    @Test func failedRequestsAreRecordedWithTheirStatus() async throws {
        h.server.fail(.unavailable(route: .listSpaces))
        h.server.fail(.networkError(.timedOut, route: .listSpaces))
        _ = try await h.get("spaces", as: h.alice)
        _ = try? await h.get("spaces", as: h.alice)
        _ = try await h.get("spaces", as: h.alice)
        #expect(h.server.requests.map(\.status) == [503, nil, 200])
    }
}
