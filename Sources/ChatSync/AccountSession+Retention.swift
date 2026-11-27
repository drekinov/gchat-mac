import ChatModel
import ChatStore
import Foundation

extension AccountSession {
    /// Arms the expiry timer for the earliest `HistoryRetention.due` and starts any cleanup the store has queued.
    /// Neither depends on admission: Google deletes these messages whether or not the app can reach it.
    func scheduleRetention(_ generation: Generation) {
        let records = (try? store.retentionRecords()) ?? [:]
        let due = records.values.compactMap(\.due).min()
        if due != expiryDue || (due != nil && expiryTimer == nil) {
            expiryTimer?.cancel()
            expiryTimer = nil
            expiryDue = due
            if let due {
                // A message created exactly a lifetime ago is due, not yet past; one second later it is.
                let at = max(due, clock.now()).adding(.seconds(1))
                expiryTimer = work.task { [weak self, clock] in
                    await clock.sleep(until: at)
                    guard !Task.isCancelled else { return }
                    await self?.expiryFired(due, generation)
                }
            }
        }
        if !cleaningExpired, (try? store.expiredCleanup()) != nil {
            cleaningExpired = true
            let spawned = work.spawn { [weak self] in await self?.cleanUpExpired(generation) }
            if !spawned { cleaningExpired = false }
        }
    }

    func expiryFired(_ due: Timestamp, _ generation: Generation) {
        guard expiryDue == due, gate.isCurrent(generation) else { return }
        expiryTimer = nil
        expiryDue = nil
        let now = clock.now()
        let records = (try? store.retentionRecords()) ?? [:]
        let spaces = records.filter { $0.value.due.map { $0 <= now } ?? false }.keys.sorted()
        if !spaces.isEmpty {
            _ = try? store.write(gate: gate, generation: generation) { $0.append(.expireHistoryOff(spaces)) }
            changedSinceSnapshot.formUnion(spaces)
        }
        publish(generation)
    }

    /// Removes delivered notifications and media copies of expired messages, then clears what was done. Media that
    /// couldn't be removed stays queued for the next publish.
    func cleanUpExpired(_ generation: Generation) async {
        defer { cleaningExpired = false }
        guard gate.isCurrent(generation), let pending = try? store.expiredCleanup(), !pending.isEmpty else { return }
        if !pending.messages.isEmpty { await notifier?.removeExpired(pending.messages) }
        var done = ExpiredCleanup(messages: pending.messages)
        if await mediaLoader?.forget(pending.media) ?? true { done.media = pending.media }
        guard gate.isCurrent(generation) else { return }
        _ = try? store.write(gate: gate, generation: generation) { $0.append(.clearExpiredCleanup(done)) }
    }
}
