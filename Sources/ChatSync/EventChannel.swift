import ChatModel
import ChatStore
import Foundation
import GoogleChat

/// Live notifications for one account on this Mac, kept in the account registry.
public struct EventSettings: Hashable, Sendable, Codable {
    /// As entered in Settings; checked when the channel starts.
    public var subscriptionPath: String?
    /// Local to this Mac: off stops pulling and renewing, and never deletes anything.
    public var enabled: Bool

    public init(subscriptionPath: String? = nil, enabled: Bool = true) {
        self.subscriptionPath = subscriptionPath
        self.enabled = enabled
    }

    public var path: PubSubSubscriptionPath? { subscriptionPath.flatMap { PubSubSubscriptionPath($0) } }

    private enum CodingKeys: String, CodingKey { case subscriptionPath, enabled }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptionPath = try? container.decodeIfPresent(String.self, forKey: .subscriptionPath)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }
}

public enum EventChannelStatus: Sendable, Equatable {
    /// No subscription path, or turned off on this Mac.
    case off
    /// The path is set but the account hasn't granted the Pub/Sub scope.
    case needsAccess
    /// Running, but not yet (or no longer) delivering; polling carries the load.
    case starting
    case live
    /// The pull subscription is missing, malformed or not readable by this account.
    case setupIncomplete
    /// The account's Workspace subscription publishes to a different topic.
    case otherTopic
    case degraded(Reason)

    public enum Reason: String, Sendable, Equatable {
        case network, rateLimited, server, permission, subscription
    }
}

/// The Pub/Sub and Workspace Events clients for one account.
public struct EventServices: Sendable {
    public var events: any WorkspaceEventsAPI
    public var pubsub: any PubSubAPI
    public var hasScope: Bool

    public init(events: any WorkspaceEventsAPI, pubsub: any PubSubAPI, hasScope: Bool) {
        self.events = events
        self.pubsub = pubsub
        self.hasScope = hasScope
    }
}

/// Pulls Workspace Events from this Mac's Pub/Sub subscription and keeps the account's shared Workspace
/// subscription alive. Failures here back off on their own and never touch the session's backoff.
public actor EventChannel {
    public static let subscriptionKey = "eventsSubscription"
    public static let expiryKey = "eventsSubscriptionExpiry"
    static let pullBatch = 50
    static let heldPull = Duration.seconds(5)
    static let emptyFloor = Duration.seconds(2)
    static let busyFloor = Duration.seconds(1)
    static let maxBackoff = Duration.seconds(300)
    static let degradedAfter = 3
    static let healthInterval = Duration.seconds(15 * 60)
    static let renewWithin = Duration.seconds(24 * 3600)
    static let livePullWindow = Duration.seconds(120)
    static let liveHealthWindow = Duration.seconds(45 * 60)
    static let reactivateDelays = [Duration.seconds(30 * 60), .seconds(3600)]
    static let verifyDelays = [Duration.seconds(30), .seconds(120), .seconds(600)]

    enum Phase: Equatable { case off, needsAccess, running, setupIncomplete, otherTopic }

    enum Verdict {
        case match, mismatch
        case inconclusive(fresh: Bool)
    }

    struct OtherTopic: Error {}

    public nonisolated let status = LatestValue<EventChannelStatus>()
    let services: EventServices
    let store: any AccountStore
    let gate: SessionGate
    let clock: any SyncClock
    let me: UserName
    weak var session: AccountSession?

    var settings = EventSettings(enabled: false)
    var phase = Phase.off
    var cycle: UInt64 = 0
    var runTask: Task<Void, Never>?
    var parked = false
    var topic: PubSubTopicPath?
    var subscription: EventSubscriptionName?
    var expiry: Timestamp?
    var loadedStored = false
    /// Verified publishers other than the stored one, e.g. the one it replaced.
    var accepted: Set<EventSubscriptionName> = []
    var foreign: Set<EventSubscriptionName> = []
    var verifyRetry: [EventSubscriptionName: (attempts: Int, at: Timestamp)] = [:]
    var failures = 0
    var pullDegraded: EventChannelStatus.Reason?
    var healthFailures = 0
    var healthDegraded: EventChannelStatus.Reason?
    var nextHealth: Timestamp?
    var lastPull: Timestamp?
    var lastHealthy: Timestamp?
    var reactivateAttempts = 0
    var nextReactivate: Timestamp?
    var reportedLive = false

    init(services: EventServices, store: any AccountStore, gate: SessionGate, clock: any SyncClock, me: UserName) {
        self.services = services
        self.store = store
        self.gate = gate
        self.clock = clock
        self.me = me
        status.send(.off)
    }

    func attach(_ session: AccountSession) {
        self.session = session
    }

    /// Applies new settings and restarts; a changed path forgets the old topic and verified publishers.
    func configure(_ settings: EventSettings) async {
        if settings.path != self.settings.path {
            topic = nil
            accepted = []
            foreign = []
            verifyRetry = [:]
        }
        self.settings = settings
        await restart()
    }

    /// Cancels any running cycle, including an in-flight pull, and starts a fresh one with a health check.
    func restart() async {
        runTask?.cancel()
        runTask = nil
        cycle &+= 1
        parked = false
        failures = 0
        pullDegraded = nil
        nextHealth = nil
        guard settings.enabled, let path = settings.path else {
            phase = .off
            return await publishStatus()
        }
        guard services.hasScope else {
            phase = .needsAccess
            return await publishStatus()
        }
        guard let session, let generation = gate.current else {
            phase = .off
            return await publishStatus()
        }
        phase = .running
        let current = cycle
        runTask = session.work.task { [weak self] in await self?.run(current, path, generation) }
        if runTask == nil { phase = .off }
        await publishStatus()
    }

    /// Stops for good: the session is closing.
    func shutdown() async {
        runTask?.cancel()
        runTask = nil
        cycle &+= 1
        phase = .off
        await publishStatus()
        status.finish()
    }

    // MARK: Status

    var isLive: Bool {
        guard phase == .running, !parked, pullDegraded == nil, healthDegraded == nil, let lastPull, let lastHealthy
        else { return false }
        let now = clock.now()
        return now.interval(since: lastPull) <= Self.livePullWindow
            && now.interval(since: lastHealthy) <= Self.liveHealthWindow
    }

    var currentStatus: EventChannelStatus {
        switch phase {
        case .off: .off
        case .needsAccess: .needsAccess
        case .setupIncomplete: .setupIncomplete
        case .otherTopic: .otherTopic
        case .running:
            if let reason = pullDegraded ?? healthDegraded { .degraded(reason) } else { isLive ? .live : .starting }
        }
    }

    func publishStatus() async {
        let next = currentStatus
        if status.current != next { status.send(next) }
        let live = next == .live
        guard live != reportedLive else { return }
        reportedLive = live
        await session?.setLiveChannel(live)
    }

    // MARK: Loop

    func isCurrent(_ cycle: UInt64, _ generation: Generation) -> Bool {
        self.cycle == cycle && gate.isCurrent(generation) && !Task.isCancelled
    }

    func run(_ cycle: UInt64, _ path: PubSubSubscriptionPath, _ generation: Generation) async {
        loadStored()
        while isCurrent(cycle, generation) {
            await publishStatus()
            guard let session, !(await session.channelBlocked) else {
                parked = true
                return await publishStatus()
            }
            do {
                if topic == nil || nextHealth.map({ $0 <= clock.now() }) ?? true {
                    let usable = try await repair(path, cycle, generation)
                    guard isCurrent(cycle, generation) else { return }
                    guard usable else {
                        await publishStatus()
                        await clock.sleep(until: nextHealth ?? clock.now().adding(Self.healthInterval))
                        continue
                    }
                }
                let started = clock.now()
                let received = try await services.pubsub.pull(path, maxMessages: Self.pullBatch)
                guard isCurrent(cycle, generation) else { return }
                let held = clock.now().interval(since: started)
                lastPull = clock.now()
                failures = 0
                pullDegraded = nil
                try await process(received, path, cycle, generation)
                guard isCurrent(cycle, generation) else { return }
                await publishStatus()
                if !received.isEmpty {
                    try? await clock.sleep(for: Self.busyFloor)
                } else if held < Self.heldPull {
                    try? await clock.sleep(for: Self.emptyFloor)
                }
            } catch {
                guard isCurrent(cycle, generation) else { return }
                if let apiError = error as? ChatAPIError, apiError == .unauthorized || apiError == .noCredentials {
                    parked = true
                    return await publishStatus()
                }
                failures += 1
                if failures >= Self.degradedAfter { pullDegraded = Self.reason(for: error) }
                await publishStatus()
                try? await clock.sleep(for: Self.backoff(failures))
            }
        }
    }

    static func backoff(_ failures: Int) -> Duration {
        min(.seconds(1 << min(max(failures, 1), 9)), maxBackoff)
    }

    static func reason(for error: any Error) -> EventChannelStatus.Reason {
        var apiError = error as? ChatAPIError
        if case .api(let wrapped, _)? = error as? SyncError { apiError = wrapped }
        switch apiError {
        case .rateLimited?: return .rateLimited
        case .permissionDenied?: return .permission
        case .transport?: return .network
        default: return .server
        }
    }

    func loadStored() {
        guard !loadedStored else { return }
        loadedStored = true
        subscription = (try? store.meta(Self.subscriptionKey)).flatMap { $0.flatMap { EventSubscriptionName($0) } }
        expiry = (try? store.meta(Self.expiryKey)).flatMap { $0.flatMap { Timestamp(rfc3339: $0) } }
    }

    /// Writes only through the cycle's generation, so a straggler after logout can't put anything back.
    func remember(_ found: EventSubscription, _ generation: Generation) {
        if let old = subscription, old != found.name { accepted.insert(old) }
        accepted.remove(found.name)
        subscription = found.name
        if let expireTime = found.expireTime { expiry = expireTime }
        let expiry = expiry
        _ = try? store.write(gate: gate, generation: generation) { batch in
            batch.append(.setMeta(key: Self.subscriptionKey, value: found.name.rawValue))
            if let expiry { batch.append(.setMeta(key: Self.expiryKey, value: expiry.rfc3339)) }
        }
    }

    func matches(_ candidate: EventSubscription, topic: PubSubTopicPath) -> Bool {
        candidate.targetResource == EventSubscription.chatTarget
            && Set(candidate.eventTypes) == Set(EventSubscription.requiredEventTypes)
            && candidate.pubsubTopic == topic.rawValue && candidate.authority == me.rawValue
    }

    // MARK: Health and repair

    /// Reads the pull subscription's topic, then checks and repairs the Workspace subscription. Returns false when
    /// the channel can't run (setup incomplete or another topic); it retries at the next health time.
    func repair(_ path: PubSubSubscriptionPath, _ cycle: UInt64, _ generation: Generation) async throws -> Bool {
        let found: PubSubSubscription
        do throws(ChatAPIError) {
            found = try await services.pubsub.getSubscription(path)
        } catch {
            switch error {
            case .permissionDenied, .notFound, .invalidArgument, .decoding, .failedPrecondition:
                phase = .setupIncomplete
                topic = nil
                nextHealth = clock.now().adding(Self.healthInterval)
                return false
            default:
                throw error
            }
        }
        guard isCurrent(cycle, generation) else { return false }
        if topic != found.topic {
            accepted = []
            foreign = []
        }
        topic = found.topic
        phase = .running
        do {
            try await checkSubscription(found.topic, cycle, generation)
        } catch is OtherTopic {
            phase = .otherTopic
            nextHealth = clock.now().adding(Self.healthInterval)
            return false
        } catch let error as ChatAPIError {
            if error == .unauthorized || error == .noCredentials { throw error }
            healthFailures += 1
            if healthFailures >= Self.degradedAfter { healthDegraded = Self.reason(for: error) }
            let retry = min(Duration.seconds(60) * (1 << min(healthFailures - 1, 4)), Self.healthInterval)
            nextHealth = clock.now().adding(retry)
        }
        return true
    }

    func checkSubscription(_ topic: PubSubTopicPath, _ cycle: UInt64, _ generation: Generation) async throws {
        var current: EventSubscription?
        if let name = subscription {
            do throws(ChatAPIError) {
                current = try await services.events.getSubscription(name)
            } catch .notFound {
                current = nil
            }
            guard isCurrent(cycle, generation) else { return }
            if let found = current {
                if matches(found, topic: topic) { remember(found, generation) } else { current = nil }
            }
        }
        if current == nil || current?.state == .deleted {
            current = try await create(topic, generation)
            guard isCurrent(cycle, generation) else { return }
        }
        guard var found = current else { return }
        if found.state == .suspended {
            if nextReactivate.map({ $0 <= clock.now() }) ?? true {
                do throws(ChatAPIError) {
                    found = try await services.events.reactivateSubscription(found.name)
                    guard isCurrent(cycle, generation) else { return }
                    remember(found, generation)
                    reactivateAttempts = 0
                    nextReactivate = nil
                } catch {
                    if error == .unauthorized || error == .noCredentials { throw error }
                    let delays = Self.reactivateDelays
                    nextReactivate = clock.now().adding(delays[min(reactivateAttempts, delays.count - 1)])
                    reactivateAttempts += 1
                }
            }
        }
        if found.state == .active, let expireTime = found.expireTime ?? expiry,
            expireTime.interval(since: clock.now()) < Self.renewWithin
        {
            found = try await services.events.renewSubscription(found.name)
            guard isCurrent(cycle, generation) else { return }
            remember(found, generation)
        }
        let now = clock.now()
        if found.state == .active {
            lastHealthy = now
            healthFailures = 0
            healthDegraded = nil
            nextHealth = now.adding(Self.healthInterval)
        } else {
            healthDegraded = .subscription
            let regular = now.adding(Self.healthInterval)
            nextHealth = min(regular, nextReactivate ?? regular)
        }
    }

    /// Creates the shared subscription, or adopts the equivalent one another Mac created.
    func create(_ topic: PubSubTopicPath, _ generation: Generation) async throws -> EventSubscription {
        do throws(ChatAPIError) {
            let created = try await services.events.createSubscription(topic: topic)
            remember(created, generation)
            return created
        } catch  where error.isAlreadyExists {
            let listed = try await services.events.listSubscriptions(filter: .chat)
            if let match = listed.first(where: { matches($0, topic: topic) && $0.state != .deleted }) {
                remember(match, generation)
                return match
            }
            if listed.contains(where: {
                $0.targetResource == EventSubscription.chatTarget && $0.authority == me.rawValue
                    && !Set($0.eventTypes).isDisjoint(with: EventSubscription.requiredEventTypes)
                    && $0.pubsubTopic != topic.rawValue
            }) {
                throw OtherTopic()
            }
            throw error
        }
    }

    // MARK: Deliveries

    func process(
        _ received: [ReceivedEvent], _ path: PubSubSubscriptionPath, _ cycle: UInt64, _ generation: Generation
    ) async throws {
        guard !received.isEmpty, let session else { return }
        var acks: [String] = []
        var deliveries: [(ackID: String, events: [ChatEvent])] = []
        var lifecycle: [ChatEvent] = []
        var verdicts: [EventSubscriptionName: Verdict] = [:]
        var askForPoll = false
        for event in received {
            guard let source = event.subscription else {
                acks.append(event.ackID)
                continue
            }
            if source != subscription, !accepted.contains(source) {
                let verdict: Verdict
                if let known = verdicts[source] {
                    verdict = known
                } else {
                    verdict = await verify(source, generation)
                    verdicts[source] = verdict
                    guard isCurrent(cycle, generation) else { return }
                }
                switch verdict {
                case .match:
                    break
                case .mismatch:
                    acks.append(event.ackID)
                    continue
                case .inconclusive(let fresh):
                    askForPoll = askForPoll || fresh
                    continue
                }
            }
            var record: [ChatEvent] = []
            for chatEvent in event.chatEvents {
                switch chatEvent {
                case .messagesCreated, .membershipCreated:
                    record.append(chatEvent)
                case .expirationReminder(let name, _), .suspended(let name), .expired(let name):
                    if name == subscription { lifecycle.append(chatEvent) }
                case .unknown:
                    break
                }
            }
            if record.isEmpty { acks.append(event.ackID) } else { deliveries.append((event.ackID, record)) }
        }
        if askForPoll { await session.requestSidebarTick() }
        var hasMessages = false
        if !deliveries.isEmpty {
            let recorded = try await session.recordEvents(deliveries.flatMap(\.events))
            guard isCurrent(cycle, generation) else { return }
            let rejected = Set(recorded.rejected)
            for delivery in deliveries {
                let refused = delivery.events.contains { event in
                    guard case .messagesCreated(_, let messages, _) = event else { return false }
                    return messages.contains(where: rejected.contains)
                }
                if !refused { acks.append(delivery.ackID) }
                if delivery.events.contains(where: { if case .messagesCreated = $0 { true } else { false } }) {
                    hasMessages = true
                }
            }
        }
        var ackError: (any Error)?
        if !acks.isEmpty {
            do { try await services.pubsub.acknowledge(path, ackIDs: acks) } catch { ackError = error }
        }
        if hasMessages { await session.requestOwedSync() }
        if let ackError { throw ackError }
        guard isCurrent(cycle, generation) else { return }
        for event in lifecycle { await handleLifecycle(event, cycle, generation) }
    }

    /// Checks an unfamiliar publisher before anything from it is acked. Transient failures back off per source.
    func verify(_ source: EventSubscriptionName, _ generation: Generation) async -> Verdict {
        if foreign.contains(source) { return .mismatch }
        guard let topic else { return .inconclusive(fresh: false) }
        let now = clock.now()
        if let retry = verifyRetry[source], retry.at > now { return .inconclusive(fresh: false) }
        do throws(ChatAPIError) {
            let found = try await services.events.getSubscription(source)
            verifyRetry[source] = nil
            guard matches(found, topic: topic) else {
                foreign.insert(source)
                return .mismatch
            }
            if gate.isCurrent(generation) { remember(found, generation) }
            return .match
        } catch {
            switch error {
            case .notFound, .permissionDenied, .invalidArgument:
                verifyRetry[source] = nil
                foreign.insert(source)
                return .mismatch
            default:
                let attempts = (verifyRetry[source]?.attempts ?? 0) + 1
                let delays = Self.verifyDelays
                verifyRetry[source] = (attempts, now.adding(delays[min(attempts - 1, delays.count - 1)]))
                return .inconclusive(fresh: true)
            }
        }
    }

    func handleLifecycle(_ event: ChatEvent, _ cycle: UInt64, _ generation: Generation) async {
        switch event {
        case .expirationReminder(let name, _):
            do {
                let renewed = try await services.events.renewSubscription(name)
                guard isCurrent(cycle, generation) else { return }
                remember(renewed, generation)
                lastHealthy = clock.now()
            } catch {
                nextHealth = clock.now()
            }
        case .suspended:
            nextReactivate = nil
            lastHealthy = nil
            nextHealth = clock.now()
        case .expired:
            if let old = subscription { accepted.insert(old) }
            subscription = nil
            lastHealthy = nil
            nextHealth = clock.now()
        default:
            break
        }
    }
}
