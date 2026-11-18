import ChatModel
import Foundation
import Testing

@testable import FakeChatServer

struct SpaceEventTests {
    let h = Harness()
    let t0 = ts("2026-03-01T00:00:00Z")

    func eventTypes(_ call: Call) -> [String] {
        call.items("spaceEvents").compactMap { $0["eventType"] as? String }
    }

    @Test func everyMutationRecordsItsEvent() async throws {
        let message = h.server.post("a", in: h.space, from: .account(h.alice))
        h.server.edit(message.name, text: "b")
        h.server.react(message.name, emoji: .unicode("👍"), by: .account(h.bob))
        h.server.delete(message.name)
        h.server.addMember(h.carol, to: h.space)
        h.server.removeMember(h.carol, from: h.space)

        let all = [
            created, updated, deleted, reactionCreated, "google.workspace.chat.membership.v1.created",
            "google.workspace.chat.membership.v1.deleted",
        ]
        let call = try await h.listEvents(h.eventsFilter(types: all))
        #expect(
            eventTypes(call) == [
                created, updated, reactionCreated, deleted, "google.workspace.chat.membership.v1.created",
                "google.workspace.chat.membership.v1.deleted",
            ])
        let events = call.items("spaceEvents")
        for event in events {
            #expect((event["name"] as? String)?.hasPrefix("\(h.space.rawValue)/spaceEvents/") == true)
            #expect(event["eventTime"] is String)
        }
        let reaction = (events[2]["reactionCreatedEventData"] as? [String: Any])?["reaction"] as? [String: Any]
        #expect((reaction?["name"] as? String)?.contains("/reactions/") == true)
        #expect((reaction?["user"] as? [String: Any])?["name"] as? String == h.bob.user.name.rawValue)
        let membership = (events[4]["membershipCreatedEventData"] as? [String: Any])?["membership"] as? [String: Any]
        #expect(membership?["state"] as? String == "JOINED")
    }

    @Test func eventsCarryTheMessageStateAtThatTime() async throws {
        let message = h.server.post("first", in: h.space, from: .account(h.alice))
        h.server.edit(message.name, text: "second")
        h.server.delete(message.name)

        let call = try await h.listEvents(h.eventsFilter(types: [created, updated, deleted]))
        func payload(_ index: Int, _ key: String) -> [String: Any]? {
            (call.items("spaceEvents")[index][key] as? [String: Any])?["message"] as? [String: Any]
        }
        #expect(payload(0, "messageCreatedEventData")?["text"] as? String == "first")
        #expect(payload(1, "messageUpdatedEventData")?["text"] as? String == "second")
        #expect(payload(1, "messageUpdatedEventData")?["lastUpdateTime"] != nil)
        let tombstone = payload(2, "messageDeletedEventData")
        #expect(tombstone?["text"] == nil)
        #expect(tombstone?["deleteTime"] != nil)
    }

    @Test func typeFilterIsAnOrList() async throws {
        let message = h.server.post("a", in: h.space, from: .account(h.alice))
        h.server.edit(message.name, text: "b")
        h.server.react(message.name, emoji: .unicode("👍"), by: .account(h.bob))

        #expect(eventTypes(try await h.listEvents(h.eventsFilter(types: [updated]))) == [updated])
        #expect(
            eventTypes(try await h.listEvents(h.eventsFilter(types: [updated, reactionCreated])))
                == [updated, reactionCreated])
        #expect(try await h.listEvents(h.eventsFilter(types: [deleted])).items("spaceEvents").isEmpty)
    }

    @Test func windowExcludesStartAndIncludesEnd() async throws {
        let times = (0..<4).map { t0.adding(.seconds($0 * 10)) }
        for (index, time) in times.enumerated() {
            h.server.post("m\(index)", in: h.space, from: .account(h.alice), at: time)
        }
        let call = try await h.listEvents(h.eventsFilter(start: times[1].rfc3339, end: times[3].rfc3339))
        let texts = call.items("spaceEvents").compactMap {
            (($0["messageCreatedEventData"] as? [String: Any])?["message"] as? [String: Any])?["text"] as? String
        }
        #expect(texts == ["m2", "m3"])
    }

    @Test func withoutStartTimeTheWindowIsTheLast28Days() async throws {
        h.server.post("old", in: h.space, from: .account(h.alice), at: ts("2025-11-01T00:00:00Z"))
        let recent = h.server.post("recent", in: h.space, from: .account(h.alice))
        let call = try await h.listEvents()
        #expect(call.items("spaceEvents").count == 1)
        let message =
            (call.items("spaceEvents")[0]["messageCreatedEventData"] as? [String: Any])?["message"] as? [String: Any]
        #expect(message?["name"] as? String == recent.name.rawValue)
    }

    @Test func startTimeOlderThan28DaysIs400() async throws {
        let edge = h.server.now.adding(.seconds(-28 * 24 * 3600))
        #expect(try await h.listEvents(h.eventsFilter(start: edge.rfc3339)).status == 200)
        let tooOld = try await h.listEvents(h.eventsFilter(start: edge.adding(.seconds(-1)).rfc3339))
        #expect(tooOld.status == 400)
        #expect(tooOld.errorStatus == "INVALID_ARGUMENT")
    }

    @Test func eventsAreOldestFirstEvenWhenSeededOutOfOrder() async throws {
        h.server.post("late", in: h.space, from: .account(h.alice), at: t0.adding(.seconds(20)))
        h.server.post("early", in: h.space, from: .account(h.alice), at: t0)
        let call = try await h.listEvents()
        let times = call.items("spaceEvents").compactMap { $0["eventTime"] as? String }
        #expect(times == [t0.rfc3339, t0.adding(.seconds(20)).rfc3339])
    }

    @Test func eventsPaginate() async throws {
        for index in 0..<5 { h.server.post("m\(index)", in: h.space, from: .account(h.alice)) }
        var seen = 0
        var token: String?
        repeat {
            let page = try await h.listEvents(nil, ["pageSize": "2", "pageToken": token].compactMapValues { $0 })
            #expect(page.status == 200)
            seen += page.items("spaceEvents").count
            token = page.nextPageToken
        } while token != nil
        #expect(seen == 5)
    }

    @Test func tokenFromADifferentFilterIs400() async throws {
        for index in 0..<3 { h.server.post("m\(index)", in: h.space, from: .account(h.alice)) }
        let token = try #require(try await h.listEvents(nil, ["pageSize": "1"]).nextPageToken)
        let call = try await h.listEvents(h.eventsFilter(types: [updated]), ["pageSize": "1", "pageToken": token])
        #expect(call.status == 400)
    }

    @Test func sameInstantCreatesAreServedAsOneBatch() async throws {
        let first = h.server.post("a", in: h.space, from: .account(h.alice), at: t0)
        let second = h.server.post("b", in: h.space, from: .account(h.bob), at: t0)
        h.server.post("c", in: h.space, from: .account(h.alice), at: t0.adding(.seconds(1)))

        let call = try await h.listEvents()
        let events = call.items("spaceEvents")
        #expect(events.count == 2)

        let batch = events[0]
        #expect(batch["eventType"] as? String == "google.workspace.chat.message.v1.batchCreated")
        #expect(batch["messageCreatedEventData"] == nil)
        let entries = try #require(
            (batch["messageBatchCreatedEventData"] as? [String: Any])?["messages"] as? [[String: Any]])
        let names = entries.compactMap { ($0["message"] as? [String: Any])?["name"] as? String }
        #expect(names == [first.name.rawValue, second.name.rawValue])
        #expect(events[1]["messageCreatedEventData"] != nil)
    }

    @Test func otherEventKindsBatchUnderTheirOwnPayloadNames() async throws {
        let message = h.server.post("a", in: h.space, from: .account(h.alice), at: t0)
        h.server.react(message.name, emoji: .unicode("👍"), by: .account(h.alice), at: t0.adding(.seconds(1)))
        h.server.react(message.name, emoji: .unicode("🎉"), by: .account(h.bob), at: t0.adding(.seconds(1)))
        h.server.edit(message.name, text: "b", at: t0.adding(.seconds(2)))
        h.server.edit(message.name, text: "c", at: t0.adding(.seconds(2)))
        h.server.addMember(h.carol, to: h.space)

        let types = [created, updated, reactionCreated]
        let events = try await h.listEvents(h.eventsFilter(types: types)).items("spaceEvents")
        #expect(events.count == 3)

        let reactions = (events[1]["reactionBatchCreatedEventData"] as? [String: Any])?["reactions"] as? [[String: Any]]
        #expect(events[1]["eventType"] as? String == "google.workspace.chat.reaction.v1.batchCreated")
        #expect(reactions?.count == 2)
        #expect((reactions?[0]["reaction"] as? [String: Any])?["emoji"] != nil)

        let updates = (events[2]["messageBatchUpdatedEventData"] as? [String: Any])?["messages"] as? [[String: Any]]
        #expect(events[2]["eventType"] as? String == "google.workspace.chat.message.v1.batchUpdated")
        #expect(updates?.compactMap { ($0["message"] as? [String: Any])?["text"] as? String } == ["b", "c"])
    }

    @Test func membershipBatchUsesMembershipsKey() async throws {
        let added = "google.workspace.chat.membership.v1.created"
        let dave = User(name: UserName("users/4242")!, displayName: "Dave")
        h.server.addMember(h.carol, to: h.space)
        let separate = try await h.listEvents(h.eventsFilter(types: [added])).items("spaceEvents")
        #expect(separate.count == 1)
        #expect(separate[0]["membershipCreatedEventData"] != nil)

        let at = ts("2026-02-01T00:00:00Z")
        h.server.removeMember(h.carol, from: h.space)
        h.server.addMember(h.carol, to: h.space, at: at)
        h.server.addMember(dave, to: h.space, at: at)
        let batched = try await h.listEvents(h.eventsFilter(start: "2026-01-31T00:00:00Z", types: [added])).items(
            "spaceEvents")
        let data = batched.first?["membershipBatchCreatedEventData"] as? [String: Any]
        #expect(batched.count == 1)
        #expect((data?["memberships"] as? [[String: Any]])?.count == 2)
        #expect(((data?["memberships"] as? [[String: Any]])?[0]["membership"] as? [String: Any])?["member"] != nil)
    }

    @Test func batchesAreKeptTogetherAcrossPages() async throws {
        h.server.post("a", in: h.space, from: .account(h.alice), at: t0)
        h.server.post("b", in: h.space, from: .account(h.alice), at: t0)
        h.server.post("c", in: h.space, from: .account(h.alice), at: t0.adding(.seconds(1)))
        let call = try await h.listEvents(nil, ["pageSize": "1"])
        let batch = call.items("spaceEvents")[0]["messageBatchCreatedEventData"] as? [String: Any]
        #expect((batch?["messages"] as? [Any])?.count == 2)
        #expect(call.nextPageToken != nil)
    }

    @Test func missingEventTypesIs400() async throws {
        let space = h.space.rawValue
        let noFilter = try await h.get("\(space)/spaceEvents", as: h.alice)
        #expect(noFilter.status == 400)
        let onlyTimes = try await h.get(
            "\(space)/spaceEvents", ["filter": "startTime=\"\(t0.rfc3339)\""], as: h.alice)
        #expect(onlyTimes.status == 400)
        #expect(onlyTimes.errorStatus == "INVALID_ARGUMENT")
    }

    @Test func windowOver28DaysIs400() async throws {
        let end28 = t0.adding(.seconds(28 * 24 * 3600))
        #expect(try await h.listEvents(h.eventsFilter(start: t0.rfc3339, end: end28.rfc3339)).status == 200)
        let over = try await h.listEvents(h.eventsFilter(start: t0.rfc3339, end: end28.adding(.seconds(1)).rfc3339))
        #expect(over.status == 400)
        #expect(over.errorStatus == "INVALID_ARGUMENT")
    }

    @Test(arguments: [
        "garbage", "startTime=\"yesterday\" AND (eventTypes:\"google.workspace.chat.message.v1.created\")",
        "(eventTypes:\"nope\")", "startTime=\"2026-03-01T00:00:00Z\" AND text=\"x\"",
        "start_time=\"2026-03-01T00:00:00Z\" AND (event_types:\"google.workspace.chat.message.v1.created\")",
    ])
    func unparseableFilterIs400(filter: String) async throws {
        #expect(try await h.listEvents(filter).status == 400)
    }
}
