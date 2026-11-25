import ChatModel
import Foundation
import Testing

@testable import ChatStore

@Suite struct StoreConformanceTests {
    @Test(arguments: Backend.allCases)
    func messageRoundTripsEveryField(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let message = richMessage()
        try f.commit(.upsertMessages([message]))
        #expect(try f.store.message(message.name) == message)
        #expect(try f.store.message(messageName("A", "missing")) == nil)
    }

    @Test(arguments: Backend.allCases)
    func olderVersionIsIgnored(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let stored = makeMessage(id: "m", at: 10, text: "new", updated: 30)
        try f.commit(.upsertMessages([stored]))
        try f.commit(.upsertMessages([makeMessage(id: "m", at: 10, text: "old", updated: 20)]))
        try f.commit(.upsertMessages([makeMessage(id: "m", at: 10, text: "never edited")]))
        #expect(try f.store.message(stored.name)?.text == "new")
    }

    @Test(arguments: Backend.allCases)
    func newerVersionReplaces(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.upsertMessages([makeMessage(id: "m", at: 10, text: "v1")]))
        try f.commit(.upsertMessages([makeMessage(id: "m", at: 10, text: "v2", updated: 20)]))
        #expect(try f.store.message(messageName("A", "m"))?.text == "v2")
        try f.commit(.upsertMessages([makeMessage(id: "m", at: 10, text: "v3", updated: 20)]))
        #expect(try f.store.message(messageName("A", "m"))?.text == "v2")
    }

    @Test(arguments: Backend.allCases)
    func replaceRewritesEqualVersionsButKeepsNewerRows(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(
            .upsertMessages([
                makeMessage(id: "m", at: 10, text: "cached"), makeMessage(id: "n", at: 11, text: "edited", updated: 30),
            ]))
        try f.commit(
            .replaceMessages(
                spaceName("A"),
                [
                    makeMessage(id: "m", at: 10, text: "refetched"),
                    makeMessage(id: "n", at: 11, text: "stale", updated: 20),
                ],
                coveredBefore: stamp(100)))
        #expect(try f.store.message(messageName("A", "m"))?.text == "refetched")
        #expect(try f.store.message(messageName("A", "n"))?.text == "edited")
    }

    @Test(arguments: Backend.allCases)
    func nanosecondsDecideVersions(_ backend: Backend) throws {
        let f = try Fixture(backend)
        var first = makeMessage(id: "m", at: 10, text: "a")
        first.lastUpdateTime = stamp(20, 1)
        var second = makeMessage(id: "m", at: 10, text: "b")
        second.lastUpdateTime = stamp(20, 2)
        try f.commit(.upsertMessages([second]))
        try f.commit(.upsertMessages([first]))
        #expect(try f.store.message(first.name)?.text == "b")
    }

    @Test(arguments: Backend.allCases)
    func equalVersionTombstoneWins(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let live = makeMessage(id: "m", at: 10, text: "live", updated: 20)
        let tombstone = makeMessage(id: "m", at: 10, text: "", updated: 5, deleted: 20)
        #expect(live.version == tombstone.version)
        try f.commit(.upsertMessages([live]))
        try f.commit(.upsertMessages([tombstone]))
        #expect(try f.store.message(live.name)?.isDeleted == true)
    }

    @Test(arguments: Backend.allCases)
    func equalVersionNonTombstoneKeepsStoredCopy(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let live = makeMessage(id: "m", at: 10, text: "live", updated: 20)
        let tombstone = makeMessage(id: "m", at: 10, text: "", updated: 5, deleted: 20)
        try f.commit(.upsertMessages([tombstone]))
        try f.commit(.upsertMessages([live]))
        #expect(try f.store.message(live.name)?.isDeleted == true)

        let other = makeMessage(id: "n", at: 10, text: "first", updated: 20)
        try f.commit(.upsertMessages([other]))
        try f.commit(.upsertMessages([makeMessage(id: "n", at: 10, text: "second", updated: 20)]))
        #expect(try f.store.message(other.name)?.text == "first")
    }

    @Test(arguments: Backend.allCases)
    func liveCopyNeverReplacesTombstone(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.upsertMessages([makeMessage(id: "m", at: 10, deleted: 20)]))
        try f.commit(.upsertMessages([makeMessage(id: "m", at: 10, text: "back", updated: 30)]))
        try f.commit(
            .replaceMessages(
                spaceName("A"), [makeMessage(id: "m", at: 10, text: "back", updated: 40)], coveredBefore: stamp(5)))
        #expect(try f.store.message(messageName("A", "m"))?.isDeleted == true)
    }

    @Test(arguments: Backend.allCases)
    func tombstoneKeepsThreadAndSenderAndReplacesAnEqualTombstone(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let reply = makeMessage(id: "r", at: 10, text: "hi", thread: "t")
        try f.commit(.upsertMessages([reply]))
        var local = makeMessage(id: "r", at: 10, deleted: 10)
        local.thread = nil
        try f.commit(.upsertMessages([local]))
        var server = makeMessage(id: "r", at: 10, deleted: 10)
        server.thread = nil
        server.sender = User(name: UserName(unchecked: "users/unknown"))
        server.text = "server"
        try f.commit(.upsertMessages([server]))
        let stored = try #require(try f.store.message(messageName("A", "r")))
        #expect(stored.isDeleted)
        #expect(stored.thread == reply.thread)
        #expect(stored.isThreadReply)
        #expect(stored.sender == reply.sender)
        #expect(stored.text == "server")
    }

    @Test(arguments: Backend.allCases)
    func duplicatesInOneBatchApplyInOrder(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(
            .upsertMessages([
                makeMessage(id: "m", at: 10, text: "a", updated: 11),
                makeMessage(id: "m", at: 10, text: "b", updated: 12),
                makeMessage(id: "m", at: 10, text: "stale", updated: 11),
            ]))
        #expect(try f.store.message(messageName("A", "m"))?.text == "b")
    }

    @Test(arguments: Backend.allCases)
    func checkpointsAreMonotonicAndIndependent(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let a = spaceName("A")
        #expect(try f.store.checkpoint(a, .messages) == nil)
        try f.commit(.setCheckpoint(a, .messages, stamp(100, 5)))
        try f.commit(.setCheckpoint(a, .messages, stamp(100, 4)))
        try f.commit(.setCheckpoint(a, .messages, stamp(99, 999)))
        #expect(try f.store.checkpoint(a, .messages) == stamp(100, 5))
        try f.commit(.setCheckpoint(a, .messages, stamp(100, 5)))
        #expect(try f.store.checkpoint(a, .messages) == stamp(100, 5))
        try f.commit(.setCheckpoint(a, .messages, stamp(100, 6)))
        #expect(try f.store.checkpoint(a, .messages) == stamp(100, 6))
        #expect(try f.store.checkpoint(a, .events) == nil)
        #expect(try f.store.checkpoint(spaceName("B"), .messages) == nil)
    }

    @Test(arguments: Backend.allCases)
    func mergeSpaceKeepsLocalFields(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let a = spaceName("A")
        let setting = SpaceNotificationSetting(level: .forYou, isMuted: true)
        try f.commit(
            .mergeSpace(makeSpace("A", name: "Old")), .setReadState(a, stamp(40, 1)),
            .setNotificationSetting(a, setting),
            .setMembers(
                a, [Membership(name: MembershipName(unchecked: "spaces/A/members/1"), member: ann)], title: "Ann",
                fetched: stamp(60)),
            .setSpaceHidden(a, true))
        try f.commit(.mergeSpace(makeSpace("A", name: "New")))

        let stored = try #require(try f.store.space(a))
        #expect(stored.space.displayName == "New")
        #expect(stored.lastReadTime == stamp(40, 1))
        #expect(stored.notificationSetting == setting)
        #expect(stored.memberTitle == "Ann")
        #expect(stored.memberTitleFetched == stamp(60))
        #expect(stored.isHidden)
        #expect(try f.store.spaces() == [stored])
    }

    @Test(arguments: Backend.allCases)
    func localSettersAreNoOpsForUnknownSpaces(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let ghost = spaceName("ghost")
        try f.commit(.setSpaceHidden(ghost, true), .setNotificationSetting(ghost, nil))
        #expect(try f.store.space(ghost) == nil)
        #expect(try f.store.spaces().isEmpty)
    }

    @Test(arguments: Backend.allCases)
    func newSpaceAdoptsMembersFetchedEarlier(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let a = spaceName("A")
        try f.commit(.setMembers(a, [], title: "Early", fetched: stamp(9)))
        try f.commit(.mergeSpace(makeSpace("A")))
        let stored = try #require(try f.store.space(a))
        #expect(stored.memberTitle == "Early")
        #expect(stored.memberTitleFetched == stamp(9))
    }

    @Test(arguments: Backend.allCases)
    func spacesAreOrderedByName(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.mergeSpace(makeSpace("C")), .mergeSpace(makeSpace("A")), .mergeSpace(makeSpace("B")))
        #expect(try f.store.spaces().map(\.space.name.rawValue) == ["spaces/A", "spaces/B", "spaces/C"])
    }

    @Test(arguments: Backend.allCases)
    func readStateRoundTripAndClear(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let a = spaceName("A")
        let t = threadName("A", "t")
        try f.commit(.mergeSpace(makeSpace("A")), .setReadState(a, stamp(5)), .setThreadReadState(t, stamp(6, 7)))
        #expect(try f.store.space(a)?.lastReadTime == stamp(5))
        #expect(try f.store.threadReadState(t) == stamp(6, 7))
        try f.commit(.setReadState(a, nil), .setThreadReadState(t, nil))
        #expect(try f.store.space(a)?.lastReadTime == nil)
        #expect(try f.store.threadReadState(t) == nil)
    }

    @Test(arguments: Backend.allCases)
    func pruneKeepsNewestByCreateTime(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let messages = (1...10).map { makeMessage(id: "m\($0)", at: Int64($0) * 10) }
        try f.commit(.upsertMessages(messages), .upsertMessages([makeMessage("B", "other", at: 1)]))
        try f.commit(.pruneMessages(spaceName("A"), keep: 3))
        let kept = try f.store.messages(in: spaceName("A"), before: nil, limit: 100)
        #expect(kept.map(\.name.rawValue) == ["spaces/A/messages/m8", "spaces/A/messages/m9", "spaces/A/messages/m10"])
        #expect(try f.store.messages(in: spaceName("B"), before: nil, limit: 100).count == 1)
        try f.commit(.pruneMessages(spaceName("A"), keep: 50))
        #expect(try f.store.messages(in: spaceName("A"), before: nil, limit: 100).count == 3)
        try f.commit(.pruneMessages(spaceName("A"), keep: 0))
        #expect(try f.store.messages(in: spaceName("A"), before: nil, limit: 100).isEmpty)
    }

    @Test(arguments: Backend.allCases)
    func deleteSpaceCascadesButKeepsOutbox(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let a = spaceName("A")
        let b = spaceName("B")
        let item = OutboxItem(space: a, payload: OutboxPayload(text: "pending", thread: nil), created: stamp(1))
        for space in ["A", "B"] {
            let name = spaceName(space)
            try f.commit(
                .mergeSpace(makeSpace(space)), .upsertMessages([makeMessage(space, "m", at: 10, thread: "t")]),
                .setMembers(name, [], title: "T", fetched: stamp(1)),
                .putDraft(Draft(space: name, thread: nil, text: "d", updated: stamp(2))),
                .putDraft(Draft(space: name, thread: threadName(space, "t"), text: "dt", updated: stamp(2))),
                .setReadState(name, stamp(3)), .setThreadReadState(threadName(space, "t"), stamp(3)),
                .setCheckpoint(name, .messages, stamp(4)), .setCheckpoint(name, .events, stamp(4)),
                .markNotified([messageName(space, "m")], at: stamp(5)))
        }
        try f.commit(.putOutbox(item))
        try f.commit(.deleteSpace(a))

        #expect(try f.store.space(a) == nil)
        #expect(try f.store.messages(in: a, before: nil, limit: 10).isEmpty)
        #expect(try f.store.messages(inThread: threadName("A", "t"), limit: 10).isEmpty)
        #expect(try f.store.members(in: a).isEmpty)
        #expect(try f.store.drafts().map(\.space) == [b, b])
        #expect(try f.store.threadReadState(threadName("A", "t")) == nil)
        #expect(try f.store.checkpoint(a, .messages) == nil)
        #expect(try f.store.checkpoint(a, .events) == nil)
        #expect(try !f.store.isNotified(messageName("A", "m")))
        #expect(try f.store.outbox() == [item])

        #expect(try f.store.space(b)?.lastReadTime == stamp(3))
        #expect(try f.store.messages(in: b, before: nil, limit: 10).count == 1)
        #expect(try f.store.threadReadState(threadName("B", "t")) == stamp(3))
        #expect(try f.store.checkpoint(b, .events) == stamp(4))
        #expect(try f.store.isNotified(messageName("B", "m")))
    }

    @Test(arguments: Backend.allCases)
    func draftsRoundTrip(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let a = spaceName("A")
        let composer = Draft(space: a, thread: nil, text: "space draft", updated: stamp(1, 2))
        let reply = Draft(space: a, thread: threadName("A", "t"), text: "reply draft", updated: stamp(3))
        #expect(composer.key != reply.key)
        try f.commit(.putDraft(reply), .putDraft(composer))
        #expect(try f.store.drafts() == [composer, reply].sorted { $0.key < $1.key })
        var edited = composer
        edited.text = "edited"
        try f.commit(.putDraft(edited))
        #expect(try f.store.drafts().contains(edited))
        #expect(try f.store.drafts().count == 2)
        try f.commit(.deleteDraft(key: composer.key))
        #expect(try f.store.drafts() == [reply])
        try f.commit(.deleteDraft(key: "spaces/none"))
    }

    @Test(arguments: Backend.allCases)
    func draftsKeepTheirFilesAndOnlyFillAnEmptySlot(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let a = spaceName("A")
        let file = PendingAttachment(
            bookmark: Data("b".utf8), filename: "f.pdf", contentType: "application/pdf", byteCount: 3)
        let filesOnly = Draft(space: a, thread: nil, text: "", attachments: [file], updated: stamp(1))
        try f.commit(.putDraft(filesOnly))
        #expect(try f.store.drafts() == [filesOnly])

        let recovered = Draft(space: a, thread: nil, text: "recovered", updated: stamp(2))
        try f.commit(.putDraftIfAbsent(recovered))
        #expect(try f.store.drafts() == [filesOnly])

        try f.commit(.putDraft(Draft(space: a, thread: nil, text: "", updated: stamp(3))))
        try f.commit(.putDraftIfAbsent(recovered))
        #expect(try f.store.drafts() == [recovered])
    }

    @Test func aDraftSavedWithoutFilesStillDecodes() throws {
        let legacy = Data(
            #"{"space":"spaces/A","text":"old","updated":"2026-01-01T00:00:00Z"}"#.utf8)
        let draft = try JSONDecoder().decode(Draft.self, from: legacy)
        #expect(draft.text == "old")
        #expect(draft.attachments.isEmpty)
    }

    @Test(arguments: Backend.allCases)
    func outboxRoundTripsEveryState(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let a = spaceName("A")
        let states: [OutboxState] = [
            .queued, .sending, .committed(messageName("A", "sent")), .unknown, .failed(reason: "quota exceeded"),
        ]
        let items = states.enumerated().map { index, state in
            OutboxItem(
                space: a,
                payload: OutboxPayload(
                    text: "message \(index)", thread: index.isMultiple(of: 2) ? threadName("A", "t") : nil,
                    attachmentUploadTokens: ["token-\(index)"]),
                state: state, attempts: index, created: stamp(Int64(10 - index), Int32(index)),
                nextAttempt: index == 1 ? stamp(99, 1) : nil)
        }
        try f.commit(
            .putOutbox(items[0]), .putOutbox(items[1]), .putOutbox(items[2]), .putOutbox(items[3]), .putOutbox(items[4])
        )
        #expect(try f.store.outbox() == Array(items.reversed()))

        var updated = items[0]
        updated.state = .failed(reason: "gone")
        updated.attempts = 9
        try f.commit(.putOutbox(updated))
        #expect(try f.store.outbox().first(where: { $0.id == updated.id }) == updated)
        #expect(try f.store.outbox().count == 5)

        try f.commit(.deleteOutbox(updated.id), .deleteOutbox(UUID()))
        #expect(try f.store.outbox().count == 4)
    }

    @Test(arguments: Backend.allCases)
    func notifiedTracksMessages(_ backend: Backend) throws {
        let f = try Fixture(backend)
        #expect(try !f.store.isNotified(messageName("A", "m1")))
        try f.commit(.markNotified([messageName("A", "m1"), messageName("A", "m2")], at: stamp(5)))
        try f.commit(.markNotified([messageName("A", "m1")], at: stamp(9)))
        #expect(try f.store.isNotified(messageName("A", "m1")))
        #expect(try f.store.isNotified(messageName("A", "m2")))
        #expect(try !f.store.isNotified(messageName("A", "m3")))
    }

    @Test(arguments: Backend.allCases)
    func metaSetOverwriteDelete(_ backend: Backend) throws {
        let f = try Fixture(backend)
        #expect(try f.store.meta("k") == nil)
        try f.commit(.setMeta(key: "k", value: "one"), .setMeta(key: "empty", value: ""))
        #expect(try f.store.meta("k") == "one")
        #expect(try f.store.meta("empty") == "")
        try f.commit(.setMeta(key: "k", value: "two \u{1F600}"))
        #expect(try f.store.meta("k") == "two \u{1F600}")
        try f.commit(.setMeta(key: "k", value: nil))
        #expect(try f.store.meta("k") == nil)
        try f.commit(.setMeta(key: "never", value: nil))
    }

    @Test(arguments: Backend.allCases)
    func membersRoundTrip(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let a = spaceName("A")
        let first = Membership(name: MembershipName(unchecked: "spaces/A/members/1"), member: ann, role: .manager)
        let second = Membership(
            name: MembershipName(unchecked: "spaces/A/members/2"),
            member: User(name: UserName(unchecked: "users/2"), type: .bot, displayName: nil, isAnonymous: true),
            state: .invited)
        try f.commit(.setMembers(a, [first, second], title: "Ann, Bot", fetched: stamp(1)))
        #expect(try f.store.members(in: a) == [first, second])
        try f.commit(.setMembers(a, [first], title: nil, fetched: stamp(2)))
        #expect(try f.store.members(in: a) == [first])
        #expect(try f.store.members(in: spaceName("none")).isEmpty)
    }

    @Test(arguments: Backend.allCases)
    func messageWindowOrderingAndPaging(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let messages =
            (1...10).map { makeMessage(id: "m\($0)", at: Int64($0) * 10) } + [
                makeMessage(id: "tie-a", at: 55), makeMessage(id: "tie-b", at: 55, nanos: 0),
                makeMessage(id: "sub", at: 55, nanos: 1), makeMessage(id: "gone", at: 15, deleted: 16),
                makeMessage(id: "reply", at: 25, thread: "t"),
            ]
        try f.commit(.upsertMessages(messages), .upsertMessages([makeMessage("B", "foreign", at: 12)]))
        let a = spaceName("A")

        let all = try f.store.messages(in: a, before: nil, limit: 100)
        #expect(all.count == 15)
        #expect(all.map(\.createTime) == all.map(\.createTime).sorted())
        #expect(all.contains { $0.isDeleted })
        #expect(all.contains { $0.isThreadReply })
        #expect(all.allSatisfy { $0.space == a })

        let newest = try f.store.messages(in: a, before: nil, limit: 3)
        #expect(
            newest.map(\.name.rawValue) == ["spaces/A/messages/m8", "spaces/A/messages/m9", "spaces/A/messages/m10"])

        let before = try f.store.messages(in: a, before: stamp(55), limit: 2)
        #expect(before.map(\.name.rawValue) == ["spaces/A/messages/m4", "spaces/A/messages/m5"])
        #expect(try f.store.messages(in: a, before: stamp(55, 1), limit: 2).last?.name == messageName("A", "tie-b"))
        #expect(try f.store.messages(in: a, before: stamp(10), limit: 5).isEmpty)

        #expect(try f.store.messages(in: a, before: nil, limit: 0).isEmpty)
        #expect(try f.store.messages(in: a, before: nil, limit: -1).isEmpty)
    }

    @Test(arguments: Backend.allCases)
    func threadQuery(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(
            .upsertMessages([
                makeMessage(id: "root", at: 10, thread: "t"), makeMessage(id: "r1", at: 30, thread: "t"),
                makeMessage(id: "r2", at: 20, thread: "t"), makeMessage(id: "r3", at: 40, deleted: 41, thread: "t"),
                makeMessage(id: "other", at: 25, thread: "u"), makeMessage(id: "plain", at: 26),
            ]))
        let t = threadName("A", "t")
        #expect(
            try f.store.messages(inThread: t, limit: 10).map(\.name.rawValue).map {
                String($0.split(separator: "/").last!)
            } == ["root", "r2", "r1", "r3"])
        #expect(
            try f.store.messages(inThread: t, limit: 2).map(\.name.rawValue).map {
                String($0.split(separator: "/").last!)
            } == ["r1", "r3"])
        #expect(try f.store.messages(inThread: threadName("A", "none"), limit: 10).isEmpty)
        #expect(try f.store.messages(inThread: t, limit: 0).isEmpty)
    }

    @Test(arguments: Backend.allCases)
    func retiredGateRejectsWritesAndChangesNothing(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.setMeta(key: "k", value: "before"))
        f.gate.retire()
        #expect(throws: StoreError.gateClosed) {
            try f.commit(
                .setMeta(key: "k", value: "after"), .upsertMessages([makeMessage(id: "m", at: 1)]),
                .mergeSpace(makeSpace()))
        }
        #expect(try f.store.meta("k") == "before")
        #expect(try f.store.message(messageName("A", "m")) == nil)
        #expect(try f.store.spaces().isEmpty)
    }

    @Test(arguments: Backend.allCases)
    func closedGateRejectsWrites(_ backend: Backend) throws {
        let f = try Fixture(backend)
        f.gate.retire()
        f.gate.close()
        #expect(throws: StoreError.gateClosed) { try f.commit(.setMeta(key: "k", value: "x")) }
        #expect(try f.store.meta("k") == nil)
    }

    @Test(arguments: Backend.allCases)
    func staleGenerationRejectedAfterActivate(_ backend: Backend) throws {
        let f = try Fixture(backend)
        let old = f.generation
        f.gate.retire()
        let fresh = f.gate.activate()
        #expect(fresh > old)

        #expect(throws: StoreError.gateClosed) { try f.commit(.setMeta(key: "k", value: "stale")) }
        #expect(try f.store.meta("k") == nil)

        f.generation = fresh
        try f.commit(.setMeta(key: "k", value: "fresh"))
        #expect(try f.store.meta("k") == "fresh")
    }

    @Test(arguments: Backend.allCases)
    func emptyBatchConvenienceIsANoOp(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.store.write(gate: f.gate, generation: f.generation) { _ in }
        try f.store.write(StoreWrite(), gate: f.gate, generation: f.generation)
        f.gate.retire()
        #expect(throws: StoreError.gateClosed) {
            try f.store.write(StoreWrite(), gate: f.gate, generation: f.generation)
        }
    }

    @Test(arguments: Backend.allCases)
    func concurrentReadersAndWritersStayConsistent(_ backend: Backend) async throws {
        let f = try Fixture(backend)
        let store = f.store
        let gate = f.gate
        let generation = f.generation
        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<4 {
                group.addTask {
                    for index in 0..<25 {
                        try store.write(gate: gate, generation: generation) {
                            $0.append(.upsertMessages([makeMessage(id: "w\(writer)-\(index)", at: Int64(index))]))
                            $0.append(.setMeta(key: "writer\(writer)", value: "\(index)"))
                        }
                    }
                }
                group.addTask {
                    for _ in 0..<25 { _ = try store.messages(in: spaceName("A"), before: nil, limit: 10) }
                }
            }
            try await group.waitForAll()
        }
        #expect(try f.store.messages(in: spaceName("A"), before: nil, limit: 1000).count == 100)
        #expect(try f.store.meta("writer3") == "24")
    }
}
