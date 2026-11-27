import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatSync

/// Google deletes messages of history-off conversations after 24 hours and tells no client; the session must drop
/// its copies on its own, offline too.
struct HistoryRetentionSessionTests {
    static let day = Duration.seconds(24 * 3600)

    struct Rig: Sendable {
        let world: SimWorld
        let server: FakeChatServer
        let alice: FakeAccount
        let bob: FakeAccount
        let space: SpaceName
        let clock: SimClock
        let store: InMemoryAccountStore
        let poster = RecordingPoster()
        let session: AccountSession
        let recorder: SnapshotRecorder

        init(_ world: SimWorld, historyOn: Bool, timing: SessionTiming = .syncPolling) {
            self.world = world
            server = world.server
            alice = server.addAccount(displayName: "Alice")
            bob = server.addAccount(displayName: "Bob")
            space = server.addSpace(.groupChat, displayName: "", members: [alice, bob])
            server.setHistory(on: historyOn, in: space)
            server.advance(.seconds(5))
            let clock = world.clock()
            self.clock = clock
            store = InMemoryAccountStore(now: { clock.now() })
            session = world.syncSession(alice, store: store, clock: clock, timing: timing, notifications: poster)
            recorder = SnapshotRecorder(session.snapshots.values, in: world)
        }

        func start() async -> Bool {
            await session.start()
            let space = space
            let synced = await recorder.wait(in: world) { $0.status == .ok && $0.spaces.contains { $0.name == space } }
            await world.settle()
            return synced != nil
        }

        var summary: SpaceSummary? { recorder.latest?.spaces.first { $0.name == space } }

        func cached(_ name: MessageName) -> Bool { (try? store.message(name)) != nil }

        /// Goes offline, so whatever happens next happens without asking Google.
        func goOffline() async -> Int {
            await session.setConnectivity(.unreachable)
            await world.settle()
            return server.requests.count
        }
    }

    @Test func aHistoryOffMessageLeavesCacheUnreadAndNotificationsOfflineAfterADay() async throws {
        try await SimWorld.run { world in
            let rig = Rig(world, historyOn: false)
            #expect(await rig.start())
            await world.jump(by: .seconds(1))
            let message = rig.server.post("ephemeral", in: rig.space, from: .account(rig.bob))
            #expect(await world.run { rig.poster.posted.all.count == 1 })
            #expect(await world.run { rig.summary?.unreadCount == 1 })
            #expect(rig.cached(message.name))

            let requests = await rig.goOffline()
            await world.pass(Self.day - .seconds(60))
            #expect(rig.cached(message.name), "not before Google deletes it")
            await world.pass(.seconds(120))

            #expect(!rig.cached(message.name))
            #expect((try? rig.store.messages(in: rig.space, before: nil, limit: 10))?.isEmpty == true)
            #expect(rig.summary?.unreadCount == 0)
            #expect(rig.summary?.lastMessagePreview == nil)
            #expect(rig.summary?.retention?.isExpired(message.createTime, now: rig.clock.now()) == true)
            #expect(rig.poster.removedMessages.all.flatMap { $0 }.contains(message.name))
            #expect((try? rig.store.expiredCleanup()) == .some(nil), "the cleanup ran and was cleared")
            #expect(rig.server.requests.count == requests, "expiry needs no request")
        }
    }

    @Test func historyOnMessagesStay() async throws {
        try await SimWorld.run { world in
            let rig = Rig(world, historyOn: true)
            #expect(await rig.start())
            await world.jump(by: .seconds(1))
            let message = rig.server.post("kept", in: rig.space, from: .account(rig.bob))
            #expect(await world.run { rig.cached(message.name) })
            _ = await rig.goOffline()
            await world.pass(Self.day * 3)
            #expect(rig.cached(message.name))
            #expect(rig.summary?.retention == nil)
            #expect(await rig.session.expiryTimer == nil, "no expiry timer for a space with history on")
        }
    }

    @Test func onlyMessagesSentWhileHistoryWasOffExpireAfterAToggleSeenInEvents() async throws {
        try await SimWorld.run { world in
            let rig = Rig(world, historyOn: true, timing: .syncParked)
            #expect(await rig.start())
            let server = rig.server
            server.advance(.seconds(10))
            let before = server.post("before", in: rig.space, from: .account(rig.bob))
            server.advance(.seconds(10))
            server.setHistory(on: false, in: rig.space)
            server.advance(.seconds(10))
            let during = server.post("during", in: rig.space, from: .account(rig.bob))
            server.advance(.seconds(10))
            server.setHistory(on: true, in: rig.space)
            server.advance(.seconds(10))
            let after = server.post("after", in: rig.space, from: .account(rig.bob))
            await world.jump(by: .seconds(10))

            // Only the focused space's event poll can see the toggles: the listing shows history on before and after.
            await rig.session.setFocus(rig.space)
            #expect(await world.run { rig.cached(after.name) })
            await world.settle()
            #expect(rig.summary?.historyOn == true)

            _ = await rig.goOffline()
            await world.pass(Self.day)
            #expect(rig.cached(before.name))
            #expect(!rig.cached(during.name))
            #expect(rig.cached(after.name))
        }
    }

    @Test func expiredMessagesAreGoneBeforeTheSessionPublishesAnything() async throws {
        try await SimWorld.run { world in
            let server = world.server
            let alice = server.addAccount(displayName: "Alice")
            let clock = world.clock()
            let offset = Mutex(Duration.zero - Self.day * 2)
            let store = InMemoryAccountStore(now: { clock.now().adding(offset.withLock { $0 }) })
            let space = SpaceName(unchecked: "spaces/offline")
            let stale = Message(
                name: MessageName(unchecked: "spaces/offline/messages/old"),
                sender: User(name: UserName(unchecked: "users/7"), displayName: "Zed"),
                createTime: clock.now().adding(.zero - Self.day * 2), text: "left over from last week")
            // Written while it was still fresh, by the store's clock.
            try store.write(gate: SessionGate(), generation: Generation(1)) { batch in
                batch.append(.mergeSpace(Space(name: space, type: .groupChat, historyOn: false)))
                batch.append(.upsertMessages([stale]))
            }
            #expect((try? store.message(stale.name)) != nil)
            offset.withLock { $0 = .zero }

            let session = world.syncSession(alice, store: store, clock: clock)
            #expect((try? store.message(stale.name)) == .some(nil), "expired before the session can publish")
            await session.setConnectivity(.unreachable)
            let recorder = SnapshotRecorder(session.snapshots.values, in: world)
            await session.start()
            await world.settle()
            #expect(recorder.history.allSatisfy { $0.spaces.allSatisfy { $0.unreadCount == 0 } })
            #expect((try? store.expiredCleanup()) == .some(nil))
        }
    }
}
