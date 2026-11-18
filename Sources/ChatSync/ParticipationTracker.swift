import ChatModel
import ChatStore
import Foundation
import Synchronization

/// Threads where I posted or was mentioned, derived from the newest cached messages of a space.
final class ParticipationTracker: Sendable {
    static let scanLimit = 300

    private let store: any AccountStore
    private let me: UserName
    private let cache = Mutex<[SpaceName: Set<ThreadName>]>([:])

    init(store: any AccountStore, me: UserName) {
        self.store = store
        self.me = me
    }

    func threads(in space: SpaceName) throws(StoreError) -> Set<ThreadName> {
        if let cached = cache.withLock({ $0[space] }) { return cached }
        let recent = try store.messages(in: space, before: nil, limit: Self.scanLimit)
        var threads: Set<ThreadName> = []
        for message in recent where !message.isDeleted {
            guard let thread = message.thread else { continue }
            if message.sender.name == me || mentionsMe(message) { threads.insert(thread) }
        }
        cache.withLock { $0[space] = threads }
        return threads
    }

    func invalidate(_ spaces: some Sequence<SpaceName>) {
        cache.withLock { cache in
            for space in spaces { cache.removeValue(forKey: space) }
        }
    }

    private func mentionsMe(_ message: Message) -> Bool {
        message.annotations.contains { annotation in
            if case .userMention(let user) = annotation.kind { user == me } else { false }
        }
    }
}
