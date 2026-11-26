import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

/// A send queue whose requests wait at a barrier, so a second drain can arrive while the first is in flight.
private struct SendRaceRig: Sendable {
    let world: SimWorld
    let server: FakeChatServer
    let alice: FakeAccount
    let team: SpaceName
    let store = InMemoryAccountStore()
    let gate = SessionGate()
    let clock: SimClock
    let barrier: Barrier
    let sends: SendQueue

    init(_ world: SimWorld) {
        self.world = world
        server = world.server
        alice = server.addAccount(displayName: "Alice")
        team = server.addSpace(.space, displayName: "Team", members: [alice])
        server.advance(.seconds(5))
        clock = world.clock()
        barrier = world.barrier()
        let api = BarrierAPI(base: world.syncClient(alice), barrier: barrier, log: CallLog(), clock: clock)
        sends = SendQueue(api: api, store: store, gate: gate, clock: clock)
    }

    var generation: Generation { gate.current! }

    func enqueue(_ text: String) throws {
        _ = try sends.enqueue(text: text, space: team, thread: nil, generation)
        server.advance(.milliseconds(1))
    }

    /// Starts a drain and runs it to the barrier, where the answer to its first request waits.
    func heldDrain() async throws -> SimTask<Result<[UUID: SendOutcome]?, SyncError>> {
        barrier.arm()
        let (sends, team, generation) = (sends, team, generation)
        let drain = world.syncStart { () async throws(SyncError) in try await sends.drain(team, generation) }
        await world.settle()
        try #require(barrier.arrivals == 1 && !drain.isFinished, "the first send is in flight")
        return drain
    }

    var serverTexts: [String] { server.messages(in: team).map(\.text) }
}

struct SendRaceTests {
    @Test func aSecondDrainOfTheSameSpaceReturnsNilWhileTheFirstIsRunning() async throws {
        try await SimWorld.run { world in
            let rig = SendRaceRig(world)
            try rig.enqueue("one")
            let running = try await rig.heldDrain()

            let second = try await rig.sends.drain(rig.team, rig.generation)
            #expect(second == nil)
            rig.barrier.release()
            #expect(await world.run { running.isFinished })
            #expect(try await running.value.get() != nil)
            #expect(rig.serverTexts == ["one"])
        }
    }

    @Test func sendsEnqueuedWhileADrainIsRunningAreNotDropped() async throws {
        try await SimWorld.run { world in
            let rig = SendRaceRig(world)
            try rig.enqueue("one")
            let first = try await rig.heldDrain()

            try rig.enqueue("two")
            let overlapping = try await rig.sends.drain(rig.team, rig.generation)
            #expect(overlapping == nil)
            rig.barrier.release()
            // The first drain runs another pass for what the turned-away one would have sent, a second after "one".
            #expect(await world.run { first.isFinished })
            #expect(try await first.value.get() != nil)
            #expect(rig.serverTexts == ["one", "two"])
            #expect(try rig.store.outbox().isEmpty)
        }
    }
}

struct SendSessionTests {
    @Test func aBurstOfSessionSendsAllArriveInOrder() async throws {
        try await IsolationRig.run { rig in
            let texts = (1...5).map { "burst \($0)" }
            for text in texts {
                try await rig.sessionA.send(text, in: rig.spaceA, thread: nil)
                rig.server.advance(.milliseconds(1))
            }

            let bursts: @Sendable () -> [String] = {
                rig.server.messages(in: rig.spaceA).map(\.text).filter { $0.hasPrefix("burst") }
            }
            #expect(await rig.world.run { bursts().count == texts.count }, "a send enqueued during a drain was dropped")
            #expect(bursts() == texts)
            await rig.world.settle()
            #expect(try rig.sessionA.outbox(in: rig.spaceA).isEmpty)
        }
    }
}
