import ChatModel
import Foundation
import Testing

@testable import ChatStore

private let day: Int64 = 24 * 3600

private func space(_ id: String = "A", historyOn: Bool?) -> Space {
    var space = makeSpace(id)
    space.historyOn = historyOn
    return space
}

private func withMedia(_ message: Message, _ id: String) -> Message {
    var copy = message
    copy.attachments = [
        Attachment(contentName: "f.png", contentType: "image/png", source: .uploaded(MediaResourceName("media/\(id)")!))
    ]
    return copy
}

@Suite struct HistoryRetentionStoreTests {
    @Test(arguments: Backend.allCases)
    func historyOffMessagesGoOnceADayOld(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let now = f.clock.now.seconds
        let old = withMedia(makeMessage(id: "old", at: now - day - 10), "old")
        let fresh = makeMessage(id: "fresh", at: now - 100)
        try f.commit(.mergeSpace(space(historyOn: false)), .upsertMessages([old, fresh]))

        #expect(try f.store.message(old.name) == nil)
        #expect(try f.store.message(fresh.name) != nil)
        #expect(try f.store.expiredCleanup() == ExpiredCleanup(messages: [old.name], media: ["media/old"]))
        #expect(try f.store.retentionRecords()[spaceName("A")]?.due == stamp(now - 100 + day))

        f.clock.set(stamp(now + day))
        try f.commit(.expireHistoryOff(nil))
        #expect(try f.store.message(fresh.name) == nil)
        #expect(try f.store.messages(in: spaceName("A"), before: nil, limit: 10).isEmpty)
        #expect(try f.store.retentionRecords().isEmpty)
    }

    @Test(arguments: Backend.allCases)
    func historyOnAndUnknownSpacesKeepTheirMessages(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let now = f.clock.now.seconds
        try f.commit(
            .mergeSpace(space("A", historyOn: true)), .mergeSpace(space("B", historyOn: nil)),
            .upsertMessages([makeMessage("A", "a", at: now - 5 * day), makeMessage("B", "b", at: now - 5 * day)]),
            .expireHistoryOff(nil))
        #expect(try f.store.message(messageName("A", "a")) != nil)
        #expect(try f.store.message(messageName("B", "b")) != nil)
        #expect(try f.store.retentionRecords().isEmpty)
        #expect(try f.store.expiredCleanup() == nil)
    }

    @Test(arguments: Backend.allCases)
    func listedTogglesKeepMessagesSentWithHistoryOn(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let t0 = f.clock.now.seconds
        try f.commit(.mergeSpace(space(historyOn: true)), .upsertMessages([makeMessage(id: "before", at: t0 - 3600)]))
        try f.commit(.mergeSpace(space(historyOn: false)), .upsertMessages([makeMessage(id: "off", at: t0 + 10)]))
        f.clock.set(stamp(t0 + 3600))
        try f.commit(.mergeSpace(space(historyOn: true)), .upsertMessages([makeMessage(id: "after", at: t0 + 7200)]))

        f.clock.set(stamp(t0 + 3 * day))
        try f.commit(.expireHistoryOff(nil))
        #expect(try f.store.message(messageName("A", "before")) != nil)
        #expect(try f.store.message(messageName("A", "off")) == nil)
        #expect(try f.store.message(messageName("A", "after")) != nil)
        let windows = try f.store.retentionRecords()[spaceName("A")]?.windows
        #expect(windows == [HistoryOffWindow(from: stamp(t0 - 300), until: stamp(t0 + 3600))])
    }

    @Test(arguments: Backend.allCases)
    func messagesSentWhileOffExpireAfterHistoryIsBackOn(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let t0 = f.clock.now.seconds
        try f.commit(.mergeSpace(space(historyOn: false)), .upsertMessages([makeMessage(id: "off", at: t0 - 600)]))
        try f.commit(.mergeSpace(space(historyOn: true)))
        #expect(try f.store.message(messageName("A", "off")) != nil)
        f.clock.set(stamp(t0 + day))
        try f.commit(.expireHistoryOff(nil))
        #expect(try f.store.message(messageName("A", "off")) == nil)
    }

    @Test(arguments: Backend.allCases)
    func eventTogglesUseTheirOwnTimes(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let t0 = f.clock.now.seconds
        try f.commit(.mergeSpace(space(historyOn: true)))
        try f.commit(
            .observeHistory(spaceName("A"), historyOn: false, at: stamp(t0 - 7200)),
            .observeHistory(spaceName("A"), historyOn: true, at: stamp(t0 - 3600)),
            .mergeSpace(space(historyOn: true)),
            .upsertMessages([
                makeMessage(id: "early", at: t0 - 7201), makeMessage(id: "off", at: t0 - 7000),
                makeMessage(id: "late", at: t0 - 3599),
            ]))
        #expect(try f.store.space(spaceName("A"))?.space.historyOn == true)
        f.clock.set(stamp(t0 + day))
        try f.commit(.expireHistoryOff(nil))
        #expect(try f.store.message(messageName("A", "early")) != nil)
        #expect(try f.store.message(messageName("A", "off")) == nil)
        #expect(try f.store.message(messageName("A", "late")) != nil)

        // Replaying the same events (the poll overlap) changes nothing.
        let before = try f.store.retentionRecords()
        try f.commit(.observeHistory(spaceName("A"), historyOn: true, at: stamp(t0 - 3600)))
        #expect(try f.store.retentionRecords() == before)
    }

    @Test(arguments: Backend.allCases)
    func eventTimeMovesAListedSwitchEarlier(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let t0 = f.clock.now.seconds
        try f.commit(.mergeSpace(space(historyOn: true)))
        try f.commit(.mergeSpace(space(historyOn: false)), .upsertMessages([makeMessage(id: "m", at: t0 - 1800)]))
        try f.commit(.observeHistory(spaceName("A"), historyOn: false, at: stamp(t0 - 3600)))
        f.clock.set(stamp(t0 + day))
        try f.commit(.expireHistoryOff(nil))
        #expect(try f.store.message(messageName("A", "m")) == nil)
    }

    @Test(arguments: Backend.allCases)
    func unspecifiedHistoryStateKeepsTheStoredOne(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.mergeSpace(space(historyOn: false)))
        try f.commit(.mergeSpace(space(historyOn: nil)))
        #expect(try f.store.space(spaceName("A"))?.space.historyOn == false)
    }

    @Test(arguments: Backend.allCases)
    func expiryTakesCommittedSendsAndPendingNotifications(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let now = f.clock.now.seconds
        let old = makeMessage(id: "old", at: now - day - 5)
        let committed = OutboxItem(
            space: spaceName("A"), payload: OutboxPayload(text: "sent", thread: nil), state: .committed(old.name),
            created: stamp(now - day - 5))
        let queued = OutboxItem(
            space: spaceName("A"), payload: OutboxPayload(text: "unsent", thread: nil), created: stamp(now - day - 5))
        try f.commit(.mergeSpace(space(historyOn: true)), .putOutbox(committed), .putOutbox(queued))
        try f.commit(
            .mergeSpace(space(historyOn: false)), .addNotifyCandidates(spaceName("A"), [old.name]),
            .observeHistory(spaceName("A"), historyOn: false, at: stamp(now - 2 * day)), .upsertMessages([old]))
        #expect(try f.store.message(old.name) == nil)
        #expect(try f.store.outbox().map(\.id) == [queued.id])
        #expect(try f.store.notifyRecords().isEmpty)
    }

    @Test(arguments: Backend.allCases)
    func pruningQueuesCleanupForRowsDueBeforeIt(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let now = f.clock.now.seconds
        let message = withMedia(makeMessage(id: "m", at: now - 10), "m")
        try f.commit(.mergeSpace(space(historyOn: false)), .upsertMessages([message]))
        #expect(try f.store.expiredCleanup() == nil)
        f.clock.set(stamp(now + day))
        try f.commit(.pruneMessages(spaceName("A"), keep: 0))
        #expect(try f.store.expiredCleanup()?.media == ["media/m"])

        try f.commit(.clearExpiredCleanup(ExpiredCleanup(messages: [message.name], media: ["media/m"])))
        #expect(try f.store.expiredCleanup() == nil)
    }

    @Test(arguments: Backend.allCases)
    func deletingASpaceDropsItsRetention(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let now = f.clock.now.seconds
        try f.commit(.mergeSpace(space(historyOn: false)), .upsertMessages([makeMessage(id: "m", at: now - 10)]))
        #expect(try f.store.retentionRecords()[spaceName("A")] != nil)
        try f.commit(.deleteSpace(spaceName("A")))
        #expect(try f.store.retentionRecords().isEmpty)
    }
}

@Suite struct HistoryRetentionModelTests {
    @Test func aSpaceFirstSeenOffHasBeenOffForever() {
        let record = HistoryRetention().effective(historyOn: false)
        #expect(record.isExpired(stamp(0), now: stamp(day + 1)))
        #expect(!record.isExpired(stamp(2), now: stamp(day + 1)))
        #expect(!HistoryRetention().effective(historyOn: true).isExpired(stamp(0), now: stamp(10 * day)))
    }

    @Test func oldClosedWindowsAreForgottenAndTheCountIsCapped() {
        var record = HistoryRetention()
        for hour in 0..<40 {
            record.observe(historyOn: false, previous: true, at: stamp(Int64(hour) * 3600), margin: .zero)
            record.observe(historyOn: true, previous: false, at: stamp(Int64(hour) * 3600 + 60), margin: .zero)
        }
        #expect(record.windows.count == 16)
        #expect(record.isExpired(stamp(30), now: stamp(2 * day)))
        record.forgetExpired(now: stamp(10 * day))
        #expect(record.windows.isEmpty)
    }
}
