import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

struct ThreadReadFlushTests {
    /// Jumping to a reply moves the thread's read point several times while the first save is still talking to
    /// Google. The newest point is saved as soon as that save ends, not at the next focus tick.
    @Test func aNewerReadPointArrivingDuringASaveIsSavedRightAfterIt() async throws {
        let server = FakeChatServer()
        let alice = server.addAccount(displayName: "Alice")
        let bob = server.addAccount(displayName: "Bob")
        let team = server.addSpace(.space, displayName: "Team", members: [alice, bob])
        let root = server.post("root", in: team, from: .account(bob))
        let thread = try #require(root.thread)
        server.advance(.seconds(5))
        let first = server.post("first reply", in: team, from: .account(bob), thread: thread)
        server.advance(.seconds(5))
        let second = server.post("second reply", in: team, from: .account(bob), thread: thread)
        server.advance(.seconds(5))

        let clock = ServerClock(server: server)
        let barrier = Barrier()
        let log = CallLog()
        let client = GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token))
        let scratch = ScratchDirectory()
        var timing = SessionTiming.fast
        timing.focusInterval = 600...600
        let session = AccountSession(
            account: AccountID(), me: alice.user.name,
            api: BarrierAPI(base: client, barrier: barrier, log: log, clock: clock),
            store: InMemoryAccountStore(), clock: clock,
            logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: scratch.url)),
            timing: timing)
        let generation = try #require(session.gate.current)
        let work = await session.work
        _ = try await session.engine.syncSpaces(generation)
        try await session.engine.syncMessages(team, generation)
        // Focusing the space starts its first sync. After its read state nothing else calls Google (no threads are
        // visible and nothing has reactions), so once it's done the barrier can only park the thread read.
        await session.setFocus(team)
        #expect(await poll { log.count("getSpaceReadState") >= 1 && work.count == 0 })

        barrier.arm()
        await session.setFocus(team, threadRead: ThreadReadPosition(thread: thread, upTo: first.createTime))
        #expect(await barrier.waitForArrival())
        #expect(log.count("getThreadReadState") == 1)
        #expect(work.count == 1)
        await session.setFocus(team, threadRead: ThreadReadPosition(thread: thread, upTo: second.createTime))
        // The second save attempt is a task of its own. Once the registry is back to one task it has returned while
        // the first is still parked, having made no call and saved nothing, so only the first save's loop can
        // deliver the newer position.
        #expect(await poll { work.count == 1 })
        #expect(log.count("getThreadReadState") == 1)
        #expect(barrier.arrivals == 1)
        #expect(server.threadReadState(alice, thread: thread) == nil)
        barrier.release()

        let saved = await poll(timeout: .seconds(3)) {
            server.threadReadState(alice, thread: thread) == second.createTime
        }
        #expect(saved)
    }

    /// A save that fails for good (its thread was deleted, say) doesn't strand the newer position for another thread.
    @Test func aPermanentFailureStillSavesTheNewerPositionForAnotherThread() async throws {
        let server = FakeChatServer()
        let alice = server.addAccount(displayName: "Alice")
        let bob = server.addAccount(displayName: "Bob")
        let team = server.addSpace(.space, displayName: "Team", members: [alice, bob])
        let rootA = server.post("thread A", in: team, from: .account(bob))
        let threadA = try #require(rootA.thread)
        server.advance(.seconds(5))
        let rootB = server.post("thread B", in: team, from: .account(bob))
        let threadB = try #require(rootB.thread)
        server.advance(.seconds(5))
        let replyA = server.post("reply in A", in: team, from: .account(bob), thread: threadA)
        server.advance(.seconds(5))
        let replyB = server.post("reply in B", in: team, from: .account(bob), thread: threadB)
        server.advance(.seconds(5))

        let clock = ServerClock(server: server)
        let barrier = Barrier()
        let log = CallLog()
        let client = GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: alice.token))
        let scratch = ScratchDirectory()
        var timing = SessionTiming.fast
        timing.focusInterval = 600...600
        let session = AccountSession(
            account: AccountID(), me: alice.user.name,
            api: BarrierAPI(base: client, barrier: barrier, log: log, clock: clock),
            store: InMemoryAccountStore(), clock: clock,
            logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: scratch.url)),
            timing: timing)
        let generation = try #require(session.gate.current)
        let work = await session.work
        _ = try await session.engine.syncSpaces(generation)
        try await session.engine.syncMessages(team, generation)
        await session.setFocus(team)
        #expect(await poll { log.count("getSpaceReadState") >= 1 && work.count == 0 })

        // A's read-state lookup is refused for good, and parks with that answer while B's position arrives.
        server.fail(
            FailureRule(
                account: alice, route: .getThreadReadState, times: 1,
                response: .http(status: 400, googleStatus: "INVALID_ARGUMENT")))
        barrier.arm()
        await session.setFocus(team, threadRead: ThreadReadPosition(thread: threadA, upTo: replyA.createTime))
        #expect(await barrier.waitForArrival())
        await session.setFocus(team, threadRead: ThreadReadPosition(thread: threadB, upTo: replyB.createTime))
        #expect(await poll { work.count == 1 })
        #expect(server.threadReadState(alice, thread: threadB) == nil)
        barrier.release()

        let saved = await poll(timeout: .seconds(3)) {
            server.threadReadState(alice, thread: threadB) == replyB.createTime
        }
        #expect(saved)
        #expect(server.threadReadState(alice, thread: threadA) == nil)
    }
}
