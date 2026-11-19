import ChatModel
import Foundation

extension AccountSession {
    /// Every path change starts a new epoch. Reaching the network again clears only the offline deadline.
    public func setConnectivity(_ connectivity: Connectivity) {
        connectivityEpoch &+= 1
        let wasOffline = !reachable || offlineUntil != nil
        reachable = connectivity == .reachable
        guard let generation = gate.current else { return }
        guard reachable else {
            admissionWasClosed = true
            if status != .needsLogin { setStatus(.offline, generation) }
            return wake()
        }
        offlineUntil = nil
        offlineFailures = 0
        guard wasOffline else { return }
        if status == .offline {
            if let until = retryUntil, isFuture(until) {
                setStatus(.backingOff(until: until), generation)
            } else {
                setStatus(.ok, generation)
            }
        }
        requestCatchUp()
    }

    /// While offline this only marks the catch-up; it runs once admission reopens.
    public func systemDidWake() {
        requestCatchUp()
    }

    /// True while the event channel delivers new messages, which slows the inactive sidebar cadence.
    public func setLiveChannel(_ live: Bool) {
        liveChannel = live
    }

    /// Called once a catch-up has polled the sidebar and drained the outboxes.
    public func setEventChannelRestart(_ restart: (@Sendable () -> Void)?) {
        restartEventChannel = restart
    }

    func requestCatchUp() {
        catchUpPending = true
        catchUpGeneration &+= 1
        nextSidebar = nil
        nextFocus = nil
        wake()
    }

    /// Runs after a sidebar tick of generation `catchUp` completed with admission open.
    func finishCatchUp(_ catchUp: UInt64, _ generation: Generation) async {
        await drainAllOutboxes(generation)
        guard catchUpGeneration == catchUp, admitted, gate.isCurrent(generation) else { return }
        catchUpPending = false
        restartEventChannel?()
    }

    /// Reruns the work turned away while admission was closed: parked drains, pending retries and read marks.
    func reopenAdmission(_ generation: Generation) {
        admissionWasClosed = false
        let spaces = blockedDrains.union(retryScheduled)
        blockedDrains = []
        for space in spaces {
            work.spawn { [weak self] in await self?.drainOutbox(space, generation) }
        }
        let reads = blockedMarkReads
        blockedMarkReads = [:]
        for (space, time) in reads { markRead(space, upTo: time) }
        if pendingThreadRead != nil {
            work.spawn { [weak self] in await self?.flushThreadRead(generation) }
        }
    }
}
