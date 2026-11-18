import ChatModel
import ChatNet
import Foundation
import Testing

@testable import FakeChatServer

struct AccessTests {
    let h = Harness()

    @Test func missingTokenIs401() async throws {
        let call = try await h.get("spaces", as: nil)
        #expect(call.status == 401)
        #expect(call.errorStatus == "UNAUTHENTICATED")
    }

    @Test func unknownTokenIs401() async throws {
        let call = try await h.get("spaces", as: nil, token: "not-a-token")
        #expect(call.status == 401)
        #expect(call.errorStatus == "UNAUTHENTICATED")
    }

    @Test func revokedTokenIs401AndTheNewTokenWorks() async throws {
        let renewed = h.server.revokeToken(h.alice)
        #expect(renewed.user == h.alice.user)
        #expect(renewed.token != h.alice.token)

        #expect(try await h.get("spaces", as: h.alice).status == 401)
        #expect(try await h.get("spaces", as: renewed).status == 200)
        let accounts = h.server.requests.map { $0.account?.token }
        #expect(accounts == [nil, renewed.token])
    }

    @Test func serversAreIsolatedByToken() async throws {
        let other = FakeChatServer()
        let stranger = other.addAccount(displayName: "Stranger")
        #expect(try await h.get("spaces", as: stranger).status == 200)
        #expect(h.server.requests.isEmpty)
        #expect(other.requests.count == 1)
    }

    @Test func errorEnvelopeShape() async throws {
        let call = try await h.get("spaces/nonexistent", as: h.alice)
        let error = try #require(call.json["error"] as? [String: Any])
        #expect(error["code"] as? Int == 404)
        #expect(error["status"] as? String == "NOT_FOUND")
        #expect(error["message"] is String)
        #expect(error["details"] == nil)
    }

    @Test func nonMemberGets403OnEverySpaceResource() async throws {
        let message = h.seed(1)[0]
        let space = h.space.rawValue
        let paths = [
            space, "\(space)/messages", message.name.rawValue, "\(space)/members",
            "users/me/\(space)/spaceReadState", "users/me/\(space)/spaceNotificationSetting",
        ]
        for path in paths {
            let call = try await h.get(path, as: h.carol)
            #expect(call.status == 403, "\(path)")
            #expect(call.errorStatus == "PERMISSION_DENIED", "\(path)")
        }
        #expect(try await h.listEvents(as: h.carol).status == 403)
        #expect(try await h.create("hi", as: h.carol).status == 403)
    }

    @Test func missingResourcesAre404() async throws {
        let space = h.space.rawValue
        let paths = [
            "spaces/Missing", "spaces/Missing/messages", "\(space)/messages/Nope.Nope", "spaces/Missing/members",
            "users/me/spaces/Missing/spaceReadState", "users/me/\(space)/threads/Nope/threadReadState",
        ]
        for path in paths {
            let call = try await h.get(path, as: h.alice)
            #expect(call.status == 404, "\(path)")
            #expect(call.errorStatus == "NOT_FOUND", "\(path)")
        }
    }

    @Test func unknownRouteIs404() async throws {
        #expect(try await h.get("somethingElse", as: h.alice).status == 404)
        #expect(try await h.call(.delete, h.space.rawValue, as: h.alice).status == 404)
        #expect(try await h.get("\(h.space.rawValue)/nothing", as: h.alice).errorStatus == "NOT_FOUND")
    }

    @Test func spacesListShowsOnlyJoinedSpaces() async throws {
        let dm = h.server.addSpace(.directMessage, members: [h.alice, h.carol])
        #expect(try await h.get("spaces", as: h.alice).names("spaces") == [h.space.rawValue, dm.rawValue])
        #expect(try await h.get("spaces", as: h.bob).names("spaces") == [h.space.rawValue])
        #expect(try await h.get("spaces", as: h.carol).names("spaces") == [dm.rawValue])
    }

    @Test func membershipChangesTakeEffect() async throws {
        h.server.addMember(h.carol, to: h.space)
        #expect(try await h.get(h.space.rawValue, as: h.carol).status == 200)
        h.server.removeMember(h.carol, from: h.space)
        #expect(try await h.get(h.space.rawValue, as: h.carol).status == 403)
        let members = try await h.get("\(h.space.rawValue)/members", as: h.alice)
        #expect(members.items("memberships").count == 2)
    }

    @Test func wireShapeOfSpaceAndMembers() async throws {
        let bot = User(name: UserName("users/9001")!, type: .bot, displayName: "Helper")
        let dm = h.server.addSpace(.directMessage, members: [h.alice], bots: [bot])
        let space = try await h.get(dm.rawValue, as: h.alice).json
        #expect(space["spaceType"] as? String == "DIRECT_MESSAGE")
        #expect(space["singleUserBotDm"] as? Bool == true)
        #expect(space["displayName"] == nil)
        #expect(space["spaceThreadingState"] as? String == "THREADED_MESSAGES")
        #expect((space["lastActiveTime"] as? String) != nil)

        let members = try await h.get("\(dm.rawValue)/members", as: h.alice).items("memberships")
        let botMember = try #require(members.first { ($0["member"] as? [String: Any])?["type"] as? String == "BOT" })
        #expect(botMember["state"] as? String == "JOINED")
        #expect(botMember["role"] as? String == "ROLE_MEMBER")
        #expect((botMember["name"] as? String)?.hasPrefix("\(dm.rawValue)/members/") == true)
    }

    @Test func requestsAreRecorded() async throws {
        h.seed(1)
        try await h.listMessages(["pageSize": "1"])
        try await h.get("spaces/Missing", as: h.alice)
        let recorded = h.server.requests
        #expect(recorded.map(\.status) == [200, 404])
        #expect(recorded[0].method == "GET")
        #expect(recorded[0].path == "/v1/\(h.space.rawValue)/messages")
        #expect(recorded[0].value(for: "pageSize") == "1")
        #expect(recorded[0].account == h.alice)
    }
}
