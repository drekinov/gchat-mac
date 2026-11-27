import ChatModel
import Foundation
import Testing

@testable import FakeChatServer

/// Like Google Chat: a message posted while history is off is gone a day later, from every read, without an event.
struct HistoryOffTests {
    let h = Harness()
    let spaceUpdated = "google.workspace.chat.space.v1.updated"

    func search(_ text: String) async throws -> [String] {
        let call = try await h.call(.post, "spaces/-/messages:search", body: ["filter": text], as: h.alice)
        return call.items("results").compactMap { ($0["message"] as? [String: Any])?["text"] as? String }
    }

    @Test func messagesPostedWhileHistoryIsOffVanishAfterADay() async throws {
        let kept = h.server.post("kept note", in: h.space, from: .account(h.bob))
        h.server.setHistory(on: false, in: h.space)
        let gone = h.server.post("gone note", in: h.space, from: .account(h.bob))
        h.server.setHistory(on: true, in: h.space)
        #expect(Set(try await search("note")) == ["kept note", "gone note"])

        h.server.advance(.seconds(24 * 3600))
        #expect(try await h.listMessages().items("messages").compactMap { $0["text"] as? String } == ["kept note"])
        #expect(try await h.get(gone.name.rawValue, as: h.alice).status == 404)
        #expect(try await h.get(kept.name.rawValue, as: h.alice).status == 200)
        #expect(try await search("note") == ["kept note"])
        let events = try await h.listEvents(h.eventsFilter(types: [created]))
        #expect(events.items("spaceEvents").count == 1)
    }

    @Test func togglingHistoryRecordsSpaceUpdatedEvents() async throws {
        h.server.setHistory(on: false, in: h.space)
        h.server.setHistory(on: false, in: h.space)
        h.server.setHistory(on: true, in: h.space)
        let call = try await h.listEvents(h.eventsFilter(types: [spaceUpdated]))
        let states = call.items("spaceEvents").compactMap {
            (($0["spaceUpdatedEventData"] as? [String: Any])?["space"] as? [String: Any])?["spaceHistoryState"]
                as? String
        }
        #expect(states == ["HISTORY_OFF", "HISTORY_ON"], "one event per change")
    }
}
