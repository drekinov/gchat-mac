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
        _ = try await session.engine.syncSpaces(generation)
        try await session.engine.syncMessages(team, generation)
        // Focusing the space starts its first sync; let it finish so only the thread read is parked.
        await session.setFocus(team)
        #expect(await poll { log.count("getSpaceReadState") >= 1 })
        try await Task.sleep(for: .milliseconds(200))

        barrier.arm()
        await session.setFocus(team, threadRead: ThreadReadPosition(thread: thread, upTo: first.createTime))
        #expect(await barrier.waitForArrival())
        await session.setFocus(team, threadRead: ThreadReadPosition(thread: thread, upTo: second.createTime))
        barrier.release()

        let saved = await poll(timeout: .seconds(3)) {
            server.threadReadState(alice, thread: thread) == second.createTime
        }
        #expect(saved)
    }
}
