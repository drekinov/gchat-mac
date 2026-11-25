import ChatModel
import Foundation

extension AccountSession {
    /// Applies this Mac's live-notification settings; the channel restarts with them.
    public func configureEvents(_ settings: EventSettings) async {
        await eventChannel?.configure(settings)
    }

    /// The blocks that stop the channel: closing, paused, unreachable or signed out. Retry deadlines don't, since
    /// queued events outlive them only briefly.
    var channelBlocked: Bool { standingBlock || gate.current == nil }

    /// Polls the sidebar now, for events the channel couldn't attribute yet.
    func requestSidebarTick() {
        sidebarRequested = true
        nextSidebar = nil
        wake()
    }

    func startEventChannel() {
        guard let channel = eventChannel else { return }
        setEventChannelRestart { Task { await channel.restart() } }
        work.spawn { [weak self] in
            guard let self else { return }
            await channel.attach(self)
            await channel.restart()
        }
    }

    func restartEvents() {
        guard let channel = eventChannel, gate.current != nil else { return }
        work.spawn { await channel.restart() }
    }
}
