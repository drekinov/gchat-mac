import ChatModel
import Foundation
import GoogleChat
import Synchronization

/// Profile photo URLs for one account, looked up in People API batches and kept for the session. People without a
/// photo are remembered too, so each person costs at most one lookup; after a failure lookups pause for a while.
public final class ProfilePhotos: Sendable {
    static let retryAfter: Duration = .seconds(600)
    static let maxPerCall = 200

    private struct State {
        var known: [UserName: URL?] = [:]
        var inFlight: Set<UserName> = []
        var pausedUntil: Timestamp?
    }

    private let directory: (any PeopleDirectoryAPI)?
    private let clock: any SyncClock
    private let state = Mutex(State())

    init(directory: (any PeopleDirectoryAPI)?, clock: any SyncClock) {
        self.directory = directory
        self.clock = clock
    }

    public func cached(_ user: UserName) -> URL? {
        state.withLock { $0.known[user] ?? nil }
    }

    /// Looks up the users not seen yet and returns every known photo among `users`.
    public func load(_ users: [UserName]) async -> [UserName: URL] {
        let now = clock.now()
        let missing: [UserName] = state.withLock { state in
            if let paused = state.pausedUntil, paused > now { return [] }
            var picked: [UserName] = []
            for user in users where state.known.index(forKey: user) == nil && !state.inFlight.contains(user) {
                guard picked.count < Self.maxPerCall else { break }
                if !picked.contains(user) { picked.append(user) }
            }
            state.inFlight.formUnion(picked)
            return picked
        }
        if let directory, !missing.isEmpty {
            var start = 0
            while start < missing.count {
                let chunk = Array(missing[start..<min(start + profilePhotoBatch, missing.count)])
                start += chunk.count
                do throws(ChatAPIError) {
                    let found = try await directory.profilePhotos(for: chunk)
                    state.withLock { state in
                        for user in chunk { state.known[user] = .some(found[user]) }
                        state.inFlight.subtract(chunk)
                    }
                } catch {
                    let rest = missing[(start - chunk.count)...]
                    state.withLock { state in
                        state.inFlight.subtract(rest)
                        state.pausedUntil = now.adding(Self.retryAfter)
                    }
                    break
                }
            }
        } else {
            state.withLock { $0.inFlight.subtract(missing) }
        }
        return state.withLock { state in
            var result: [UserName: URL] = [:]
            for user in users { if let url = state.known[user] ?? nil { result[user] = url } }
            return result
        }
    }
}
