import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

struct MemberRefreshTests {
    /// A session past its first sync, with its loop parked far ahead.
    struct Rig: Sendable {
        let world: SimWorld
        let server: FakeChatServer
        let account: FakeAccount
        let spaces: [SpaceName]
        let session: AccountSession

        init(_ world: SimWorld, spaces count: Int) async throws {
            self.world = world
            let server = world.server
            self.server = server
            let account = server.addAccount(displayName: "Alice")
            let other = server.addAccount(displayName: "Bob")
            self.account = account
            spaces = (0..<count).map { server.addSpace(.space, displayName: "Space \($0)", members: [account, other]) }
            server.advance(.seconds(5))
            session = world.syncSession(account)
            let recorder = SnapshotRecorder(session.snapshots.values, in: world)
            await session.start()
            try #require(await recorder.wait(in: world) { $0.status == .ok && $0.spaces.count == count } != nil)
            await world.settle()
        }

        func memberRequests() -> [String] {
            server.requests.filter { $0.account == account && $0.method == "GET" && $0.path.hasSuffix("/members") }
                .map(\.path)
        }
    }

    @Test func prepareMembersFetchesOnlyTheFirstThirtyStaleSpaces() async throws {
        try await SimWorld.run { world in
            let rig = try await Rig(world, spaces: 35)
            for space in rig.spaces.prefix(3) { #expect(await rig.session.ensureMembers(in: space)) }
            let before = rig.memberRequests().count
            #expect(before == 3)

            await rig.session.prepareMembers(in: rig.spaces)
            await world.settle()

            let fetched = rig.memberRequests().dropFirst(before)
            #expect(fetched.count == Contacts.memberRefreshLimit)
            #expect(!fetched.contains { path in rig.spaces.prefix(3).contains { path.contains($0.rawValue + "/") } })
        }
    }

    @Test func ensureMembersReportsAFetchFailureAndHoldsOffDuringBackoff() async throws {
        try await SimWorld.run { world in
            let rig = try await Rig(world, spaces: 2)
            let (first, second) = (rig.spaces[0], rig.spaces[1])
            rig.server.fail(.unavailable(route: .listMembers, space: first))

            #expect(await rig.session.ensureMembers(in: first) == false)
            let until = try #require(await rig.session.retryUntil)
            #expect(until > world.now)
            let afterFailure = rig.memberRequests().count
            #expect(await rig.session.ensureMembers(in: second) == false)
            await world.settle()
            #expect(rig.memberRequests().count == afterFailure, "a backed-off account makes no new member requests")

            await world.jump(to: until)
            #expect(await rig.session.ensureMembers(in: second))
            #expect(rig.memberRequests().count == afterFailure + 1, "the same call fetches once the back-off ends")
        }
    }

    @Test func ensureMembersUsesAFreshCacheWithoutARequest() async throws {
        try await SimWorld.run { world in
            let rig = try await Rig(world, spaces: 1)
            let space = rig.spaces[0]
            #expect(await rig.session.ensureMembers(in: space))
            #expect(try rig.session.contacts.memberships(in: space).count == 2)
            let before = rig.memberRequests().count

            #expect(await rig.session.ensureMembers(in: space))
            await world.settle()
            #expect(rig.memberRequests().count == before)
        }
    }
}
