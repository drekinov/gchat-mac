import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

enum GateOp: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case spaces
    case messagesSeed
    case messagesCatchUp
    case events
    case readState
    case threadReadStates
    case memberTitle
    case markRead
    case send

    var testDescription: String { rawValue }
}

enum GateInterference: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case retire
    case retireThenReactivate

    var testDescription: String { rawValue }
}

extension SyncRig {
    func prepare(_ op: GateOp) async throws {
        let g = generation
        switch op {
        case .spaces:
            break
        case .messagesSeed, .readState, .threadReadStates, .memberTitle:
            try await syncSpaces()
            if op == .readState { server.setReadState(alice, space: team, lastReadTime: first.createTime) }
            if op == .threadReadStates {
                server.setThreadReadState(alice, thread: thread, lastReadTime: first.createTime)
            }
        case .messagesCatchUp:
            try await syncSpaces()
            try await engine.syncMessages(team, g)
            server.post("second", in: team, from: .account(bob))
            server.advance(.seconds(5))
        case .events:
            try await syncSpaces()
            try await engine.syncMessages(team, g)
            server.edit(first.name, text: "edited")
            server.advance(.seconds(5))
        case .markRead:
            try await syncSpaces()
            try await engine.syncMessages(team, g)
        case .send:
            try await syncSpaces()
            _ = try sends.enqueue(text: "hi", space: team, thread: nil, g)
        }
    }

    func start(_ op: GateOp, _ generation: Generation) -> Task<SyncError?, Never> {
        let engine = engine
        let sends = sends
        let team = team
        let dm = dm
        let thread = thread
        let readTime = first.createTime
        return Task { () async -> SyncError? in
            do throws(SyncError) {
                switch op {
                case .spaces: _ = try await engine.syncSpaces(generation)
                case .messagesSeed, .messagesCatchUp: try await engine.syncMessages(team, generation)
                case .events: try await engine.syncEvents(team, generation)
                case .readState: try await engine.syncReadState(team, generation)
                case .threadReadStates: try await engine.syncThreadReadStates([thread], generation)
                case .memberTitle: try await engine.syncMemberTitle(dm, generation)
                case .markRead: try await engine.markRead(team, upTo: readTime, generation)
                case .send: _ = try await sends.drain(team, generation)
                }
                return nil
            } catch {
                return error
            }
        }
    }
}

struct GateCase: Sendable, CustomTestStringConvertible {
    var op: GateOp
    var interference: GateInterference
    var kind: StoreKind

    var testDescription: String { "\(op.rawValue)/\(interference.rawValue)/\(kind.rawValue)" }

    static let all: [GateCase] = GateOp.allCases.flatMap { op in
        GateInterference.allCases.flatMap { interference in
            StoreKind.allCases.map { GateCase(op: op, interference: interference, kind: $0) }
        }
    }
}

struct CommitGateTests {
    @Test(arguments: GateCase.all)
    func operationRetiredAtTheBarrierCommitsNothing(_ scenario: GateCase) async throws {
        let (op, interference, kind) = (scenario.op, scenario.interference, scenario.kind)
        let rig = try SyncRig(store: kind)
        defer { rig.close() }
        try await rig.prepare(op)
        let old = rig.generation
        let beforeOperation = try rig.dump()

        rig.barrier.arm()
        let task = rig.start(op, old)
        #expect(await rig.barrier.waitForArrival(), "the operation never reached the barrier")
        let atBarrier = try rig.dump()
        if op != .send { #expect(atBarrier == beforeOperation, "committed before its network await finished") }

        rig.gate.retire()
        if interference == .retireThenReactivate { _ = rig.gate.activate() }
        rig.barrier.release()
        let error = await task.value

        #expect(error == .retired)
        #expect(try rig.dump() == atBarrier)

        if op == .send {
            let item = try #require(try rig.store.outbox().first)
            #expect(item.state == .sending)
            let created = rig.server.messages(in: rig.team).filter { $0.text == "hi" }
            #expect(created.count == 1, "the server should have created the message")
            #expect(try rig.store.messages(in: rig.team, before: nil, limit: 100).allSatisfy { $0.text != "hi" })
        }

        if interference == .retireThenReactivate {
            _ = try await rig.engine.syncSpaces(rig.generation)
            #expect(try rig.store.spaces().isEmpty == false, "the new generation must be able to commit")
        }
    }

    @Test(arguments: GateOp.allCases, StoreKind.allCases)
    func controlWithoutRetireDoesCommit(op: GateOp, kind: StoreKind) async throws {
        let rig = try SyncRig(store: kind)
        defer { rig.close() }
        try await rig.prepare(op)
        let before = try rig.dump()

        rig.barrier.arm()
        let task = rig.start(op, rig.generation)
        #expect(await rig.barrier.waitForArrival())
        rig.barrier.release()
        let error = await task.value

        #expect(error == nil)
        let after = try rig.dump()
        #expect(after != before, "the operation changes nothing, so the retire test proves nothing")
        if op == .send {
            #expect(after.outbox.isEmpty)
            #expect(after.messages[rig.team]?.contains { $0.text == "hi" } == true)
        }
    }

    @Test func stragglerTaggedWithAnOlderGenerationStaysRejectedAfterActivate() async throws {
        let rig = try SyncRig()
        let old = rig.generation
        let retired = rig.gate.retire()
        let renewed = rig.gate.activate()
        #expect(renewed > retired)

        await #expect(throws: SyncError.retired) { _ = try await rig.engine.syncSpaces(old) }
        await #expect(throws: SyncError.retired) { _ = try await rig.engine.syncSpaces(retired) }
        #expect(try rig.store.spaces().isEmpty)
        #expect(rig.gate.isCurrent(old) == false)
        #expect(rig.gate.isCurrent(retired) == false)
        #expect(rig.gate.isCurrent(renewed))

        _ = try await rig.engine.syncSpaces(renewed)
        #expect(try rig.store.spaces().count == 2)
    }

    @Test func retireWaitsForAnInFlightCommitAndRejectsEveryLaterOne() throws {
        let gate = SessionGate()
        let store = InMemoryAccountStore()
        let g = gate.current!
        try store.write(gate: gate, generation: g) { $0.append(.setMeta(key: "k", value: "1")) }
        gate.retire()
        #expect(throws: StoreError.gateClosed) {
            try store.write(gate: gate, generation: g) { $0.append(.setMeta(key: "k", value: "2")) }
        }
        #expect(try store.meta("k") == "1")
        gate.close()
        let activated = gate.activate()
        #expect(throws: StoreError.gateClosed) {
            try store.write(gate: gate, generation: g) { $0.append(.setMeta(key: "k", value: "3")) }
        }
        try store.write(gate: gate, generation: activated) { $0.append(.setMeta(key: "k", value: "4")) }
        #expect(try store.meta("k") == "4")
    }
}
