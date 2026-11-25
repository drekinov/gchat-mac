import ChatModel
import ChatStore
import Foundation
import GoogleChat

extension AccountSession {
    /// The longest an owed sync waits after the first request.
    static let owedDebounceCap = Duration.seconds(5)
    static let owedDebounceSlack = Duration.milliseconds(500)
    /// Owed rows of spaces the listing doesn't know, probed with `messages.get` per sidebar tick.
    static let unknownOwedProbes = 2

    /// Commits owed rows and relist requests for `events`; returns after the commit, so every delivery may be acked
    /// except those whose messages are in `rejected`.
    public func recordEvents(_ events: [ChatEvent]) async throws(SyncError) -> SyncEngine.RecordedEvents {
        guard let generation = gate.current else { throw .retired }
        let recorded = try engine.recordEvents(events, generation)
        if recorded.relistRequested {
            sidebarRequested = true
            nextSidebar = nil
            wake()
        }
        return recorded
    }

    /// Syncs due owed rows through the scheduler: single-flight, admitted work only, debounced until the newest
    /// boundary plus skew and 0.5 s, but at most 5 s after the first request.
    public func requestOwedSync() {
        guard let generation = gate.current else { return }
        if owedFirstRequest == nil { owedFirstRequest = clock.now() }
        owedSyncWanted = true
        guard !owedSyncArmed else { return }
        owedSyncArmed = true
        let spawned = work.spawn { [weak self] in await self?.runOwedSync(generation) }
        if !spawned { owedSyncArmed = false }
    }

    func runOwedSync(_ generation: Generation) async {
        defer { owedSyncArmed = false }
        while owedSyncWanted, gate.isCurrent(generation), !Task.isCancelled {
            let cap = (owedFirstRequest ?? clock.now()).adding(Self.owedDebounceCap)
            var target = owedSettleTime(cap: cap)
            while !Task.isCancelled, clock.now() < target {
                await clock.sleep(until: target)
                target = owedSettleTime(cap: cap)
            }
            owedSyncWanted = false
            owedFirstRequest = nil
            guard admitted, gate.isCurrent(generation), !Task.isCancelled else { return }
            let plan = owedPlan(limit: timing.spacesPerTick)
            if !plan.unknown.isEmpty {
                sidebarRequested = true
                nextSidebar = nil
                wake()
            }
            guard !plan.due.isEmpty else { continue }
            await syncSpaces(plan.due, generation)
            publish(generation)
        }
    }

    /// The newest owed boundary plus skew and slack, no later than `cap`.
    func owedSettleTime(cap: Timestamp) -> Timestamp {
        let newest = ((try? engine.owedRecords()) ?? [:]).values.map(\.boundary).max()
        return min(newest.map { $0.adding(SyncEngine.skew + Self.owedDebounceSlack) } ?? clock.now(), cap)
    }

    struct OwedPlan {
        /// Visible spaces with a due row, oldest boundary first.
        var due: [SpaceName]
        /// Due rows of spaces the store doesn't show.
        var unknown: [SpaceName]
    }

    func owedPlan(limit: Int) -> OwedPlan {
        let records = (try? engine.owedRecords()) ?? [:]
        guard !records.isEmpty else { return OwedPlan(due: [], unknown: []) }
        let visible = Set(((try? store.spaces()) ?? []).filter { !$0.isHidden }.map(\.space.name))
        let now = clock.now()
        let due = records.filter { $0.value.isDue(at: now) }.sorted {
            ($0.value.boundary, $0.key) < ($1.value.boundary, $1.key)
        }
        return OwedPlan(
            due: Array(due.filter { visible.contains($0.key) }.map(\.key).prefix(max(0, limit))),
            unknown: due.filter { !visible.contains($0.key) }.map(\.key))
    }

    /// Owed rows of spaces no listing returns: IDs resolve on 404, or on 403 once a complete listing omitted them.
    func probeUnknownOwed(_ spaces: [SpaceName], _ generation: Generation) async {
        for space in spaces.prefix(Self.unknownOwedProbes) where admitted {
            guard let record = try? store.owed(space), record.hasMessages, record.omitted > 0 else { continue }
            let epoch = connectivityEpoch
            do throws(SyncError) {
                try await engine.probeOwed(space, revision: record.revision, generation)
            } catch {
                handle(error, generation, epoch: epoch)
            }
            if (try? store.owed(space))?.revision == record.revision {
                try? engine.deferOwed(space, revision: record.revision, generation)
            }
        }
    }

    /// Listing-derived owed rows given up on.
    public nonisolated func droppedOwedCount() -> Int { (try? store.droppedOwedCount()) ?? 0 }
}

extension SyncError {
    /// Whether a failed space sync spends one of its owed row's attempts.
    var countsAsOwedAttempt: Bool {
        switch self {
        case .api, .incompletePage: true
        case .busy, .retired, .store: false
        }
    }
}
