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

    func scheduleNotifications(_ spaces: Set<SpaceName>, _ generation: Generation) {
        guard notifier != nil, !spaces.isEmpty else { return }
        notifyPending.formUnion(spaces)
        guard !notifyRunning else { return }
        notifyRunning = true
        let spawned = work.spawn { [weak self] in await self?.drainNotifications(generation) }
        if !spawned { notifyRunning = false }
    }

    func drainNotifications(_ generation: Generation) async {
        while let notifier, !Task.isCancelled, gate.isCurrent(generation), !notifyPending.isEmpty {
            let batch = notifyPending
            notifyPending = []
            let context = NotifierContext(focusedSpace: focused, appIsActive: appActive)
            await notifier.process(spaces: batch, generation: generation, context: context)
        }
        notifyRunning = false
    }
}
