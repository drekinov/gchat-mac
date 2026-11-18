import ChatModel
import ChatStore
import Foundation
import Synchronization

/// Content-bearing: it holds message text, so it never goes to logs.
public struct ChatNotification: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var account: AccountID
    public var space: SpaceName
    public var thread: ThreadName?
    /// `nil` for a summary.
    public var message: MessageName?
    public var title: String
    /// At most `Notifier.bodyLimit` characters.
    public var body: String
    public var threadIdentifier: String
    public var identifier: String

    public var description: String { "ChatNotification(<redacted>)" }
    public var debugDescription: String { description }
}

public protocol NotificationPoster: Sendable {
    func post(_ request: ChatNotification) async
    func remove(account: AccountID) async
    func remove(messages: [MessageName]) async
}

struct NotifierContext: Sendable, Equatable {
    var focusedSpace: SpaceName?
    var appIsActive: Bool
}

/// Turns newly stored messages into notifications. Marks are committed through the gate before anything is posted.
final class Notifier: Sendable {
    static let maxPerPass = 5
    static let scanLimit = 100
    static let bodyLimit = 200

    let account: AccountID
    let store: any AccountStore
    let gate: SessionGate
    let me: UserName
    let poster: any NotificationPoster
    let clock: any SyncClock
    let participation: ParticipationTracker
    private let removed = Mutex(Set<MessageName>())

    init(
        account: AccountID, store: any AccountStore, gate: SessionGate, me: UserName,
        poster: any NotificationPoster, clock: any SyncClock
    ) {
        self.account = account
        self.store = store
        self.gate = gate
        self.me = me
        self.poster = poster
        self.clock = clock
        participation = ParticipationTracker(store: store, me: me)
    }

    static func markKey(_ space: SpaceName) -> String { "notifyMark|\(space.rawValue)" }

    private struct Candidate {
        var message: Message
        var stored: StoredSpace
    }

    func process(spaces: Set<SpaceName>, generation: Generation, context: NotifierContext) async {
        guard gate.isCurrent(generation), !spaces.isEmpty else { return }
        guard let firstSync = try? store.meta("firstSyncCompleted").flatMap({ Timestamp(rfc3339: $0) }) else {
            return
        }
        participation.invalidate(spaces)
        let now = clock.now()

        var candidates: [Candidate] = []
        var marks: [SpaceName: Timestamp] = [:]
        var deleted: [MessageName] = []
        for name in spaces.sorted() {
            guard let stored = try? store.space(name), !stored.isHidden else { continue }
            let storedMark: String?
            do { storedMark = try store.meta(Self.markKey(name)) } catch { continue }
            let storedTime = storedMark.flatMap { Timestamp(rfc3339: $0) }
            let mark = storedTime ?? firstSync
            guard let recent = try? store.messages(in: name, before: nil, limit: Self.scanLimit) else { continue }
            if let newest = recent.last?.createTime, newest > mark {
                marks[name] = newest
            } else if storedTime == nil {
                marks[name] = mark
            }
            deleted += recent.filter(\.isDeleted).map(\.name)

            let fresh = recent.filter { $0.createTime > mark }
            var policy = PolicyContext(
                me: me, focusedSpace: context.focusedSpace, appIsActive: context.appIsActive,
                firstSyncCompleted: firstSync)
            if NotificationPolicy.effectiveLevel(for: stored) == .mainConversations,
                fresh.contains(where: \.isThreadReply)
            {
                policy.participatingThreads = (try? participation.threads(in: name)) ?? []
            }
            for message in fresh where NotificationPolicy.shouldNotify(message, in: stored, context: policy) {
                guard let notified = try? store.isNotified(message.name), !notified else { continue }
                candidates.append(Candidate(message: message, stored: stored))
            }
        }
        candidates.sort { ($0.message.createTime, $0.message.name) < ($1.message.createTime, $1.message.name) }

        if !candidates.isEmpty || !marks.isEmpty {
            let names = candidates.map(\.message.name)
            do {
                try store.write(gate: gate, generation: generation) { batch in
                    if !names.isEmpty { batch.append(.markNotified(names, at: now)) }
                    for (space, time) in marks.sorted(by: { $0.key < $1.key }) {
                        batch.append(.setMeta(key: Self.markKey(space), value: time.rfc3339))
                    }
                }
            } catch {
                return
            }
        }

        for request in requests(for: candidates) {
            guard gate.isCurrent(generation), !Task.isCancelled else { return }
            await poster.post(request)
        }

        let gone = removable(deleted)
        if !gone.isEmpty, gate.isCurrent(generation), !Task.isCancelled {
            await poster.remove(messages: gone)
        }
    }

    func removeAll() async {
        await poster.remove(account: account)
    }

    private func removable(_ deleted: [MessageName]) -> [MessageName] {
        let fresh = removed.withLock { removed in deleted.filter { !removed.contains($0) } }
        let notified = fresh.filter { (try? store.isNotified($0)) == true }
        removed.withLock { $0.formUnion(fresh) }
        return notified
    }

    private func requests(for candidates: [Candidate]) -> [ChatNotification] {
        guard candidates.count > Self.maxPerPass else { return candidates.map(single) }
        let grouped = Dictionary(grouping: candidates, by: \.stored.space.name)
        let summaries = grouped.values.map { group -> (newest: Timestamp, request: ChatNotification) in
            let newest = group.map(\.message.createTime).max() ?? group[0].message.createTime
            return (newest, summary(group, newest: newest))
        }
        return summaries.sorted { ($0.newest, $0.request.space) > ($1.newest, $1.request.space) }
            .prefix(Self.maxPerPass).map(\.request)
    }

    private func single(_ candidate: Candidate) -> ChatNotification {
        let message = candidate.message
        let title = SyncEngine.title(of: candidate.stored)
        let text = Self.preview(of: message)
        let sender = message.sender.displayName ?? "Someone"
        let body = candidate.stored.space.type == .directMessage ? text : "\(sender): \(text)"
        let thread = message.isThreadReply ? message.thread : nil
        return ChatNotification(
            account: account, space: message.space, thread: message.thread, message: message.name, title: title,
            body: String(body.prefix(Self.bodyLimit)), threadIdentifier: (thread?.rawValue ?? message.space.rawValue),
            identifier: message.name.rawValue)
    }

    private func summary(_ group: [Candidate], newest: Timestamp) -> ChatNotification {
        let stored = group[0].stored
        let title = SyncEngine.title(of: stored)
        let space = stored.space.name
        return ChatNotification(
            account: account, space: space, thread: nil, message: nil, title: title,
            body: String(
                "\(group.count) new \(group.count == 1 ? "message" : "messages") in \(title)".prefix(Self.bodyLimit)),
            threadIdentifier: space.rawValue, identifier: "summary|\(space.rawValue)|\(newest.rfc3339)")
    }

    private static func preview(of message: Message) -> String {
        message.contentPreview ?? "New message"
    }
}

extension Message {
    /// Text for notifications and the sidebar: the text, else card text, else an attachment note.
    public var contentPreview: String? {
        if !text.isEmpty { return text }
        if let fallback = cardsFallbackText, !fallback.isEmpty { return fallback }
        if let summary = cards?.lazy.compactMap(\.summary).first { return summary }
        if !attachments.isEmpty || !gifURLs.isEmpty { return "Sent an attachment" }
        return nil
    }
}
