import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

struct SendRig: Sendable {
    let server = FakeChatServer()
    let alice: FakeAccount
    let team: SpaceName
    let other: SpaceName
    let store = InMemoryAccountStore()
    let gate = SessionGate()
    let clock: ManualClock
    let barrier = Barrier()
    let calls = CallLog()
    let tamper = PageTamper()
    let api: BarrierAPI
    let sends: SendQueue

    init() {
        alice = server.addAccount(displayName: "Alice")
        team = server.addSpace(.space, displayName: "Team", members: [alice])
        other = server.addSpace(.space, displayName: "Other", members: [alice])
        server.advance(.seconds(5))
        clock = ManualClock(start: server.now)
        api = BarrierAPI(
            base: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token)),
            barrier: barrier, log: calls, clock: clock, tamper: tamper)
        sends = SendQueue(api: api, store: store, gate: gate, clock: clock)
    }

    var generation: Generation { gate.current! }

    @discardableResult
    func enqueue(
        _ text: String, in space: SpaceName? = nil, thread: ThreadName? = nil, tick: Duration = .milliseconds(1)
    ) throws -> OutboxItem {
        defer { clock.advance(tick) }
        return try sends.enqueue(text: text, space: space ?? team, thread: thread, generation)
    }

    func drain(_ space: SpaceName? = nil) async throws -> [UUID: SendOutcome] {
        try #require(try await sends.drain(space ?? team, generation))
    }

    func serverTexts(_ space: SpaceName? = nil) -> [String] {
        server.messages(in: space ?? team).map(\.text)
    }

    func createRequestIDs() -> [String] {
        server.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/messages") }
            .compactMap { $0.value(for: "requestId") }
    }

    func restarted() -> (queue: SendQueue, generation: Generation) {
        let newGate = SessionGate()
        return (SendQueue(api: api, store: store, gate: newGate, clock: clock), newGate.current!)
    }

    func outbox() throws -> [OutboxItem] { try store.outbox() }
}

func draftFile(_ name: String) -> PendingAttachment {
    PendingAttachment(bookmark: Data(name.utf8), filename: name, contentType: "application/pdf", byteCount: 10)
}

func isSent(_ outcome: SendOutcome?) -> Bool {
    if case .sent = outcome { true } else { false }
}

func isWillRetry(_ outcome: SendOutcome?) -> Bool {
    if case .willRetry = outcome { true } else { false }
}

struct SendTests {
    @Test func twoSendsInOneSpaceAreAtLeastASecondApart() async throws {
        let rig = SendRig()
        try rig.enqueue("one")
        try rig.enqueue("two")

        let outcomes = try await rig.drain()

        #expect(outcomes.count == 2 && outcomes.values.allSatisfy(isSent))
        let times = rig.calls.times("createMessage")
        #expect(times.count == 2)
        #expect(times[1].offset(from: times[0]) >= .seconds(1))
        #expect(rig.clock.sleeps == [.seconds(1)])
        #expect(rig.serverTexts() == ["one", "two"])
    }

    @Test func aSendAfterAlongPauseNeedsNoWait() async throws {
        let rig = SendRig()
        try rig.enqueue("one")
        _ = try await rig.drain()
        rig.clock.advance(.seconds(3))
        try rig.enqueue("two")
        _ = try await rig.drain()

        let times = rig.calls.times("createMessage")
        #expect(times[1].offset(from: times[0]) >= .seconds(3))
        #expect(rig.clock.sleeps.isEmpty)
    }

    @Test func differentSpacesAreNotPacedAgainstEachOther() async throws {
        let rig = SendRig()
        try rig.enqueue("team 1", in: rig.team, tick: .zero)
        try rig.enqueue("other 1", in: rig.other, tick: .zero)

        _ = try await rig.drain(rig.team)
        _ = try await rig.drain(rig.other)

        let times = rig.calls.times("createMessage")
        #expect(times.count == 2)
        #expect(times[0] == times[1], "the second space waited for the first")
        #expect(rig.clock.sleeps.isEmpty)

        try rig.enqueue("team 2", in: rig.team)
        _ = try await rig.drain(rig.team)
        let all = rig.calls.times("createMessage")
        #expect(all.count == 3)
        #expect(all[2].offset(from: all[0]) >= .seconds(1), "the same space still waits its own second")
        #expect(rig.clock.sleeps.count == 1)
    }

    @Test func pacingAlsoCoversAFailedWrite() async throws {
        let rig = SendRig()
        rig.server.fail(.unavailable(route: .createMessage))
        try rig.enqueue("one")
        let first = try await rig.drain()
        #expect(first.values.allSatisfy(isWillRetry))

        rig.clock.advance(.seconds(120))
        _ = try await rig.drain()
        let times = rig.calls.times("createMessage")
        #expect(times.count == 2)
        #expect(times[1].offset(from: times[0]) >= .seconds(1))
    }

    @Test func aSecondDrainOfTheSameSpaceReturnsNilWhileTheFirstIsRunning() async throws {
        let rig = SendRig()
        try rig.enqueue("one")
        rig.barrier.arm()
        let sends = rig.sends
        let generation = rig.generation
        let team = rig.team
        let running = Task { () async -> Bool in
            let outcomes = try? await sends.drain(team, generation)
            return outcomes != nil
        }
        #expect(await rig.barrier.waitForArrival())

        let second = try await rig.sends.drain(rig.team, rig.generation)
        #expect(second == nil)
        rig.barrier.release()
        #expect(await running.value)
        #expect(rig.serverTexts() == ["one"])
    }

    @Test func aRestartedQueueResendsAnInterruptedSendWithTheSameRequestID() async throws {
        let rig = SendRig()
        let queued = try rig.enqueue("queued, never started")
        let failed = try rig.enqueue("failed earlier")
        let item = try rig.enqueue("in flight at the crash")
        var failedItem = failed
        failedItem.state = .failed(reason: "invalid")
        var sending = item
        sending.state = .sending
        sending.attempts = 1
        try rig.store.write(gate: rig.gate, generation: rig.generation) {
            $0.append(.putOutbox(failedItem))
            $0.append(.putOutbox(sending))
        }
        let landed = try await rig.api.base.createMessage(
            NewMessage(space: rig.team, text: item.payload.text, requestID: item.requestID))
        #expect(rig.serverTexts() == ["in flight at the crash"])

        rig.gate.retire()
        let (queue, generation) = rig.restarted()
        try queue.recoverInterrupted(generation)

        let recovered = try rig.outbox().reduce(into: [UUID: OutboxState]()) { $0[$1.id] = $1.state }
        #expect(recovered[item.id] == .unknown)
        #expect(recovered[queued.id] == .queued)
        #expect(recovered[failed.id] == .failed(reason: "invalid"))

        rig.clock.advance(.seconds(1))
        let outcomes = try #require(try await queue.drain(rig.team, generation))
        #expect(outcomes[item.id] == .sent(landed.name))
        #expect(outcomes[queued.id] == .sent(try #require(rig.server.messages(in: rig.team).last).name))
        #expect(rig.serverTexts().filter { $0 == "in flight at the crash" }.count == 1, "duplicated on the server")
        #expect(Set(rig.serverTexts()) == ["in flight at the crash", "queued, never started"])
        #expect(try rig.outbox().map(\.id) == [failed.id])
        let ids = rig.createRequestIDs()
        #expect(
            ids.filter { $0 == item.requestID.uuidString.lowercased() }.count == 2,
            "the retry must reuse the request ID")
    }

    @Test func aLostResponseThenARestartStillResolvesToOneMessage() async throws {
        let rig = SendRig()
        rig.server.fail(.lostResponse())
        let item = try rig.enqueue("hello")

        let first = try await rig.drain()
        #expect(isWillRetry(first[item.id]))
        #expect(try rig.outbox().first?.state == .unknown)
        #expect(rig.serverTexts() == ["hello"])

        rig.gate.retire()
        let (queue, generation) = rig.restarted()
        try queue.recoverInterrupted(generation)
        #expect(try rig.outbox().first?.state == .unknown)
        rig.clock.advance(.seconds(120))
        let second = try #require(try await queue.drain(rig.team, generation))

        #expect(isSent(second[item.id]))
        #expect(rig.serverTexts() == ["hello"])
        #expect(try rig.outbox().isEmpty)
        #expect(Set(rig.createRequestIDs()).count == 1)
        #expect(rig.createRequestIDs().count == 2)
    }

    @Test func unauthorizedKeepsTheItemQueuedAndReturnsNeedsLogin() async throws {
        let rig = SendRig()
        rig.server.fail(.unauthenticated(route: .createMessage, times: 2))
        let item = try rig.enqueue("hello")

        let first = try await rig.drain()

        #expect(first[item.id] == .needsLogin)
        let stored = try #require(try rig.outbox().first)
        #expect(stored.state == .queued)
        #expect(stored.nextAttempt == nil)
        #expect(try rig.store.drafts().isEmpty)
        #expect(rig.serverTexts().isEmpty)

        let second = try await rig.drain()
        #expect(isSent(second[item.id]))
        #expect(rig.serverTexts() == ["hello"])
    }

    @Test func unauthorizedAfterAnUnknownOutcomeStaysUnknown() async throws {
        let rig = SendRig()
        rig.server.fail(.lostResponse())
        rig.server.fail(.unauthenticated(route: .createMessage, times: 2))
        let item = try rig.enqueue("hello")
        _ = try await rig.drain()
        #expect(try rig.outbox().first?.state == .unknown)

        rig.clock.advance(.seconds(120))
        let unauthorized = try await rig.drain()
        #expect(unauthorized[item.id] == .needsLogin)
        #expect(try rig.outbox().first?.state == .unknown, "a possibly-landed send must not look unsent")

        let final = try await rig.drain()
        #expect(isSent(final[item.id]))
        #expect(rig.serverTexts() == ["hello"])
    }

    @Test(arguments: [
        (400, "INVALID_ARGUMENT", "invalid"), (403, "PERMISSION_DENIED", "permissionDenied"),
        (404, "NOT_FOUND", "notFound"), (409, "ABORTED", "conflict"),
    ])
    func anExplicit4xxFailsTheItemAndRestoresTheDraft(status: Int, google: String, reason: String) async throws {
        let rig = SendRig()
        rig.server.fail(FailureRule(route: .createMessage, response: .http(status: status, googleStatus: google)))
        let item = try rig.enqueue("my words")
        #expect(try rig.store.drafts().isEmpty, "enqueue clears the composer")

        let outcomes = try await rig.drain()

        #expect(outcomes[item.id] == .failed(reason: reason))
        let stored = try #require(try rig.outbox().first)
        #expect(stored.state == .failed(reason: reason))
        let draft = try #require(try rig.store.drafts().first)
        #expect(draft.text == "my words")
        #expect(draft.space == rig.team)
        #expect(rig.serverTexts().isEmpty)
    }

    @Test func aDraftTheUserStartedMeanwhileIsNotOverwritten() async throws {
        let rig = SendRig()
        rig.server.fail(
            FailureRule(route: .createMessage, response: .http(status: 400, googleStatus: "INVALID_ARGUMENT")))
        let item = try rig.enqueue("first try")
        let newer = Draft(space: rig.team, thread: nil, text: "something new", updated: rig.clock.now())
        try rig.store.write(gate: rig.gate, generation: rig.generation) { $0.append(.putDraft(newer)) }

        let outcomes = try await rig.drain()

        #expect(outcomes[item.id] == .failed(reason: "invalid"))
        #expect(try rig.store.drafts() == [newer])
        #expect(try rig.outbox().first?.payload.text == "first try", "the failed payload stays recoverable")
    }

    @Test func anAttachmentOnlyDraftCountsAsStarted() async throws {
        let rig = SendRig()
        rig.server.fail(
            FailureRule(route: .createMessage, response: .http(status: 400, googleStatus: "INVALID_ARGUMENT")))
        let item = try rig.enqueue("first try")
        let newer = Draft(
            space: rig.team, thread: nil, text: "", attachments: [draftFile("new.pdf")], updated: rig.clock.now())
        try rig.store.write(gate: rig.gate, generation: rig.generation) { $0.append(.putDraft(newer)) }

        let outcomes = try await rig.drain()

        #expect(outcomes[item.id] == .failed(reason: "invalid"))
        #expect(try rig.store.drafts() == [newer])
    }

    @Test func aFailedSendReturnsItsFilesAndReplacesAnEmptyLegacyDraft() async throws {
        let rig = SendRig()
        let empty = Draft(space: rig.team, thread: nil, text: "", updated: rig.clock.now())
        try rig.store.write(gate: rig.gate, generation: rig.generation) { $0.append(.putDraft(empty)) }
        let file = draftFile("report.pdf")
        let item = OutboxItem(
            space: rig.team, payload: OutboxPayload(text: "", thread: nil, attachments: [file]),
            created: rig.clock.now())

        _ = try rig.sends.fail(item, reason: "invalid", rig.generation)

        let draft = try #require(try rig.store.drafts().first)
        #expect(draft.attachments == [file])
        #expect(draft.text.isEmpty)
    }

    @Test func repostingKeepsTheRoomDraftAndTheFiles() async throws {
        let rig = SendRig()
        let roomDraft = Draft(space: rig.team, thread: nil, text: "unsent", updated: rig.clock.now())
        try rig.store.write(gate: rig.gate, generation: rig.generation) { $0.append(.putDraft(roomDraft)) }
        let file = draftFile("photo.png")
        let failed = try rig.sends.enqueue(
            text: "", space: rig.team, thread: ThreadName(unchecked: "\(rig.team.rawValue)/threads/gone"),
            attachments: [file], rig.generation)

        let item = try rig.sends.enqueue(
            text: failed.payload.text, space: rig.team, thread: nil, attachments: failed.payload.attachments,
            clearsDraft: false, replacing: failed.id, rig.generation)

        #expect(try rig.store.drafts() == [roomDraft])
        #expect(try rig.outbox().map(\.id) == [item.id])
        #expect(item.payload.attachments == [file])
    }

    @Test(arguments: [429, 503])
    func rateLimitsAndServerErrorsRetryInsteadOfFailing(status: Int) async throws {
        let rig = SendRig()
        rig.server.fail(
            FailureRule(
                route: .createMessage,
                response: .http(
                    status: status, googleStatus: status == 429 ? "RESOURCE_EXHAUSTED" : "UNAVAILABLE",
                    retryAfterSeconds: status == 429 ? 30 : nil)))
        let item = try rig.enqueue("patient")

        let first = try await rig.drain()

        guard case .willRetry(let at) = first[item.id] else {
            Issue.record("expected willRetry, got \(String(describing: first[item.id]))")
            return
        }
        #expect(at.offset(from: rig.clock.now()) >= .seconds(1))
        #expect(try rig.store.drafts().isEmpty)
        #expect(try rig.outbox().first?.state.isTerminal == false)
    }

    @Test func aLaterItemNeverOvertakesAnEarlierOneWaitingOnBackoff() async throws {
        let rig = SendRig()
        rig.server.fail(.unavailable(route: .createMessage))
        let early = try rig.enqueue("early")
        let late = try rig.enqueue("late")

        let first = try await rig.drain()
        #expect(isWillRetry(first[early.id]))
        #expect(first[late.id] == nil, "the later item was attempted behind a waiting one")
        #expect(rig.serverTexts().isEmpty)

        let second = try await rig.drain()
        #expect(isWillRetry(second[early.id]))
        #expect(second[late.id] == nil)
        #expect(rig.calls.count("createMessage") == 1, "no request while the earlier item waits")
        #expect(rig.serverTexts().isEmpty)

        rig.clock.advance(.seconds(120))
        let third = try await rig.drain()
        #expect(isSent(third[early.id]) && isSent(third[late.id]))
        #expect(rig.serverTexts() == ["early", "late"])
    }

    @Test func aFailedItemDoesNotBlockTheOnesBehindIt() async throws {
        let rig = SendRig()
        rig.server.fail(
            FailureRule(route: .createMessage, response: .http(status: 400, googleStatus: "INVALID_ARGUMENT")))
        let bad = try rig.enqueue("bad")
        let good = try rig.enqueue("good")

        let outcomes = try await rig.drain()

        #expect(outcomes[bad.id] == .failed(reason: "invalid"))
        #expect(isSent(outcomes[good.id]))
        #expect(rig.serverTexts() == ["good"])
    }

    @Test func itemsEnqueuedInTheSameInstantKeepTheirEnqueueOrder() async throws {
        let rig = SendRig()
        let texts = (0..<12).map { "item \($0)" }
        for text in texts { try rig.enqueue(text, tick: .zero) }

        _ = try await rig.drain()

        #expect(rig.serverTexts() == texts)
    }

    @Test func aReplyToAGoneThreadFailsWithoutFallingBackToANewThread() async throws {
        let rig = SendRig()
        let ghost = try #require(ThreadName("spaces/\(rig.team.id(at: 0))/threads/gone"))
        let item = try rig.enqueue("reply", thread: ghost)

        let outcomes = try await rig.drain()

        #expect(outcomes[item.id] == .failed(reason: "threadGone"))
        #expect(try rig.store.drafts().first?.thread == ghost)
        #expect(rig.serverTexts().isEmpty)
    }

    @Test func aCancelledTransportAfterDispatchIsUnknownNotFailed() async throws {
        let rig = SendRig()
        rig.server.fail(.networkError(.cancelled, route: .createMessage))
        let item = try rig.enqueue("maybe sent")

        let outcomes = try await rig.drain()

        let stored = try #require(try rig.outbox().first)
        #expect(stored.state != .failed(reason: "rejected"))
        #expect(stored.state.isTerminal == false, "a cancelled request may have landed; it is not a rejection")
        #expect(try rig.store.drafts().isEmpty)
        if case .failed = outcomes[item.id] {
            Issue.record("reported failed: \(String(describing: outcomes[item.id]))")
        }

        rig.clock.advance(.seconds(120))
        _ = try await rig.drain()
        #expect(rig.serverTexts() == ["maybe sent"])
        #expect(try rig.outbox().isEmpty)
    }

    @Test func sendsEnqueuedWhileADrainIsRunningAreNotDropped() async throws {
        let rig = SendRig()
        try rig.enqueue("one")
        rig.barrier.arm()
        let sends = rig.sends
        let generation = rig.generation
        let team = rig.team
        let first = Task { () async -> Bool in
            let outcomes = try? await sends.drain(team, generation)
            return outcomes != nil
        }
        #expect(await rig.barrier.waitForArrival())

        try rig.enqueue("two")
        let overlapping = try await rig.sends.drain(rig.team, rig.generation)
        #expect(overlapping == nil)
        rig.barrier.release()
        #expect(await first.value)

        if rig.serverTexts().count < 2 { _ = try await rig.sends.drain(rig.team, rig.generation) }
        #expect(rig.serverTexts() == ["one", "two"])
        #expect(try rig.outbox().isEmpty)
    }

    @Test func aBurstOfSessionSendsAllArriveInOrder() async throws {
        try await IsolationRig.run { rig in
            let texts = (1...5).map { "burst \($0)" }
            for text in texts {
                try await rig.sessionA.send(text, in: rig.spaceA, thread: nil)
                rig.server.advance(.milliseconds(1))
            }

            let delivered = await poll(timeout: .seconds(8)) {
                rig.server.messages(in: rig.spaceA).filter { $0.text.hasPrefix("burst") }.count == texts.count
            }
            #expect(delivered, "a send enqueued during a drain was dropped")
            #expect(rig.server.messages(in: rig.spaceA).map(\.text).filter { $0.hasPrefix("burst") } == texts)
            let drained = await poll { ((try? rig.sessionA.outbox(in: rig.spaceA)) ?? []).isEmpty }
            #expect(drained)
        }
    }

    @Test func aFailedFollowUpGetKeepsTheItemCommittedUntilItSucceeds() async throws {
        let rig = SendRig()
        rig.tamper.setDropCreatedMessage(true)
        rig.server.fail(.unavailable(route: .getMessage))
        let item = try rig.enqueue("landed")

        let first = try await rig.drain()

        let name = try #require(rig.server.messages(in: rig.team).first?.name)
        #expect(first[item.id] == .sent(name))
        #expect(try rig.outbox().first?.state == .committed(name), "a failed get must not undo a committed send")
        #expect(try rig.store.message(name) == nil)

        _ = try await rig.drain()
        #expect(try rig.outbox().isEmpty)
        #expect(try rig.store.message(name)?.text == "landed")
        #expect(rig.serverTexts() == ["landed"])
        #expect(rig.calls.count("createMessage") == 1, "a committed item must not be created again")
    }
}
