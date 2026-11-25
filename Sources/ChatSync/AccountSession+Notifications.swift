import ChatModel
import Foundation

extension AccountSession {
    /// Focus suppression only applies while the app is active.
    public func setAppActive(_ active: Bool) {
        appActive = active
        guard !active, let next = nextSidebar else { return }
        let due = clock.now().adding(timing.sidebarInterval(appActive: false, liveChannel: liveChannel))
        if due < next {
            nextSidebar = due
            wake()
        }
    }

    /// `force` runs a pass even without changed spaces, for pending records left by a failure or a restart.
    func scheduleNotifications(_ spaces: Set<SpaceName>, _ generation: Generation, force: Bool = false) {
        guard notifier != nil, !spaces.isEmpty || force else { return }
        notifyPending.formUnion(spaces)
        notifyForced = notifyForced || force
        guard !notifyRunning else { return }
        notifyRunning = true
        let spawned = work.spawn { [weak self] in await self?.drainNotifications(generation) }
        if !spawned { notifyRunning = false }
    }

    func drainNotifications(_ generation: Generation) async {
        var retry = false
        while let notifier, !Task.isCancelled, gate.isCurrent(generation), !notifyPending.isEmpty || notifyForced {
            let batch = notifyPending
            notifyPending = []
            notifyForced = false
            let context = NotifierContext(focusedSpace: focused, appIsActive: appActive)
            let pass = await notifier.process(spaces: batch, generation: generation, context: context)
            notifyPasses &+= 1
            retry = pass.retry
            if pass.more, pass.settled { notifyForced = true }
        }
        notifyRunning = false
        guard gate.isCurrent(generation), !Task.isCancelled else { return }
        if retry {
            armNotificationRetry(generation)
        } else {
            notifyRetryAttempts = 0
        }
    }

    /// One timer at a time, independent of new commits: 30 s, 2 min, then every 10 min.
    func armNotificationRetry(_ generation: Generation) {
        guard !notifyRetryArmed else { return }
        notifyRetryArmed = true
        let delays = Notifier.retryDelays
        let delay = delays[min(notifyRetryAttempts, delays.count - 1)]
        notifyRetryAttempts += 1
        let due = clock.now().adding(delay)
        let spawned = work.spawn { [weak self, clock] in
            await clock.sleep(until: due)
            await self?.notificationRetryFired(generation)
        }
        if !spawned { notifyRetryArmed = false }
    }

    func notificationRetryFired(_ generation: Generation) {
        notifyRetryArmed = false
        guard !Task.isCancelled, gate.isCurrent(generation) else { return }
        scheduleNotifications([], generation, force: true)
    }
}

extension SyncClock {
    /// Sleeps until `deadline` by this clock, however its sleeps relate to its time.
    func sleep(until deadline: Timestamp) async {
        while !Task.isCancelled, now() < deadline {
            let remaining = deadline.interval(since: now())
            do { try await sleep(for: max(remaining, .milliseconds(1))) } catch { return }
        }
    }
}

extension Timestamp {
    func interval(since other: Timestamp) -> Duration {
        .seconds(seconds - other.seconds) + .nanoseconds(Int64(nanos) - Int64(other.nanos))
    }
}
