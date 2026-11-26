import ChatKeychain
import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatSync

/// Holds an empty pull on the clock for `hold`, as Google does when nothing is queued.
struct HoldingPubSub: PubSubAPI {
    let base: any PubSubAPI
    let clock: any SyncClock
    let hold: Duration
    let pulls: CallLog
    let ackBarrier: Barrier

    func getSubscription(_ path: PubSubSubscriptionPath) async throws(ChatAPIError) -> PubSubSubscription {
        try await base.getSubscription(path)
    }

    func pull(_ path: PubSubSubscriptionPath, maxMessages: Int) async throws(ChatAPIError) -> [ReceivedEvent] {
        pulls.record("start", at: clock.now())
        let received = try await base.pull(path, maxMessages: maxMessages)
        if received.isEmpty, hold > .zero {
            do { try await clock.sleep(for: hold) } catch { throw .transport(.cancelled) }
        }
        pulls.record("end", at: clock.now())
        return received
    }

    func acknowledge(_ path: PubSubSubscriptionPath, ackIDs: [String]) async throws(ChatAPIError) {
        await ackBarrier.pass()
        try await base.acknowledge(path, ackIDs: ackIDs)
    }
}

/// A Workspace subscription `get` answers with instead of asking the server.
final class StaleGets: Sendable {
    private let value = Mutex<EventSubscription?>(nil)

    func set(_ subscription: EventSubscription?) { value.withLock { $0 = subscription } }
    func answer(_ name: EventSubscriptionName) -> EventSubscription? { value.withLock { $0?.name == name ? $0 : nil } }
}

/// Lets a test answer create with ALREADY_EXISTS, park a create's answer or a get until released, or script a get.
struct ScriptedEvents: WorkspaceEventsAPI {
    let base: any WorkspaceEventsAPI
    let conflictOnCreate: Bool
    let createBarrier: Barrier
    let getBarrier: Barrier
    let staleGets: StaleGets

    func createSubscription(topic: PubSubTopicPath) async throws(ChatAPIError) -> EventSubscription {
        if conflictOnCreate {
            throw .conflict(GoogleErrorInfo(httpStatus: 409, status: "ALREADY_EXISTS"))
        }
        let created = try await base.createSubscription(topic: topic)
        await createBarrier.pass()
        return created
    }

    func getSubscription(_ name: EventSubscriptionName) async throws(ChatAPIError) -> EventSubscription {
        var found = staleGets.answer(name)
        if found == nil { found = try await base.getSubscription(name) }
        await getBarrier.pass()
        return found!
    }

    func listSubscriptions(filter: EventSubscriptionFilter) async throws(ChatAPIError) -> [EventSubscription] {
        try await base.listSubscriptions(filter: filter)
    }

    func renewSubscription(_ name: EventSubscriptionName) async throws(ChatAPIError) -> EventSubscription {
        try await base.renewSubscription(name)
    }

    func reactivateSubscription(_ name: EventSubscriptionName) async throws(ChatAPIError) -> EventSubscription {
        try await base.reactivateSubscription(name)
    }

    func deleteSubscription(_ name: EventSubscriptionName) async throws(ChatAPIError) {
        try await base.deleteSubscription(name)
    }
}

/// One account on one fake server inside a simulated world; every `Mac` is a session with its own store and pull
/// subscription.
final class EventWorld: Sendable {
    static let topic = PubSubTopicPath("projects/example-project/topics/gchat-events-1")!

    let sim: SimWorld
    let server: FakeChatServer
    let alice: FakeAccount
    let bob: FakeAccount
    let space: SpaceName
    let clock: SimClock

    static func run(_ body: @escaping @Sendable (EventWorld) async throws -> Void) async throws {
        try await SimWorld.run { sim in try await body(EventWorld(sim)) }
    }

    init(_ sim: SimWorld) {
        self.sim = sim
        server = sim.server
        alice = server.addAccount(displayName: "Alice")
        bob = server.addAccount(displayName: "Bob")
        space = server.addSpace(.space, displayName: "Team", members: [alice, bob])
        server.post("history", in: space, from: .account(bob))
        server.advance(.seconds(5))
        clock = sim.clock()
    }

    static func path(_ device: String) -> PubSubSubscriptionPath {
        PubSubSubscriptionPath("projects/example-project/subscriptions/gchat-events-1-\(device)")!
    }

    func client(_ account: FakeAccount? = nil) -> WorkspaceEventsClient {
        WorkspaceEventsClient(
            transport: sim.transport(), tokens: StaticTokens(token: (account ?? alice).token),
            sleeper: { _ in })
    }

    var workspaceSubscription: FakeChatServer.EventSubscriptionInfo? {
        server.eventSubscriptions.first { $0.pubsubTopic == Self.topic.rawValue }
    }

    /// Posts as Bob and publishes the matching event from the current Workspace subscription.
    @discardableResult
    func post(_ text: String, source: String? = nil) -> Message {
        let message = server.post(text, in: space, from: .account(bob))
        publish([message.name], source: source)
        return message
    }

    func publish(_ messages: [MessageName], source: String? = nil) {
        guard let name = source ?? workspaceSubscription?.name else { return }
        server.publishMessagesCreated(topic: Self.topic.rawValue, subscription: name, space: space, messages: messages)
    }

    /// Steps virtual time from deadline to deadline until `condition` holds.
    func run(upTo limit: Duration = .seconds(120), _ condition: () async -> Bool) async -> Bool {
        await sim.run(upTo: limit, until: condition)
    }

    /// Lets time pass with nothing to wait for.
    func pass(_ duration: Duration) async { await sim.pass(duration) }

    func requests(_ method: String, _ suffix: String) -> Int {
        server.requests.filter { $0.method == method && $0.path.hasSuffix(suffix) }.count
    }

    var deletes: Int {
        server.requests.filter { $0.method == "DELETE" && $0.path.hasPrefix("/v1/subscriptions/") }.count
    }

    func shutdown(_ macs: Mac...) async throws {
        for mac in macs { try await mac.shutdown() }
    }
}

struct Mac: Sendable {
    let world: EventWorld
    let path: PubSubSubscriptionPath
    let store = InMemoryAccountStore()
    let scratch = ScratchDirectory()
    let poster = RecordingPoster()
    let pulls = CallLog()
    let createBarrier: Barrier
    let getBarrier: Barrier
    let ackBarrier: Barrier
    let staleGets = StaleGets()
    let session: AccountSession
    let recorder: SnapshotRecorder

    init(
        _ world: EventWorld, device: String = "mac-a", register: Bool = true, hold: Duration = .zero,
        conflictOnCreate: Bool = false, hasScope: Bool = true
    ) {
        self.world = world
        let sim = world.sim
        createBarrier = sim.barrier()
        getBarrier = sim.barrier()
        ackBarrier = sim.barrier()
        path = EventWorld.path(device)
        if register { world.server.addPullSubscription(path.rawValue, topic: EventWorld.topic.rawValue) }
        var timing = SessionTiming.fast
        timing.sidebarInterval = .seconds(3600)
        timing.inactiveSidebarInterval = .seconds(3600)
        timing.liveSidebarInterval = .seconds(3600)
        timing.idleSleep = .seconds(3600)
        timing.logoutDrain = .seconds(2)
        let client = world.client()
        let services = EventServices(
            events: ScriptedEvents(
                base: client, conflictOnCreate: conflictOnCreate, createBarrier: createBarrier, getBarrier: getBarrier,
                staleGets: staleGets),
            pubsub: HoldingPubSub(base: client, clock: world.clock, hold: hold, pulls: pulls, ackBarrier: ackBarrier),
            hasScope: hasScope)
        let session = AccountSession(
            account: AccountID(), me: world.alice.user.name,
            api: GoogleChatClient(
                transport: sim.transport(), tokens: StaticTokens(token: world.alice.token)),
            store: store, clock: world.clock,
            logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: scratch.url)),
            timing: timing, notifications: poster, events: services, executor: sim.executor)
        self.session = session
        recorder = SnapshotRecorder(session.snapshots.values, in: sim)
        sim.onTeardown { [scratch] in
            // Logout writes its tombstone here, so the directory has to outlive the test body.
            _ = scratch
            guard await !session.closing else { return }
            _ = try? await sim.perform { await session.logout(refreshToken: nil) }
        }
    }

    var channel: EventChannel { session.eventChannel! }
    var status: EventChannelStatus? { channel.status.current }

    /// Starts with the channel configured and runs to the first sidebar sync.
    func start(enabled: Bool = true) async -> Bool {
        await session.configureEvents(EventSettings(subscriptionPath: path.rawValue, enabled: enabled))
        await session.start()
        let space = world.space
        return await recorder.wait(in: world.sim) { $0.status == .ok && $0.spaces.contains { $0.name == space } }
            != nil
    }

    /// The channel publishes its status before it tells the session, so tests wait for both.
    func liveChannelIs(_ live: Bool) async -> Bool { await session.liveChannel == live }

    func startLive() async -> Bool {
        guard await start() else { return false }
        return await world.run { await liveChannelIs(true) && status == .live }
    }

    var pullRequests: Int { world.requests("POST", path.rawValue + ":pull") }
    var unacked: Int { world.server.unackedCount(path.rawValue) }

    func hasMessage(_ message: Message) -> Bool { (try? store.message(message.name)) != nil }

    var storedSubscription: String? { (try? store.meta(EventChannel.subscriptionKey)) ?? nil }
    var storedExpiry: Timestamp? {
        ((try? store.meta(EventChannel.expiryKey)) ?? nil).flatMap { Timestamp(rfc3339: $0) }
    }

    /// Logs the session out, moving time through the drain if a task is stuck.
    @discardableResult
    func shutdown() async throws -> AccountSession.LogoutReport {
        let session = session
        let report = try await world.sim.perform { await session.logout(refreshToken: nil) }
        recorder.cancel()
        return report
    }
}

@Suite(.serialized) struct EventChannelTests {
    @Test func aPublishedMessageIsNotifiedWithoutWaitingForThePoll() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            #expect(await mac.session.liveChannel)
            let listings = world.requests("GET", "/v1/spaces")

            let message = world.post("ping")
            #expect(await world.run { mac.poster.posted.all.count == 1 })
            #expect(mac.poster.posted.all.first?.body == "Bob: ping")
            #expect(mac.hasMessage(message))
            #expect(mac.unacked == 0)
            #expect(world.requests("GET", "/v1/spaces") == listings, "the event, not a sidebar tick, found it")
            try await world.shutdown(mac)
        }
    }

    @Test func aMessageRightAfterAnEmptyPullArrivesWithinTheLatencyTarget() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let sent = world.server.now
            let message = world.post("right after")
            #expect(await world.run { mac.poster.posted.all.count == 1 })
            #expect(mac.hasMessage(message))
            let latency = world.server.now.interval(since: sent)
            #expect(latency <= .seconds(6), "took \(latency)")
            try await world.shutdown(mac)
        }
    }

    @Test func anEmptyPullThatHeldIsReissuedAtOnceAndAQuickOneWaitsTheFloor() async throws {
        try await EventWorld.run { world in
            let held = Mac(world, device: "held", hold: .seconds(6))
            #expect(await held.startLive())
            #expect(await world.run { held.pulls.count("end") >= 3 && held.pulls.count("start") >= 4 })
            let heldStarts = held.pulls.times("start")
            let heldEnds = held.pulls.times("end")
            for index in 1...3 {
                #expect(heldEnds[index - 1].interval(since: heldStarts[index - 1]) >= .seconds(6))
                #expect(heldStarts[index].interval(since: heldEnds[index - 1]) < .milliseconds(300))
            }

            let quick = Mac(world, device: "quick")
            #expect(await quick.startLive())
            #expect(await world.run { quick.pulls.times("start").count >= 3 })
            let quickStarts = quick.pulls.times("start")
            let quickEnds = quick.pulls.times("end")
            #expect(quickStarts[2].interval(since: quickEnds[1]) >= .seconds(2))
            try await world.shutdown(held, quick)
        }
    }

    @Test func aBatchDeliveryRecordsEveryMessage() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let messages = (0..<3).map { world.server.post("batch \($0)", in: world.space, from: .account(world.bob)) }
            world.publish(messages.map(\.name))
            #expect(await world.run { messages.allSatisfy(mac.hasMessage) })
            #expect(mac.unacked == 0)
            try await world.shutdown(mac)
        }
    }

    @Test func aSixtyIDBatchKeepsEveryIDBeforeTheAck() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let names = (0..<60).map { MessageName(unchecked: "\(world.space.rawValue)/messages/event\($0)") }
            world.publish(names)
            #expect(await world.run { mac.unacked == 0 })
            #expect(try mac.store.owed(world.space)?.ids.count == 60)
            try await world.shutdown(mac)
        }
    }

    @Test func idsPastTheOwedLimitAreNotAckedAndAreRedelivered() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let full = (0..<OwedRecord.maxMessages).map {
                MessageName(unchecked: "\(world.space.rawValue)/messages/full\($0)")
            }
            world.publish(full)
            let extra = world.server.post("one too many", in: world.space, from: .account(world.bob))
            world.publish([extra.name])
            #expect(await world.run { mac.unacked == 1 })
            #expect(try mac.store.owed(world.space)?.ids.count == OwedRecord.maxMessages)

            #expect(await world.run(upTo: .seconds(300)) { mac.unacked == 0 && mac.hasMessage(extra) })
            try await world.shutdown(mac)
        }
    }

    @Test func aSourceProvenForeignIsAckedWithoutRecording() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let ours = world.workspaceSubscription?.name
            let elsewhere = PubSubTopicPath("projects/example-project/topics/gchat-events-9")!
            let other = try await world.client().createSubscription(topic: elsewhere)
            let message = world.server.post("not ours", in: world.space, from: .account(world.bob))
            world.publish([message.name], source: other.name.rawValue)
            #expect(await world.run { mac.unacked == 0 })
            #expect(try mac.store.owed(world.space) == nil)
            #expect(world.requests("GET", other.name.rawValue) == 1)
            #expect(mac.storedSubscription == ours)
            try await world.shutdown(mac)
        }
    }

    @Test func anUnreadableSourceIsNeverAckedOrCachedAsForeign() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let listings = world.requests("GET", "/v1/spaces")
            let message = world.server.post("whose?", in: world.space, from: .account(world.bob))
            world.publish([message.name], source: "subscriptions/someone-else")
            #expect(await world.run { world.requests("GET", "/v1/spaces") > listings })
            await world.pass(.seconds(20))
            #expect(mac.unacked == 1, "a 404 doesn't prove the publisher is foreign")
            #expect(await mac.channel.foreign.isEmpty)
            try await world.shutdown(mac)
        }
    }

    @Test func aForbiddenVerificationIsRetriedAndTheReplacementAdopted() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let old = try #require(world.workspaceSubscription?.name)
            world.server.removeEventSubscription(old)
            let replacement = try await world.client().createSubscription(topic: EventWorld.topic)
            world.server.fail(.permissionDenied(route: .getEventSubscription, times: 1))

            let message = world.post("from the new publisher")
            #expect(await world.run { world.requests("GET", replacement.name.rawValue) == 1 })
            #expect(mac.unacked == 1)
            #expect(await world.run { mac.unacked == 0 && mac.hasMessage(message) })
            #expect(mac.storedSubscription == replacement.name.rawValue)
            try await world.shutdown(mac)
        }
    }

    @Test func aVerificationSupersededByAPathChangeChangesNothing() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let old = try #require(world.workspaceSubscription?.name)
            world.server.removeEventSubscription(old)
            _ = try await world.client().createSubscription(topic: EventWorld.topic)
            mac.getBarrier.arm()
            world.post("verify me")
            #expect(await world.run { mac.getBarrier.arrivals == 1 })

            let superseded = try #require(await mac.channel.runTask)
            let elsewhere = EventWorld.path("elsewhere").rawValue
            await mac.session.configureEvents(EventSettings(subscriptionPath: elsewhere))
            #expect(await world.run { mac.status == .setupIncomplete })
            mac.getBarrier.release()
            await superseded.value
            #expect(mac.storedSubscription == old)
            #expect(await mac.channel.subscription?.rawValue == old)
            #expect(await mac.channel.accepted.isEmpty)
            #expect(mac.status == .setupIncomplete)
            try await world.shutdown(mac)
        }
    }

    @Test func aRecreatedPublisherIsAdoptedBeforeTheAckAndNothingIsLost() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let old = try #require(world.workspaceSubscription?.name)
            world.server.removeEventSubscription(old)
            let replacement = try await world.client().createSubscription(topic: EventWorld.topic)

            let message = world.post("from the new publisher")
            #expect(await world.run { mac.hasMessage(message) && mac.unacked == 0 })
            #expect(mac.storedSubscription == replacement.name.rawValue)
            try await world.shutdown(mac)
        }
    }

    @Test func anInconclusiveVerificationLeavesTheEventQueuedUntilItCanBeChecked() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let old = try #require(world.workspaceSubscription?.name)
            world.server.removeEventSubscription(old)
            let replacement = try await world.client().createSubscription(topic: EventWorld.topic)
            let listings = world.requests("GET", "/v1/spaces")
            world.server.fail(.unavailable(route: .getEventSubscription, times: 1))

            let message = world.post("verify me")
            #expect(await world.run { world.requests("GET", "/v1/spaces") > listings })
            #expect(mac.unacked == 1, "an unverified event isn't acked")
            #expect(mac.storedSubscription == old)

            #expect(await world.run { mac.unacked == 0 && mac.hasMessage(message) })
            #expect(mac.storedSubscription == replacement.name.rawValue)
            try await world.shutdown(mac)
        }
    }

    @Test func repeatedAckFailuresDegradeTheChannel() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            world.server.fail(.unavailable(route: .acknowledge, times: nil))
            world.post("never acked")
            #expect(
                await world.run(upTo: .seconds(300)) {
                    if case .degraded = mac.status { await mac.liveChannelIs(false) } else { false }
                })
            #expect(!(await mac.session.liveChannel))
            try await world.shutdown(mac)
        }
    }

    @Test func theOwedSyncStartsBeforeTheAckReturns() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            mac.ackBarrier.arm()
            let message = world.post("fetch me first")
            #expect(await world.run { mac.ackBarrier.arrivals == 1 })
            #expect(await world.run(upTo: .seconds(20)) { mac.hasMessage(message) })
            mac.ackBarrier.release()
            #expect(await world.run { mac.unacked == 0 })
            try await world.shutdown(mac)
        }
    }

    @Test func aRestartIsNotLiveUntilTheNewRunValidates() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            world.server.fail(.unavailable(route: .getPullSubscription, times: nil))
            await mac.channel.restart()
            #expect(mac.status != .live)
            await world.pass(.seconds(5))
            #expect(mac.status != .live)
            #expect(!(await mac.session.liveChannel))
            try await world.shutdown(mac)
        }
    }

    @Test func aSubscriptionPastItsExpiryIsRecreatedEvenWhileReportedActive() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let old = try #require(world.workspaceSubscription?.name)
            let oldName = try #require(EventSubscriptionName(old))
            var lapsed = try await world.client().getSubscription(oldName)
            lapsed.expireTime = world.server.now.adding(.zero - .seconds(1))
            mac.staleGets.set(lapsed)
            world.server.removeEventSubscription(old)
            let patches = world.requests("PATCH", old)

            await mac.channel.restart()
            #expect(await world.run { mac.storedSubscription.map { $0 != old } ?? false })
            #expect(mac.storedSubscription == world.workspaceSubscription?.name)
            #expect(world.requests("PATCH", old) == patches)
            try await world.shutdown(mac)
        }
    }

    @Test func aLifecycleEventFromTheReplacedPublisherLeavesTheReplacementAlone() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let old = try #require(world.workspaceSubscription?.name)
            world.server.removeEventSubscription(old)
            let replacement = try await world.client().createSubscription(topic: EventWorld.topic)
            let creates = world.requests("POST", "/v1/subscriptions")

            world.server.publishLifecycle(.expired, topic: EventWorld.topic.rawValue, subscription: old)
            let message = world.post("from the new publisher")
            #expect(await world.run { mac.hasMessage(message) && mac.unacked == 0 })
            await world.pass(.seconds(5))
            #expect(world.requests("POST", "/v1/subscriptions") == creates)
            #expect(await mac.channel.subscription == replacement.name)
            #expect(mac.storedSubscription == replacement.name.rawValue)
            try await world.shutdown(mac)
        }
    }

    @Test func anExpirationReminderRenews() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let name = try #require(world.workspaceSubscription?.name)
            let before = try #require(mac.storedExpiry)
            world.server.advance(.seconds(3600))
            world.server.publishLifecycle(.expirationReminder, topic: EventWorld.topic.rawValue, subscription: name)
            #expect(await world.run { (mac.storedExpiry ?? before) > before })
            #expect(world.requests("PATCH", name) == 1)
            #expect(mac.storedExpiry == world.workspaceSubscription?.expireTime)
            try await world.shutdown(mac)
        }
    }

    @Test func aSuspendedEventReactivates() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let name = try #require(world.workspaceSubscription?.name)
            world.server.suspendEventSubscription(name)
            world.server.publishLifecycle(.suspended, topic: EventWorld.topic.rawValue, subscription: name)
            #expect(await world.run { world.workspaceSubscription?.state == "ACTIVE" })
            #expect(world.requests("POST", name + ":reactivate") == 1)
            #expect(await world.run { mac.status == .live })
            try await world.shutdown(mac)
        }
    }

    @Test func anExpiredEventCreatesANewSubscription() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let name = try #require(world.workspaceSubscription?.name)
            world.server.removeEventSubscription(name)
            world.server.publishLifecycle(.expired, topic: EventWorld.topic.rawValue, subscription: name)
            #expect(await world.run { world.workspaceSubscription.map { $0.name != name } ?? false })
            #expect(await world.run { mac.storedSubscription == world.workspaceSubscription?.name })
            let message = world.post("after the expiry")
            #expect(await world.run { mac.hasMessage(message) })
            try await world.shutdown(mac)
        }
    }

    @Test func aSilentSuspensionIsRepairedByTheHealthCheck() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let name = try #require(world.workspaceSubscription?.name)
            world.server.suspendEventSubscription(name)
            #expect(
                await world.run(upTo: .seconds(16 * 60)) {
                    world.workspaceSubscription?.state == "ACTIVE"
                })
            #expect(await world.run { mac.status == .live })
            try await world.shutdown(mac)
        }
    }

    @Test func aSilentExpiryIsRepairedByTheHealthCheck() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let name = try #require(world.workspaceSubscription?.name)
            world.server.removeEventSubscription(name)
            #expect(await world.run(upTo: .seconds(16 * 60)) { world.workspaceSubscription != nil })
            #expect(await world.run { mac.storedSubscription == world.workspaceSubscription?.name })
            #expect(await world.run { mac.status == .live })
            try await world.shutdown(mac)
        }
    }

    /// The fake applies a patch even when its operation fails or stays pending, so the next `get` sees the new expiry.
    @Test func aPendingOrFailingRenewalKeepsTheStoredExpiryUntilAGetConfirmsIt() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let name = try #require(world.workspaceSubscription?.name)
            for pending in [false, true] {
                await world.sim.settle()
                let stored = try #require(mac.storedExpiry)
                let patches = world.requests("PATCH", name)
                let failures = await mac.channel.healthFailures
                if pending {
                    world.server.eventOperationPollsBeforeDone = 50
                } else {
                    world.server.failNextEventOperation(code: 14)
                }
                // One jump, so the renewal is the first thing the channel does at the new time.
                await world.sim.jump(by: .seconds(6 * 86_400 + 3600))
                #expect(world.requests("PATCH", name) > patches)
                #expect(await mac.channel.healthFailures == failures + 1)
                let nextHealth = try #require(await mac.channel.nextHealth)
                let untilRetry = nextHealth.interval(since: world.server.now)
                #expect(untilRetry > .seconds(59) && untilRetry <= .seconds(60), "retries in \(untilRetry)")
                #expect(mac.storedExpiry == stored, "an unfinished renewal doesn't move the expiry")
                #expect(mac.status != .live)

                world.server.eventOperationPollsBeforeDone = 0
                #expect(await world.run(upTo: .seconds(900)) { (mac.storedExpiry ?? stored) > stored })
                #expect(mac.storedExpiry == world.workspaceSubscription?.expireTime)
                #expect(await world.run { mac.status == .live })
            }
            try await world.shutdown(mac)
        }
    }

    @Test func twoMacsShareOneWorkspaceSubscriptionAndBothReceive() async throws {
        try await EventWorld.run { world in
            let laptop = Mac(world, device: "laptop")
            let desktop = Mac(world, device: "desktop")
            #expect(await laptop.startLive())
            #expect(await desktop.startLive())
            #expect(world.server.eventSubscriptions.count == 1)
            #expect(laptop.storedSubscription == desktop.storedSubscription)

            let message = world.post("to both")
            #expect(await world.run { laptop.hasMessage(message) && desktop.hasMessage(message) })
            #expect(await world.run { laptop.poster.posted.all.count == 1 && desktop.poster.posted.all.count == 1 })
            try await world.shutdown(laptop, desktop)
        }
    }

    @Test func anEquivalentSubscriptionOnAnotherTopicIsReportedNotAdopted() async throws {
        try await EventWorld.run { world in
            let other = PubSubTopicPath("projects/example-project/topics/gchat-events-9")!
            let foreign = try await world.client().createSubscription(topic: other)
            let mac = Mac(world, conflictOnCreate: true)
            #expect(await mac.start())
            #expect(await world.run { mac.status == .otherTopic })
            #expect(mac.storedSubscription == nil)
            #expect(world.server.eventSubscriptions.map(\.name) == [foreign.name.rawValue])
            #expect(!(await mac.session.liveChannel))
            try await world.shutdown(mac)
        }
    }

    @Test func anAlreadyExistingMatchIsAdopted() async throws {
        try await EventWorld.run { world in
            let existing = try await world.client().createSubscription(topic: EventWorld.topic)
            let mac = Mac(world, conflictOnCreate: true)
            #expect(await mac.startLive())
            #expect(mac.storedSubscription == existing.name.rawValue)
            try await world.shutdown(mac)
        }
    }

    @Test func aWrongSubscriptionPathIsSetupIncompleteUntilFixed() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world, register: false)
            #expect(await mac.start())
            #expect(await world.run { mac.status == .setupIncomplete })
            #expect(mac.pullRequests == 0)
            #expect(world.server.eventSubscriptions.isEmpty)

            world.server.addPullSubscription(mac.path.rawValue, topic: EventWorld.topic.rawValue)
            #expect(await world.run(upTo: .seconds(16 * 60)) { mac.status == .live })
            try await world.shutdown(mac)
        }
    }

    @Test func withoutTheScopeTheChannelAsksForAccessAndSendsNothing() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world, hasScope: false)
            #expect(await mac.start())
            await world.pass(.seconds(10))
            #expect(mac.status == .needsAccess)
            #expect(mac.pullRequests == 0)
            try await world.shutdown(mac)
        }
    }

    @Test func aLostAckIsRedeliveredAndRecordedOnce() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            world.server.fail(.networkError(.networkConnectionLost, route: .acknowledge, times: 1))
            let message = world.post("ack lost")
            #expect(await world.run { mac.unacked == 0 && mac.hasMessage(message) })
            #expect(await world.run { (try? mac.store.owed(world.space)) == nil }, "the redelivery's row resolves too")
            #expect(mac.poster.posted.all.count == 1)
            try await world.shutdown(mac)
        }
    }

    @Test func pullErrorsNeverTouchTheSessionBackoff() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            world.server.fail(.unavailable(route: .pull, times: 4))
            #expect(
                await world.run {
                    if case .degraded(.server) = mac.status { await mac.liveChannelIs(false) } else { false }
                })
            #expect(await mac.session.retryUntil == nil)
            #expect(await mac.session.offlineUntil == nil)
            #expect(await mac.session.status == .ok)
            #expect(!(await mac.session.liveChannel))

            world.server.fail(.networkError(.notConnectedToInternet, route: .pull, times: 1))
            world.server.fail(.rateLimited(route: .pull, retryAfter: 60, times: 1))
            #expect(await world.run(upTo: .seconds(400)) { mac.status == .live })
            #expect(await mac.session.retryUntil == nil)
            #expect(await mac.session.offlineUntil == nil)
            try await world.shutdown(mac)
        }
    }

    @Test func losingTheNetworkStopsPullingAndReconnectingGoesLiveAgain() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            world.server.fail(.rateLimited(route: .listSpaces, retryAfter: 600, times: nil))
            await mac.session.setConnectivity(.unreachable)
            #expect(await world.run { await mac.liveChannelIs(false) && mac.status == .starting })
            #expect(!(await mac.session.liveChannel))
            let pulls = mac.pullRequests
            await world.pass(.seconds(30))
            #expect(mac.pullRequests == pulls)

            await mac.session.setConnectivity(.reachable)
            #expect(await world.run { await mac.session.retryUntil != nil })
            #expect(await world.run { mac.status == .live }, "the channel doesn't wait for a rate-limited catch-up")
            let message = world.post("back online")
            #expect(await world.run { mac.unacked == 0 && (try? mac.store.owed(world.space)) != nil })
            #expect(!mac.hasMessage(message), "the fetch waits for the session's own backoff")
            try await world.shutdown(mac)
        }
    }

    @Test func aWakeRestartsTheChannelOnceItsCatchUpHasRun() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let cycle = await mac.channel.cycle
            let listings = world.requests("GET", "/v1/spaces")
            await mac.session.systemDidWake()
            #expect(await world.run { await mac.channel.cycle > cycle })
            #expect(world.requests("GET", "/v1/spaces") > listings, "the catch-up listed spaces first")
            #expect(await world.run { mac.status == .live })
            try await world.shutdown(mac)
        }
    }

    @Test func pausingStopsPullingAndResumingRestarts() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            await mac.session.setPaused(true)
            #expect(await world.run { mac.status != .live })
            let pulls = mac.pullRequests
            await world.pass(.seconds(30))
            #expect(mac.pullRequests == pulls)
            await mac.session.setPaused(false)
            #expect(await world.run { mac.status == .live })
            try await world.shutdown(mac)
        }
    }
}

@Suite(.serialized) struct EventChannelLogoutTests {
    @Test func oneMacLoggingOutLeavesTheOtherReceiving() async throws {
        try await EventWorld.run { world in
            let laptop = Mac(world, device: "laptop")
            let desktop = Mac(world, device: "desktop")
            #expect(await laptop.startLive())
            #expect(await desktop.startLive())
            try await laptop.shutdown()
            #expect(laptop.status == nil || laptop.status == .off)
            let pulls = laptop.pullRequests

            let message = world.post("after the laptop left")
            #expect(await world.run { desktop.hasMessage(message) })
            #expect(laptop.pullRequests == pulls)
            #expect(world.deletes == 0)
            #expect(world.workspaceSubscription != nil)
            try await world.shutdown(desktop)
        }
    }

    @Test func turningLiveNotificationsOffStopsOnlyThisMacAndDeletesNothing() async throws {
        try await EventWorld.run { world in
            let laptop = Mac(world, device: "laptop")
            let desktop = Mac(world, device: "desktop")
            #expect(await laptop.startLive())
            #expect(await desktop.startLive())
            await laptop.session.configureEvents(EventSettings(subscriptionPath: laptop.path.rawValue, enabled: false))
            #expect(laptop.status == .off)
            #expect(!(await laptop.session.liveChannel))
            let pulls = laptop.pullRequests
            let renewals = world.server.requests.filter { $0.method == "PATCH" }.count

            let message = world.post("only the desktop pulls")
            #expect(await world.run { desktop.hasMessage(message) })
            await world.pass(.seconds(60))
            #expect(laptop.pullRequests == pulls)
            #expect(laptop.unacked == 1, "the laptop's queue keeps the event for when it's turned back on")
            #expect(world.server.requests.filter { $0.method == "PATCH" }.count == renewals)
            #expect(world.deletes == 0)

            await laptop.session.configureEvents(EventSettings(subscriptionPath: laptop.path.rawValue, enabled: true))
            #expect(await world.run { laptop.unacked == 0 && laptop.hasMessage(message) })
            try await world.shutdown(laptop, desktop)
        }
    }

    @Test func aHungCreateCannotCommitAfterLogout() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            mac.createBarrier.arm()
            #expect(await mac.start())
            #expect(await world.run { mac.createBarrier.arrivals == 1 })
            let hung = try #require(await mac.channel.runTask)
            // The create ignores cancellation at its barrier, so logout returns at its drain deadline.
            let report = try await mac.shutdown()
            #expect(!report.drained)
            mac.createBarrier.release()
            await hung.value
            #expect(await mac.channel.subscription == nil)
            #expect(mac.storedSubscription == nil)
            #expect(world.deletes == 0)
        }
    }
}

struct EventSettingsTests {
    static func encoded(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let record = AccountRecord(email: "a@example.com", displayName: "A", me: UserName(unchecked: "users/1"))
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode([record])) as? [[String: Any]])
        #expect(object[0]["events"] == nil)
        edit(&object[0])
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func recordsWithoutEventSettingsStillDecode() throws {
        let records = try JSONDecoder().decode([AccountRecord].self, from: try Self.encoded())
        #expect(records.count == 1)
        #expect(records[0].events == nil)
        #expect(records[0].eventSettings == EventSettings())
        #expect(records[0].eventSettings.path == nil)
    }

    @Test func aGarbagePathDecodesAsUnset() throws {
        let data = try Self.encoded {
            $0["events"] = ["subscriptionPath": "projects/../x", "enabled": "yes", "future": 1] as [String: Any]
        }
        let records = try JSONDecoder().decode([AccountRecord].self, from: data)
        #expect(records[0].events?.subscriptionPath == "projects/../x")
        #expect(records[0].events?.path == nil)
        #expect(records[0].events?.enabled == true)
    }

    @Test func settingsRoundTripThroughTheRegistryInPlace() throws {
        let registry = AccountRegistry(secrets: InMemorySecretStore())
        let first = AccountRecord(email: "a@example.com", displayName: "A", me: UserName(unchecked: "users/1"))
        let second = AccountRecord(email: "b@example.com", displayName: "B", me: UserName(unchecked: "users/2"))
        try registry.upsert(first)
        try registry.upsert(second)
        var updated = first
        updated.events = EventSettings(subscriptionPath: EventWorld.path("mac").rawValue, enabled: false)
        #expect(try registry.update(updated))
        let loaded = try registry.load()
        #expect(loaded.map(\.id) == [first.id, second.id])
        #expect(loaded[0].events == updated.events)
        var unknown = second
        unknown.id = AccountID()
        #expect(try !registry.update(unknown))
    }
}

@Suite(.serialized) struct LogoutQuiesceTests {
    @Test func aWakeDuringLogoutRestartsNothing() async throws {
        try await EventWorld.run { world in
            let mac = Mac(world)
            #expect(await mac.startLive())
            let session = mac.session
            // A health check parked at its barrier ignores cancellation, so logout stays in its drain.
            mac.getBarrier.arm()
            await mac.channel.restart()
            #expect(await world.run { mac.getBarrier.arrivals == 1 })
            let logout = world.sim.start { await session.logout(refreshToken: nil) }
            await world.sim.settle()
            #expect(!logout.isFinished)
            let pulls = mac.pullRequests
            let requests = world.server.requests.count

            await session.systemDidWake()
            await session.setConnectivity(.unreachable)
            await session.setConnectivity(.reachable)
            await world.sim.settle()
            mac.getBarrier.release()
            #expect(await world.run { logout.isFinished })
            #expect(await logout.value.drained)
            await world.pass(.seconds(30))
            #expect(mac.pullRequests == pulls)
            #expect(world.server.requests.count == requests, "the session sent nothing once it was retired")
            #expect(await session.closing)
            #expect(world.sim.sleeperDeadlines.isEmpty, "nothing is left waiting on the clock")
        }
    }
}

struct EventSettingsReplacementTests {
    @Test func turningLiveNotificationsOffDuringAReconnectReachesTheReplacementSession() async throws {
        try await SimWorld.run { sim in
            let server = sim.server
            let alice = server.addAccount(displayName: "Alice")
            let scratch = ScratchDirectory()
            let tombstones = LogoutTombstones(root: scratch.url)
            let runner = LogoutRunner(eraser: NoopEraser(), tombstones: tombstones)
            let hold = sim.barrier()
            let built = Recorder<Int>()
            var timing = SessionTiming.fast
            timing.idleSleep = .seconds(3600)
            let manager = AccountManager(
                registry: AccountRegistry(secrets: InMemorySecretStore()), recovery: LogoutRecovery(runner: runner),
                tombstones: tombstones
            ) { [timing] record in
                built.append(1)
                await hold.pass()
                let client = WorkspaceEventsClient(
                    transport: sim.transport(), tokens: StaticTokens(token: alice.token),
                    sleeper: { _ in })
                let session = AccountSession(
                    account: record.id, me: record.me,
                    api: GoogleChatClient(
                        transport: sim.transport(), tokens: StaticTokens(token: alice.token)),
                    store: InMemoryAccountStore(), clock: sim.clock(), logoutRunner: runner, timing: timing,
                    events: EventServices(events: client, pubsub: client, hasScope: false), executor: sim.executor)
                await session.setPaused(true)
                return session
            }
            let on = EventSettings(subscriptionPath: EventWorld.path("mac-a").rawValue, enabled: true)
            var record = AccountRecord(email: "alice@example.com", displayName: "Alice", me: alice.user.name)
            record.events = on
            let first = try await manager.add(record)
            #expect(await first.eventChannel?.settings == on)

            // The replacement's construction is held while the settings change.
            hold.arm()
            let id = record.id
            let reconnect = sim.start { try? await manager.reconnect(id) {} }
            #expect(await sim.run { built.all.count == 2 && hold.arrivals == 1 })
            var off = on
            off.enabled = false
            try await manager.setEventSettings(id, off)
            hold.release()
            #expect(await sim.run { reconnect.isFinished })
            let replacement = try #require(await reconnect.value)

            #expect(await replacement.eventChannel?.settings == off, "the replacement started with stale settings")
            _ = try await sim.perform { await replacement.logout(refreshToken: nil) }
        }
    }
}
