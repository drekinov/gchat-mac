import ChatModel
import ChatStore
import Foundation
import GoogleChat
import Synchronization

/// The user's own reactions and custom emoji for one account. "Mine" isn't in reaction summaries, so it's learned
/// per message via `listReactions(user: me)` and kept in memory only.
public final class Reactions: Sendable {
    /// Google allows 5 reaction writes per second per space.
    public static let spacing = Duration.milliseconds(250)
    static let maxTracked = 2000
    static let refreshAfter = Duration.seconds(60)
    static let emojiRefresh = Duration.seconds(6 * 3600)

    let api: any ChatAPI
    let store: any AccountStore
    let gate: SessionGate
    let clock: any SyncClock
    let me: UserName

    private struct Tracked {
        var mine: [Emoji: ReactionName]
        var checked: Timestamp
    }

    private struct State {
        var tracked: [MessageName: Tracked] = [:]
        var lastWrite: [SpaceName: Timestamp] = [:]
        var customEmojis: [CustomEmoji] = []
        var emojisFetched: Timestamp?
    }

    private let state = Mutex(State())

    init(api: any ChatAPI, store: any AccountStore, gate: SessionGate, clock: any SyncClock, me: UserName) {
        self.api = api
        self.store = store
        self.gate = gate
        self.clock = clock
        self.me = me
    }

    public func mine(on message: MessageName) -> [Emoji: ReactionName] {
        state.withLock { $0.tracked[message]?.mine ?? [:] }
    }

    public var customEmojis: [CustomEmoji] { state.withLock { $0.customEmojis } }

    /// Adds the reaction, or removes it when it's already the user's. The summary updates locally at once and is
    /// then replaced by the server's.
    public func toggle(_ emoji: Emoji, on message: MessageName, _ generation: Generation) async throws(SyncError) {
        try await pace(message.space)
        if let existing = mine(on: message)[emoji] {
            do throws(ChatAPIError) {
                try await api.deleteReaction(existing)
            } catch .notFound {
            } catch {
                guard case .permissionDenied = error else { throw .api(error, .deleteReaction) }
                try await refreshMine([message], generation, force: true)
                guard mine(on: message)[emoji] == nil else { throw .api(error, .deleteReaction) }
            }
            setMine(message) { $0[emoji] = nil }
            try adjustSummary(message, emoji, by: -1, generation)
        } else {
            var created: Reaction?
            do throws(ChatAPIError) {
                created = try await api.createReaction(on: message, emoji: emoji)
            } catch .conflict {
                created = nil
            } catch {
                throw .api(error, .createReaction)
            }
            if let created {
                setMine(message) { $0[emoji] = created.name }
                try adjustSummary(message, emoji, by: 1, generation)
            } else {
                try await refreshMine([message], generation, force: true)
            }
        }
        try await refreshSummary(message, generation)
    }

    /// Learns which reactions are the user's for messages that have any, skipping recently checked ones.
    func refreshMine(_ messages: [MessageName], _ generation: Generation, force: Bool = false) async throws(SyncError) {
        let now = clock.now()
        let due = messages.filter { name in
            force || state.withLock { $0.tracked[name].map { $0.checked.adding(Self.refreshAfter) < now } ?? true }
        }
        for message in due {
            var mine: [Emoji: ReactionName] = [:]
            var token: String?
            var pages = 0
            repeat {
                let page: Page<Reaction>
                do throws(ChatAPIError) {
                    page = try await api.listReactions(on: message, user: me, pageToken: token)
                } catch .notFound {
                    break
                } catch {
                    throw .api(error, .listReactions)
                }
                for reaction in page.items where reaction.user == me { mine[reaction.emoji] = reaction.name }
                token = page.nextPageToken
                pages += 1
            } while token != nil && pages < 5
            guard gate.isCurrent(generation) else { throw .retired }
            let checked = clock.now()
            state.withLock { state in
                state.tracked[message] = Tracked(mine: mine, checked: checked)
                if state.tracked.count > Self.maxTracked {
                    let oldest = state.tracked.sorted { $0.value.checked < $1.value.checked }
                        .prefix(state.tracked.count - Self.maxTracked)
                    for (name, _) in oldest { state.tracked[name] = nil }
                }
            }
        }
    }

    func refreshSummary(_ message: MessageName, _ generation: Generation) async throws(SyncError) {
        let fresh: Message
        do throws(ChatAPIError) {
            fresh = try await api.getMessage(message)
        } catch .notFound {
            return
        } catch {
            throw .api(error, .readSpace)
        }
        try commit(generation) { $0.append(.updateReactions(message, fresh.reactions)) }
    }

    func adjustSummary(_ message: MessageName, _ emoji: Emoji, by delta: Int, _ generation: Generation)
        throws(SyncError)
    {
        let stored: Message?
        do { stored = try store.message(message) } catch { throw .store(error) }
        guard var reactions = stored?.reactions else { return }
        if let index = reactions.firstIndex(where: { $0.emoji == emoji }) {
            reactions[index].count = max(0, reactions[index].count + delta)
            if reactions[index].count == 0 { reactions.remove(at: index) }
        } else if delta > 0 {
            reactions.append(ReactionSummary(emoji: emoji, count: delta))
        }
        let updated = reactions
        try commit(generation) { $0.append(.updateReactions(message, updated)) }
    }

    /// Fetches the org's custom emoji at most every 6 hours. A 403 (feature off, preview API) leaves the list empty.
    func refreshCustomEmojis(_ generation: Generation) async throws(SyncError) {
        let now = clock.now()
        if let fetched = state.withLock({ $0.emojisFetched }), fetched.adding(Self.emojiRefresh) > now { return }
        var emojis: [CustomEmoji] = []
        var token: String?
        var pages = 0
        repeat {
            let page: Page<CustomEmoji>
            do throws(ChatAPIError) {
                page = try await api.listCustomEmojis(pageToken: token)
            } catch .permissionDenied, .notFound {
                break
            } catch {
                throw .api(error, .listCustomEmojis)
            }
            emojis += page.items
            token = page.nextPageToken
            pages += 1
        } while token != nil && pages < 5
        guard gate.isCurrent(generation) else { throw .retired }
        let sorted = emojis.sorted { $0.shortcode < $1.shortcode }
        state.withLock {
            $0.customEmojis = sorted
            $0.emojisFetched = now
        }
    }

    func setMine(_ message: MessageName, _ change: (inout [Emoji: ReactionName]) -> Void) {
        let now = clock.now()
        state.withLock { state in
            var tracked = state.tracked[message] ?? Tracked(mine: [:], checked: now)
            change(&tracked.mine)
            state.tracked[message] = tracked
        }
    }

    func lastWrite(_ space: SpaceName) -> Timestamp? { state.withLock { $0.lastWrite[space] } }

    func pace(_ space: SpaceName) async throws(SyncError) {
        let now = clock.now()
        let ready = state.withLock { state -> Timestamp in
            let ready = max(now, state.lastWrite[space].map { $0.adding(Self.spacing) } ?? now)
            state.lastWrite[space] = ready
            return ready
        }
        guard ready > now else { return }
        let wait = Duration.seconds(ready.seconds - now.seconds) + .nanoseconds(Int64(ready.nanos) - Int64(now.nanos))
        do { try await clock.sleep(for: wait) } catch { throw .retired }
    }

    func commit(_ generation: Generation, _ build: (inout StoreWrite) -> Void) throws(SyncError) {
        do {
            try store.write(gate: gate, generation: generation, build)
        } catch .gateClosed {
            throw .retired
        } catch {
            throw .store(error)
        }
    }
}
