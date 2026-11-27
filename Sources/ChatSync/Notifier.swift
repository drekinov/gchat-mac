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

public enum PostOutcome: Sendable, Equatable {
    case accepted
    /// Not shown on purpose (disabled, not authorized); never retried.
    case suppressed
    /// Holds a content-free error class for logs.
    case retryable(String)
}

public protocol NotificationPoster: Sendable {
    func post(_ request: ChatNotification) async -> PostOutcome
    func remove(account: AccountID) async
    func remove(messages: [MessageName]) async
}

struct NotifierContext: Sendable, Equatable {
    var focusedSpace: SpaceName?
    var appIsActive: Bool
}

/// Test seam: what one `Notifier.process` call found pending, removed from the records, and tried to post.
struct NotifyPassTrace: Sendable, Equatable {
    var pending: [SpaceName: [MessageName]] = [:]
    var settled: [SpaceName: [MessageName]] = [:]
    /// Identifiers in attempt order: a message's name, or a summary's own identifier.
    var attempted: [String] = []
}

struct NotifyPass: Sendable, Equatable {
    /// A post failed and stays pending.
    var retry = false
    /// The post cap stopped the pass before every pending record was handled.
    var more = false
    /// Some pending entry left its record.
    var settled = false
}

/// Posts the durable pending records the sync commits write. An ID leaves its record only once its post was accepted
/// or suppressed, so a failure or a restart retries it.
final class Notifier: Sendable {
    /// Accepted or suppressed posts per pass; retryable failures don't count.
    static let maxPerPass = 10
    /// More live pending messages than this in one space post as a summary.
    static let maxSinglesPerSpace = 5
    static let deletionScanLimit = 100
    static let bodyLimit = 200
    static let retryDelays: [Duration] = [.seconds(30), .seconds(120), .seconds(600)]

    let account: AccountID
    let store: any AccountStore
    let gate: SessionGate
    let me: UserName
    let poster: any NotificationPoster
    let clock: any SyncClock
    private let removed = Mutex(Set<MessageName>())
    private let passTrace = Mutex<[NotifyPassTrace]?>(nil)

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
    }

    /// Test seam: from now on every pass appends a `NotifyPassTrace`.
    func tracePasses() { passTrace.withLock { $0 = $0 ?? [] } }

    var tracedPasses: [NotifyPassTrace] { passTrace.withLock { $0 ?? [] } }

    private struct Settled {
        var messages: [MessageName] = []
        var notified: [MessageName] = []
        var overflow = 0
        var gap = false

        var isEmpty: Bool { messages.isEmpty && overflow == 0 && !gap }
    }

    /// Posts pending records of every space, then asks to remove notifications of deleted messages in `spaces`.
    @discardableResult
    func process(spaces: Set<SpaceName>, generation: Generation, context: NotifierContext) async -> NotifyPass {
        guard gate.isCurrent(generation) else { return NotifyPass() }
        var pass = NotifyPass()
        var posts = 0
        let records = (try? store.notifyRecords()) ?? [:]
        var trace: NotifyPassTrace? = passTrace.withLock { $0 == nil } ? nil : NotifyPassTrace()
        defer { if let trace { passTrace.withLock { $0?.append(trace) } } }
        trace?.pending = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0.value.messages(in: $0.key)) })
        for (space, record) in records.sorted(by: { $0.key < $1.key }) {
            guard gate.isCurrent(generation), !Task.isCancelled else { return pass }
            guard posts < Self.maxPerPass else {
                pass.more = true
                break
            }
            guard
                let settled = await post(
                    record, in: space, generation: generation, context: context, posts: &posts, pass: &pass,
                    trace: &trace)
            else {
                continue
            }
            guard !settled.isEmpty else { continue }
            let now = clock.now()
            do {
                try store.write(gate: gate, generation: generation) { batch in
                    if !settled.notified.isEmpty { batch.append(.markNotified(settled.notified, at: now)) }
                    batch.append(
                        .removeNotifyPending(
                            space, messages: settled.messages, overflow: settled.overflow, gap: settled.gap))
                }
            } catch {
                return pass
            }
            trace?.settled[space] = settled.messages
            pass.settled = true
        }

        let gone = removable(deleted(in: spaces))
        if !gone.isEmpty, gate.isCurrent(generation), !Task.isCancelled {
            await poster.remove(messages: gone)
        }
        return pass
    }

    /// Returns what to remove from the record, or `nil` when the space can't be read this pass.
    private func post(
        _ record: NotifyRecord, in space: SpaceName, generation: Generation, context: NotifierContext,
        posts: inout Int, pass: inout NotifyPass, trace: inout NotifyPassTrace?
    ) async -> Settled? {
        let all = record.messages(in: space)
        var settled = Settled()
        let lookup: StoredSpace?
        do { lookup = try store.space(space) } catch { return nil }
        guard let stored = lookup, !stored.isHidden, !(context.appIsActive && context.focusedSpace == space),
            stored.notificationSetting?.isMuted != true, NotificationPolicy.effectiveLevel(for: stored) != .off
        else {
            return Settled(messages: all, overflow: record.overflow, gap: record.gap)
        }
        var live: [Message] = []
        var pruned: [MessageName] = []
        for name in all {
            let found: Message?
            do { found = try store.message(name) } catch { return nil }
            if let message = found {
                if message.isDeleted { settled.messages.append(name) } else { live.append(message) }
            } else {
                pruned.append(name)
            }
        }
        live.sort { ($0.createTime, $0.name) < ($1.createTime, $1.name) }
        var folded = pruned
        if live.count > Self.maxSinglesPerSpace {
            folded += live.map(\.name)
            live = []
        }
        let count = record.overflow + folded.count
        if count > 0 || record.gap {
            guard gate.isCurrent(generation), !Task.isCancelled else { return settled }
            let request = summary(stored, count: count)
            trace?.attempted.append(request.identifier)
            switch await poster.post(request) {
            case .accepted, .suppressed:
                posts += 1
                settled.messages += folded
                settled.overflow = record.overflow
                settled.gap = record.gap
            case .retryable:
                pass.retry = true
            }
        }
        for message in live {
            guard gate.isCurrent(generation), !Task.isCancelled else { break }
            guard posts < Self.maxPerPass else {
                pass.more = true
                break
            }
            trace?.attempted.append(message.name.rawValue)
            switch await poster.post(single(message, in: stored)) {
            case .accepted:
                posts += 1
                settled.messages.append(message.name)
                settled.notified.append(message.name)
                // Expired while the post was in flight, after the cleanup that would have taken it down had run.
                if (try? store.message(message.name)) == nil { await poster.remove(messages: [message.name]) }
            case .suppressed:
                posts += 1
                settled.messages.append(message.name)
            case .retryable:
                pass.retry = true
            }
        }
        return settled
    }

    func removeAll() async {
        await poster.remove(account: account)
    }

    /// Takes down delivered notifications of messages Google has deleted under history-off retention.
    func removeExpired(_ messages: [MessageName]) async {
        removed.withLock { $0.formUnion(messages) }
        await poster.remove(messages: messages)
    }

    private func deleted(in spaces: Set<SpaceName>) -> [MessageName] {
        spaces.sorted().flatMap { space in
            ((try? store.messages(in: space, before: nil, limit: Self.deletionScanLimit)) ?? []).filter(\.isDeleted)
                .map(\.name)
        }
    }

    private func removable(_ deleted: [MessageName]) -> [MessageName] {
        let fresh = removed.withLock { removed in deleted.filter { !removed.contains($0) } }
        let notified = fresh.filter { (try? store.isNotified($0)) == true }
        removed.withLock { $0.formUnion(fresh) }
        return notified
    }

    private func single(_ message: Message, in stored: StoredSpace) -> ChatNotification {
        let title = SyncEngine.title(of: stored)
        let text = Self.preview(of: message)
        let sender = message.sender.displayName ?? "Someone"
        let body = stored.space.type == .directMessage ? text : "\(sender): \(text)"
        let thread = message.isThreadReply ? message.thread : nil
        return ChatNotification(
            account: account, space: message.space, thread: message.thread, message: message.name, title: title,
            body: String(body.prefix(Self.bodyLimit)), threadIdentifier: (thread?.rawValue ?? message.space.rawValue),
            identifier: message.name.rawValue)
    }

    /// `count` zero means only a reseed gap is known.
    private func summary(_ stored: StoredSpace, count: Int) -> ChatNotification {
        let title = SyncEngine.title(of: stored)
        let space = stored.space.name
        let body =
            count > 0 ? "\(count) new \(count == 1 ? "message" : "messages") in \(title)" : "New messages in \(title)"
        return ChatNotification(
            account: account, space: space, thread: nil, message: nil, title: title,
            body: String(body.prefix(Self.bodyLimit)), threadIdentifier: space.rawValue,
            identifier: "summary|\(space.rawValue)|\(clock.now().rfc3339)")
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
