import ChatModel
import ChatStore
import Foundation

/// Threads where I posted or was mentioned, derived from the newest cached messages of a space.
enum ParticipationTracker {
    static let scanLimit = 300

    /// `including` adds messages not stored yet, e.g. the batch being committed.
    static func threads(
        in space: SpaceName, store: any AccountStore, me: UserName, including extra: [Message] = []
    ) throws(StoreError) -> Set<ThreadName> {
        let recent = try store.messages(in: space, before: nil, limit: scanLimit)
        var threads: Set<ThreadName> = []
        for message in recent + extra where !message.isDeleted && message.space == space {
            guard let thread = message.thread else { continue }
            if message.sender.name == me || mentions(message, me) { threads.insert(thread) }
        }
        return threads
    }

    private static func mentions(_ message: Message, _ me: UserName) -> Bool {
        message.annotations.contains { annotation in
            if case .userMention(let user) = annotation.kind { user == me } else { false }
        }
    }
}
