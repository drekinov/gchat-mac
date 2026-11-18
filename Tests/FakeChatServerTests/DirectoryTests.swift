import ChatModel
import ChatNet
import Foundation
import Testing

@testable import FakeChatServer

private let peopleHost = "people.googleapis.com"

extension Harness {
    func setUp(
        _ body: [String: Any]?, as account: FakeAccount? = nil, token: String? = nil
    ) async throws -> Call {
        var headers = ["Content-Type": "application/json"]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await raw(
            .post, path: "/v1/spaces:setup", headers: headers, body: data, as: token == nil ? (account ?? alice) : nil)
    }

    func directMessage(with member: String, type: String? = "HUMAN", as account: FakeAccount? = nil) async throws
        -> Call
    {
        var user: [String: Any] = ["name": member]
        if let type { user["type"] = type }
        return try await setUp(
            ["space": ["spaceType": "DIRECT_MESSAGE"], "memberships": [["member": user]]], as: account)
    }

    func search(
        _ query: String, mask: String? = "names,emailAddresses", pageSize: Int? = nil, pageToken: String? = nil,
        sources: String? = "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE", as account: FakeAccount? = nil
    ) async throws -> Call {
        var parameters = ["query": query]
        if let mask { parameters["readMask"] = mask }
        if let sources { parameters["sources"] = sources }
        if let pageSize { parameters["pageSize"] = String(pageSize) }
        if let pageToken { parameters["pageToken"] = pageToken }
        return try await raw(
            .get, host: peopleHost, path: "/v1/people:searchDirectoryPeople", query: parameters, as: account ?? alice)
    }

    func memberIDs(of space: String, as account: FakeAccount? = nil) async throws -> [String] {
        let call = try await get("\(space)/members", as: account ?? alice)
        return call.items("memberships").compactMap { ($0["member"] as? [String: Any])?["name"] as? String }.sorted()
    }
}

@Suite struct SetUpSpaceTests {
    let h = Harness()
    var bobName: String { h.bob.user.name.rawValue }

    @Test func createsADirectMessageWithBothMembers() async throws {
        let call = try await h.directMessage(with: bobName)
        #expect(call.status == 200)
        let name = try #require(call.json["name"] as? String)
        #expect(call.json["spaceType"] as? String == "DIRECT_MESSAGE")
        #expect(call.json["spaceThreadingState"] as? String == "UNTHREADED_MESSAGES")
        #expect(call.json["displayName"] == nil)

        let expected = [h.alice.user.name.rawValue, bobName].sorted()
        #expect(try await h.memberIDs(of: name, as: h.alice) == expected)
        #expect(try await h.memberIDs(of: name, as: h.bob) == expected)
        #expect(try await h.get(name, as: h.carol).status == 403)
        #expect(try await h.get("spaces", as: h.bob).names("spaces").contains(name))
        #expect(h.server.space(try #require(SpaceName(name)))?.type == .directMessage)
    }

    @Test func recordsAMembershipCreatedEventPerMember() async throws {
        let name = try #require(try await h.directMessage(with: bobName).json["name"] as? String)
        let events = try await h.get(
            "\(name)/spaceEvents", ["filter": h.eventsFilter(types: ["google.workspace.chat.membership.v1.created"])],
            as: h.alice)
        #expect(events.status == 200)
        let created = events.items("spaceEvents").compactMap {
            (($0["membershipCreatedEventData"] as? [String: Any])?["membership"] as? [String: Any])
        }
        let members = created.compactMap { ($0["member"] as? [String: Any])?["name"] as? String }
        #expect(members.sorted() == [h.alice.user.name.rawValue, bobName].sorted())
        #expect(created.allSatisfy { $0["state"] as? String == "JOINED" })
    }

    @Test func returnsTheExistingDirectMessage() async throws {
        let first = try #require(try await h.directMessage(with: bobName).json["name"] as? String)
        let again = try await h.directMessage(with: bobName)
        #expect(again.status == 200)
        #expect(again.json["name"] as? String == first)
        let reverse = try await h.directMessage(with: h.alice.user.name.rawValue, as: h.bob)
        #expect(reverse.json["name"] as? String == first)
        let byEmail = try await h.directMessage(with: "users/bob@fake.example")
        #expect(byEmail.json["name"] as? String == first)

        let alicesSpaces = try await h.get("spaces", as: h.alice)
        #expect(alicesSpaces.items("spaces").filter { $0["spaceType"] as? String == "DIRECT_MESSAGE" }.count == 1)
        let events = try await h.get(
            "\(first)/spaceEvents", ["filter": h.eventsFilter(types: ["google.workspace.chat.membership.v1.created"])],
            as: h.alice)
        #expect(events.items("spaceEvents").count == 2)
    }

    @Test func differentUsersGetDifferentDirectMessages() async throws {
        let withBob = try #require(try await h.directMessage(with: bobName).json["name"] as? String)
        let withCarol = try #require(
            try await h.directMessage(with: h.carol.user.name.rawValue).json["name"] as? String)
        #expect(withBob != withCarol)
        let bobAndCarol = try #require(
            try await h.directMessage(with: h.carol.user.name.rawValue, as: h.bob).json["name"] as? String)
        #expect(Set([withBob, withCarol, bobAndCarol]).count == 3)
    }

    @Test func aGroupSpaceWithTheSamePairIsNotReused() async throws {
        let group = h.server.addSpace(.groupChat, members: [h.alice, h.carol])
        let dm = try #require(try await h.directMessage(with: h.carol.user.name.rawValue).json["name"] as? String)
        #expect(dm != group.rawValue)
    }

    @Test func resolvesEmailsCaseInsensitively() async throws {
        let dana = h.server.addAccount(displayName: "Dana K", email: "Dana.K@corp.example")
        #expect(h.server.email(of: dana.user) == "Dana.K@corp.example")
        #expect(h.server.email(of: h.bob.user) == "bob@fake.example")
        let call = try await h.directMessage(with: "users/dana.k@CORP.example")
        #expect(call.status == 200)
        #expect(try await h.memberIDs(of: try #require(call.json["name"] as? String)).contains(dana.user.name.rawValue))
    }

    @Test func seededUsersAndDirectoryPeopleCanBeMessaged() async throws {
        let zed = User(name: UserName(unchecked: "users/777"), displayName: "Zed Zane")
        h.server.addSpace(.space, members: [h.carol], users: [zed])
        h.server.setEmail("zed@corp.example", for: zed)
        let eve = User(name: UserName(unchecked: "users/42"), displayName: "Eve Adams")
        h.server.addDirectoryPerson(eve, email: "eve@corp.example")

        let withZed = try await h.directMessage(with: "users/zed@corp.example")
        #expect(withZed.status == 200)
        #expect(try await h.memberIDs(of: try #require(withZed.json["name"] as? String)).contains("users/777"))
        let withEve = try await h.directMessage(with: "users/42")
        #expect(withEve.status == 200)
        #expect(try await h.memberIDs(of: try #require(withEve.json["name"] as? String)).contains("users/42"))
    }

    @Test func bothSidesCanPostIntoTheNewDirectMessage() async throws {
        let name = try #require(try await h.directMessage(with: bobName).json["name"] as? String)
        #expect(try await h.call(.post, "\(name)/messages", body: ["text": "hi bob"], as: h.alice).status == 200)
        #expect(try await h.call(.post, "\(name)/messages", body: ["text": "hi alice"], as: h.bob).status == 200)
        #expect(try await h.get("\(name)/messages", as: h.bob).items("messages").count == 2)
        #expect(try await h.call(.post, "\(name)/messages", body: ["text": "x"], as: h.carol).status == 403)
    }

    @Test func unknownUsersAre404() async throws {
        for member in ["users/9999999", "users/nobody@fake.example", "users/not-a-user"] {
            let call = try await h.directMessage(with: member)
            #expect(call.status == 404)
            #expect(call.errorStatus == "NOT_FOUND")
        }
    }

    @Test func invalidRequestsAre400() async throws {
        let member: [String: Any] = ["member": ["name": bobName, "type": "HUMAN"]]
        let dm: [String: Any] = ["spaceType": "DIRECT_MESSAGE"]
        let carolMember: [String: Any] = ["member": ["name": h.carol.user.name.rawValue, "type": "HUMAN"]]
        let bodies: [[String: Any]?] = [
            ["space": ["spaceType": "SPACE"], "memberships": [member]],
            ["space": ["spaceType": "GROUP_CHAT"], "memberships": [member]],
            ["memberships": [member]],
            ["space": dm],
            ["space": dm, "memberships": []],
            ["space": dm, "memberships": [member, carolMember]],
            ["space": dm, "memberships": [["member": ["name": bobName, "type": "BOT"]]]],
            ["space": dm, "memberships": [["member": ["type": "HUMAN"]]]],
            ["space": dm, "memberships": [["member": ["name": "spaces/abc", "type": "HUMAN"]]]],
            ["space": dm, "memberships": [["member": ["name": "users/", "type": "HUMAN"]]]],
            ["space": dm, "memberships": [["member": ["name": h.alice.user.name.rawValue, "type": "HUMAN"]]]],
        ]
        for body in bodies {
            let call = try await h.setUp(body)
            #expect(call.status == 400, "\(String(describing: body))")
            #expect(call.errorStatus == "INVALID_ARGUMENT")
        }
        let notJSON = try await h.raw(.post, path: "/v1/spaces:setup", body: Data("nope".utf8), as: h.alice)
        #expect(notJSON.status == 400)
        let noBody = try await h.setUp(nil)
        #expect(noBody.status == 400)
        #expect(h.server.messages(in: h.space).isEmpty)
        #expect(try await h.get("spaces", as: h.alice).names("spaces") == [h.space.rawValue])
    }

    @Test func aBotDirectMessageTargetIsRejected() async throws {
        let bot = User(name: UserName(unchecked: "users/555"), type: .bot, displayName: "Helper")
        h.server.addSpace(.space, members: [h.alice], bots: [bot])
        #expect(try await h.directMessage(with: "users/555").status == 400)
    }

    @Test func requiresAuthentication() async throws {
        #expect(try await h.setUp(["space": ["spaceType": "DIRECT_MESSAGE"]], token: "bogus").status == 401)
        let renewed = h.server.revokeToken(h.alice)
        #expect(try await h.setUp(["space": ["spaceType": "DIRECT_MESSAGE"]], token: h.alice.token).status == 401)
        #expect(try await h.directMessage(with: bobName, as: renewed).status == 200)
    }

    @Test func failureRulesRouteSetUp() async throws {
        h.server.fail(.unavailable(route: .setUpSpace))
        #expect(try await h.directMessage(with: bobName).status == 503)
        #expect(try await h.get("spaces", as: h.alice).names("spaces") == [h.space.rawValue])
        #expect(try await h.directMessage(with: bobName).status == 200)

        h.server.fail(.lostResponse(route: .setUpSpace))
        await #expect(throws: TransportError.self) { try await h.directMessage(with: h.carol.user.name.rawValue) }
        let again = try await h.directMessage(with: h.carol.user.name.rawValue)
        #expect(again.status == 200)
        #expect(
            try await h.get("spaces", as: h.alice).items("spaces").filter {
                $0["spaceType"] as? String == "DIRECT_MESSAGE"
            }
            .count == 2)
    }
}

@Suite struct DirectorySearchTests {
    let h = Harness()

    private func names(_ call: Call) -> [String] {
        call.items("people").compactMap { ($0["names"] as? [[String: Any]])?.first?["displayName"] as? String }
    }

    @Test func matchesDisplayNamePrefixesCaseInsensitively() async throws {
        #expect(names(try await h.search("ali")) == ["Alice"])
        #expect(names(try await h.search("BO")) == ["Bob"])
        #expect(names(try await h.search("ice")).isEmpty)
        #expect(names(try await h.search("Carol")) == ["Carol"])
    }

    @Test func matchesEmailPrefixes() async throws {
        h.server.addDirectoryPerson(
            User(name: UserName(unchecked: "users/42"), displayName: "Xavier"), email: "ops.team@corp.example")
        #expect(names(try await h.search("ops.")) == ["Xavier"])
        #expect(names(try await h.search("OPS.TEAM@")) == ["Xavier"])
        #expect(names(try await h.search("bob@fake")) == ["Bob"])
        #expect(names(try await h.search("corp")).isEmpty)
    }

    @Test func returnsTheDocumentedShape() async throws {
        let call = try await h.search("alice")
        #expect(call.status == 200)
        let person = try #require(call.items("people").first)
        #expect(person["resourceName"] as? String == "people/\(h.alice.user.name.id(at: 0))")
        #expect((person["names"] as? [[String: Any]])?.first?["displayName"] as? String == "Alice")
        #expect((person["emailAddresses"] as? [[String: Any]])?.first?["value"] as? String == "alice@fake.example")
        #expect(call.nextPageToken == nil)
        #expect(call.headers["content-type"]?.hasPrefix("application/json") == true)
    }

    @Test func includesEveryKnownHumanOnce() async throws {
        let extra = User(name: UserName(unchecked: "users/31"), displayName: "Alan Seeded")
        h.server.addSpace(.space, members: [h.alice], users: [extra])
        h.server.addDirectoryPerson(
            User(name: UserName(unchecked: "users/32"), displayName: "Alan Directory"), email: "alan.d@corp.example")
        h.server.addSpace(
            .space, members: [h.alice],
            bots: [User(name: UserName(unchecked: "users/33"), type: .bot, displayName: "Alan Bot")])
        #expect(names(try await h.search("al")) == ["Alan Directory", "Alan Seeded", "Alice"])
        let all = try await h.search("")
        #expect(names(all).count == 5)
        #expect(Set(all.items("people").compactMap { $0["resourceName"] as? String }).count == 5)
    }

    @Test func noMatchesIsAnEmptyObject() async throws {
        let call = try await h.search("zzz")
        #expect(call.status == 200)
        #expect(call.json["people"] == nil)
        #expect(call.nextPageToken == nil)
    }

    @Test func readMaskLimitsTheFields() async throws {
        let namesOnly = try #require(try await h.search("alice", mask: "names").items("people").first)
        #expect(namesOnly["names"] != nil && namesOnly["emailAddresses"] == nil)
        let emailsOnly = try #require(try await h.search("alice", mask: "emailAddresses").items("people").first)
        #expect(emailsOnly["names"] == nil && emailsOnly["emailAddresses"] != nil)
    }

    @Test func pagesWithTokens() async throws {
        for index in 1...5 {
            h.server.addDirectoryPerson(
                User(name: UserName(unchecked: "users/10\(index)"), displayName: "Pat \(index)"),
                email: "pat\(index)@corp.example")
        }
        var seen: [String] = []
        var token: String?
        var pages = 0
        repeat {
            let call = try await h.search("pat", pageSize: 2, pageToken: token)
            #expect(call.status == 200)
            seen += names(call)
            token = call.nextPageToken
            pages += 1
        } while token != nil
        #expect(pages == 3)
        #expect(seen == ["Pat 1", "Pat 2", "Pat 3", "Pat 4", "Pat 5"])

        let first = try await h.search("pat", pageSize: 2)
        let mismatched = try await h.search("pa", pageSize: 2, pageToken: first.nextPageToken)
        #expect(mismatched.status == 400)
    }

    @Test func defaultPageSizeIsTwenty() async throws {
        for index in 1...25 {
            h.server.addDirectoryPerson(
                User(name: UserName(unchecked: "users/2\(index)"), displayName: String(format: "Sam %02d", index)),
                email: "sam\(index)@corp.example")
        }
        let first = try await h.search("sam")
        #expect(names(first).count == 20)
        #expect(first.nextPageToken != nil)
        let second = try await h.search("sam", pageToken: first.nextPageToken)
        #expect(names(second).count == 5)
        #expect(second.nextPageToken == nil)
    }

    @Test func canBeDisabled() async throws {
        #expect(h.server.directoryEnabled)
        h.server.directoryEnabled = false
        let call = try await h.search("alice")
        #expect(call.status == 403)
        #expect(call.errorStatus == "PERMISSION_DENIED")
        h.server.directoryEnabled = true
        #expect(try await h.search("alice").status == 200)
    }

    @Test func requiresAuthentication() async throws {
        let anonymous = try await h.raw(
            .get, host: peopleHost, path: "/v1/people:searchDirectoryPeople",
            query: ["query": "a", "readMask": "names", "sources": "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"], as: nil)
        #expect(anonymous.status == 401)
        let renewed = h.server.revokeToken(h.alice)
        #expect(try await h.search("a", as: h.alice).status == 401)
        #expect(try await h.search("a", as: renewed).status == 200)
    }

    @Test func rejectsMissingParameters() async throws {
        #expect(try await h.search("a", mask: nil).status == 400)
        #expect(try await h.search("a", sources: nil).status == 400)
        #expect(try await h.search("a", sources: "DIRECTORY_SOURCE_TYPE_CONTACT").status == 400)
        #expect(try await h.search("a", pageSize: 0).status == 200)
    }

    @Test func failureRulesRouteSearches() async throws {
        h.server.fail(.rateLimited(route: .searchDirectory, retryAfter: 2))
        let limited = try await h.search("a")
        #expect(limited.status == 429)
        #expect(limited.headers["retry-after"] == "2")
        #expect(try await h.search("a").status == 200)
    }

    @Test func routesAreSeparatedByHost() async throws {
        let wrongHost = try await h.raw(
            .get, host: "chat.googleapis.com", path: "/v1/people:searchDirectoryPeople",
            query: ["query": "a", "readMask": "names", "sources": "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"], as: h.alice)
        #expect(wrongHost.status == 404)
        let chatOnPeople = try await h.raw(.get, host: peopleHost, path: "/v1/spaces", as: h.alice)
        #expect(chatOnPeople.status == 404)
        let recorded = h.server.requests.map(\.path)
        #expect(recorded.contains("/v1/people:searchDirectoryPeople"))
    }
}
