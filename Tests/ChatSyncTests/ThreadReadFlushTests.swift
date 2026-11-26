import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

/// A session that is never started, so its only tasks are the ones `setFocus` spawns; every answer from Google
/// waits at the barrier while it is armed.
private struct FlushRig: Sendable {
    let world: SimWorld
    let server: FakeChatServer
    let alice: FakeAccount
    let bob: FakeAccount
    let team: SpaceName
    let barrier: Barrier
    let log = CallLog()
    let session: AccountSession
    let work: WorkRegistry

    init(_ world: SimWorld) async {
        self.world = world
        server = world.server
        alice = server.addAccount(displayName: "Alice")
        bob = server.addAccount(displayName: "Bob")
        team = server.addSpace(.space, displayName: "Team", members: [alice, bob])
        barrier = world.barrier()
        let clock = world.clock()
        session = world.syncSession(
            alice, api: BarrierAPI(base: world.syncClient(alice), barrier: barrier, log: log, clock: clock),
            clock: clock)
        work = await session.work
    }

    /// A new thread with one reply from Bob.
    func thread(_ text: String) throws -> (thread: ThreadName, reply: Message) {
        let root = server.post(text, in: team, from: .account(bob))
        let thread = try #require(root.thread)
        server.advance(.seconds(5))
        let reply = server.post("reply in \(text)", in: team, from: .account(bob), thread: thread)
        server.advance(.seconds(5))
        return (thread, reply)
    }

    /// Syncs the space and runs the first focus tick to its end, after which nothing calls Google by itself.
    func syncAndFocus() async throws {
        let generation = try #require(session.gate.current)
        _ = try await session.engine.syncSpaces(generation)
        try await session.engine.syncMessages(team, generation)
        await session.setFocus(team)
        await world.settle()
        try #require(log.count("getSpaceReadState") >= 1 && work.count == 0, "the first focus tick ended")
    }

    func open(_ thread: ThreadName, upTo reply: Message) async {
        await session.setFocus(team, threadRead: ThreadReadPosition(thread: thread, upTo: reply.createTime))
        await world.settle()
    }

    func saved(_ thread: ThreadName) -> Timestamp? { server.threadReadState(alice, thread: thread) }
}

struct ThreadReadFlushTests {
    /// Jumping to a reply moves the thread's read point several times while the first save is still talking to
    /// Google. The newest point is saved as soon as that save ends, not at the next focus tick.
    @Test func aNewerReadPointArrivingDuringASaveIsSavedRightAfterIt() async throws {
        try await SimWorld.run { world in
            let rig = await FlushRig(world)
            let (thread, first) = try rig.thread("root")
            let second = rig.server.post("second reply", in: rig.team, from: .account(rig.bob), thread: thread)
            rig.server.advance(.seconds(5))
            try await rig.syncAndFocus()
            let checked = rig.log.count("getThreadReadState")

            rig.barrier.arm()
            await rig.open(thread, upTo: first)
            #expect(rig.barrier.arrivals == 1)
            #expect(rig.log.count("getThreadReadState") == checked + 1)
            #expect(rig.work.count == 1)

            // The second save attempt is a task of its own: it finds the first one running and returns.
            await rig.open(thread, upTo: second)
            #expect(rig.work.count == 1)
            #expect(rig.log.count("getThreadReadState") == checked + 1)
            #expect(rig.barrier.arrivals == 1)
            #expect(rig.saved(thread) == nil)

            rig.barrier.release()
            await world.settle()
            #expect(rig.saved(thread) == second.createTime, "saved with no focus tick and no time passing")
            #expect(rig.log.count("updateThreadReadState") == 1, "the superseded point is never written")
            #expect(rig.work.count == 0)
        }
    }

    /// A save that fails for good (its thread was deleted, say) doesn't strand the newer position for another thread.
    @Test func aPermanentFailureStillSavesTheNewerPositionForAnotherThread() async throws {
        try await SimWorld.run { world in
            let rig = await FlushRig(world)
            let (threadA, replyA) = try rig.thread("thread A")
            let (threadB, replyB) = try rig.thread("thread B")
            try await rig.syncAndFocus()

            // A's read-state lookup is refused for good, and parks with that answer while B's position arrives.
            rig.server.fail(
                FailureRule(
                    account: rig.alice, route: .getThreadReadState, times: 1,
                    response: .http(status: 400, googleStatus: "INVALID_ARGUMENT")))
            rig.barrier.arm()
            await rig.open(threadA, upTo: replyA)
            #expect(rig.barrier.arrivals == 1)
            await rig.open(threadB, upTo: replyB)
            #expect(rig.work.count == 1)
            #expect(rig.barrier.arrivals == 1)
            #expect(rig.saved(threadB) == nil)

            rig.barrier.release()
            await world.settle()
            #expect(rig.saved(threadB) == replyB.createTime)
            #expect(rig.saved(threadA) == nil)
            #expect(rig.work.count == 0)
        }
    }
}
