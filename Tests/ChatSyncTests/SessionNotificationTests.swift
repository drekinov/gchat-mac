import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatSync

struct SessionNotificationTests {
    @Test func sessionNotifiesAfterTheFirstSyncAndHonoursFocus() async throws {
        try await SimWorld.run { world in
            let server = world.server
            let alice = server.addAccount(displayName: "Alice")
            let bob = server.addAccount(displayName: "Bob")
            let space = server.addSpace(.space, displayName: "Team", members: [alice, bob])
            server.post("history", in: space, from: .account(bob))
            server.advance(.seconds(5))

            let poster = RecordingPoster()
            let session = world.syncSession(alice, timing: .syncPolling, notifications: poster)
            let notifier = try #require(await session.notifier)
            notifier.tracePasses()
            let recorder = SnapshotRecorder(session.snapshots.values, in: world)
            await session.start()
            #expect(
                await recorder.wait(in: world) { $0.status == .ok && $0.spaces.contains { $0.name == space } } != nil)
            await world.settle()
            #expect(!notifier.tracedPasses.isEmpty, "the startup pass ran")
            #expect(poster.attempted.all.isEmpty, "history is never announced")

            await world.jump(by: .seconds(1))
            let fresh = server.post("new one", in: space, from: .account(bob))
            #expect(await world.run { poster.posted.all.count == 1 })
            #expect(poster.attempted.all.map(\.body) == ["Bob: new one"])

            await session.setFocus(space)
            await world.settle()
            let looking = server.post("while looking", in: space, from: .account(bob))
            #expect(
                await world.run { Self.settledWithoutPost(looking.name, in: space, notifier.tracedPasses) },
                "the focused message leaves its record without a post")
            await world.pass(.seconds(30))
            #expect(poster.attempted.all.map(\.message) == [fresh.name], "later polls don't bring it back")

            await session.setAppActive(false)
            let away = server.post("while away", in: space, from: .account(bob))
            #expect(await world.run { poster.posted.all.count == 2 })
            #expect(poster.attempted.all.map(\.message) == [fresh.name, away.name])
            #expect(poster.posted.all.last?.body == "Bob: while away")
        }
    }

    static func settledWithoutPost(_ message: MessageName, in space: SpaceName, _ passes: [NotifyPassTrace]) -> Bool {
        passes.contains { $0.settled[space]?.contains(message) == true && !$0.attempted.contains(message.rawValue) }
    }
}

/// The loop is parked an hour ahead after each sync, so the only other sleeper is the notifier's retry timer and a
/// pass runs only when the test moves time to that timer's deadline.
struct SessionNotificationRetryTests {
    struct Rig: Sendable {
        let world: SimWorld
        let server: FakeChatServer
        let alice: FakeAccount
        let bob: FakeAccount
        let spaces: [SpaceName]
        let poster = RecordingPoster()
        let store = InMemoryAccountStore()
        let session: AccountSession
        let notifier: Notifier
        let recorder: SnapshotRecorder

        init(_ world: SimWorld, spaces count: Int) async throws {
            self.world = world
            server = world.server
            alice = server.addAccount(displayName: "Alice")
            bob = server.addAccount(displayName: "Bob")
            var spaces: [SpaceName] = []
            for index in 0..<count {
                spaces.append(server.addSpace(.space, displayName: "Room \(index)", members: [alice, bob]))
            }
            self.spaces = spaces
            server.advance(.seconds(5))
            session = world.syncSession(alice, store: store, notifications: poster)
            notifier = try #require(await session.notifier)
            notifier.tracePasses()
            recorder = SnapshotRecorder(session.snapshots.values, in: world)
        }

        /// Posts fail unless `accepted` says otherwise. Past `limit` attempts every post is accepted, so a notifier
        /// that spins without letting time pass ends with wrong counts instead of never going quiet.
        func failPosts(
            limit: Int = 500, unless accepted: @escaping @Sendable (ChatNotification) -> Bool = { _ in false }
        ) {
            let attempts = Mutex(0)
            poster.setOutcome { request in
                let count = attempts.withLock { attempts -> Int in
                    attempts += 1
                    return attempts
                }
                return count > limit || accepted(request) ? .accepted : .retryable("notifications.1")
            }
        }

        /// Runs the first sync and the startup notifier passes to their end and returns how many passes that took.
        func start() async throws -> Int {
            await session.start()
            let count = spaces.count
            try #require(await recorder.wait(in: world) { $0.status == .ok && $0.spaces.count == count } != nil)
            await world.settle()
            #expect(poster.attempted.all.isEmpty, "nothing is pending before the first message")
            #expect(world.sleeperDeadlines.count == 1, "only the loop is asleep")
            return notifier.tracedPasses.count
        }

        /// Posts one message per space, old enough to be fetched, and runs the catch-up that finds them.
        func postEverywhere() async -> [MessageName] {
            await world.jump(by: .seconds(1))
            let messages = spaces.map { server.post("hello", in: $0, from: .account(bob)).name }
            await world.jump(by: .seconds(5))
            await session.systemDidWake()
            await world.settle()
            return messages
        }

        /// The armed retry timer's deadline: the one sleeper besides the loop.
        func retryDeadline() throws -> Timestamp {
            let deadlines = world.sleeperDeadlines
            try #require(deadlines.count == 2, "the loop and one retry timer are asleep, found \(deadlines.count)")
            try #require(deadlines[1] > world.now.adding(.seconds(1800)), "the loop is parked far ahead")
            return deadlines[0]
        }

        func attempts(of message: MessageName, in passes: ArraySlice<NotifyPassTrace>) -> Int {
            passes.reduce(0) { $0 + $1.attempted.filter { $0 == message.rawValue }.count }
        }
    }

    @Test func failingPostsAtTheCapDoNotSpin() async throws {
        try await SimWorld.run { world in
            let rig = try await Rig(world, spaces: Notifier.maxPerPass + 2)
            rig.failPosts()
            let startup = try await rig.start()
            let messages = await rig.postEverywhere()

            // The commit that found the messages runs one pass, which tries each of them once.
            let first = rig.notifier.tracedPasses[startup...]
            #expect(first.count == 1)
            for message in messages { #expect(rig.attempts(of: message, in: first) == 1) }
            #expect(rig.poster.attempted.all.count == messages.count)
            #expect(try rig.store.notifyRecords().count == messages.count)
            var due = try rig.retryDeadline()
            let wait = due.interval(since: world.now)
            // The pass follows the tick's last request, so the clock stands where the timer was armed.
            #expect(wait == .seconds(30), "the first retry is \(wait) away")

            // Each retry runs exactly one pass, which tries every pending message once and arms the next retry.
            let later: [Duration] = [.seconds(120), .seconds(600), .seconds(600)]
            for delay in later {
                await world.jump(to: due)
                #expect(world.now == due, "a retry pass calls nothing")
                let next = try rig.retryDeadline()
                #expect(next == due.adding(delay))
                due = next
            }
            let window = rig.notifier.tracedPasses[(startup + 1)...]
            #expect(window.count == later.count)
            for message in messages { #expect(rig.attempts(of: message, in: window) == later.count) }
            #expect(window.allSatisfy { $0.attempted.count == messages.count && $0.settled.isEmpty })
            #expect(rig.poster.attempted.all.count == messages.count * (1 + later.count))
            #expect(rig.poster.posted.all.isEmpty)
        }
    }

    @Test func tenFailingSpacesDoNotStarveAHealthyOne() async throws {
        try await SimWorld.run { world in
            let rig = try await Rig(world, spaces: Notifier.maxPerPass + 1)
            let healthy = try #require(rig.spaces.max())
            rig.failPosts(unless: { $0.space == healthy })
            let startup = try await rig.start()
            let messages = await rig.postEverywhere()

            let first = rig.notifier.tracedPasses[startup...]
            #expect(first.count == 1)
            for message in messages { #expect(rig.attempts(of: message, in: first) == 1) }
            #expect(rig.poster.posted.all.map(\.space) == [healthy], "the failures ahead of it don't use up the pass")

            await world.jump(to: try rig.retryDeadline())
            let window = rig.notifier.tracedPasses[(startup + 1)...]
            #expect(window.count == 1)
            for (space, message) in zip(rig.spaces, messages) {
                #expect(rig.attempts(of: message, in: window) == (space == healthy ? 0 : 1))
            }
            #expect(rig.poster.posted.all.map(\.space) == [healthy])
            _ = try rig.retryDeadline()
        }
    }

    @Test func theRetryTimerPostsWithoutANewCommit() async throws {
        try await SimWorld.run { world in
            let rig = try await Rig(world, spaces: 1)
            let failing = Mutex(true)
            rig.failPosts(unless: { _ in !failing.withLock { $0 } })
            let startup = try await rig.start()
            let messages = await rig.postEverywhere()
            #expect(rig.notifier.tracedPasses.count == startup + 1)
            #expect(rig.poster.attempted.all.count == 1)
            #expect(rig.poster.posted.all.isEmpty)
            let due = try rig.retryDeadline()
            failing.withLock { $0 = false }
            let revision = await rig.session.revision
            let requests = world.server.requests.count

            await world.jump(to: due.adding(.zero - .milliseconds(1)))
            #expect(rig.poster.attempted.all.count == 1, "nothing is tried before the timer fires")

            await world.jump(to: due)
            #expect(rig.notifier.tracedPasses.count == startup + 2)
            #expect(rig.poster.posted.all.map(\.identifier) == messages.map(\.rawValue))
            #expect(rig.poster.posted.all.first?.body == "Bob: hello")
            #expect(await rig.session.revision == revision, "no sync commit led to the post")
            #expect(world.server.requests.count == requests)
            #expect(world.sleeperDeadlines.count == 1, "a clean pass arms no retry")
        }
    }
}
