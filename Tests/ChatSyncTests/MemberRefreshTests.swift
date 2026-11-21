import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

struct MemberRefreshTests {
    struct Rig {
        let server = FakeChatServer()
        let account: FakeAccount
        let spaces: [SpaceName]
        let session: AccountSession
        let scratch = ScratchDirectory()

        init(spaces count: Int) async {
            let server = server
            let account = server.addAccount(displayName: "Alice")
            let other = server.addAccount(displayName: "Bob")
            self.account = account
            spaces = (0..<count).map { server.addSpace(.space, displayName: "Space \($0)", members: [account, other]) }
            server.advance(.seconds(5))
            session = AccountSession(
                account: AccountID(), me: account.user.name,
                api: GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: account.token)),
                store: InMemoryAccountStore(), clock: SteppingClock(server: server),
                logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: scratch.url)),
                timing: .fast)
            let recorder = SnapshotRecorder(session.snapshots.values)
            await session.start()
            let expected = count
            _ = await recorder.wait { $0.status == .ok && $0.spaces.count == expected }
        }

        func memberRequests() -> [String] {
            server.requests.filter { $0.account == account && $0.method == "GET" && $0.path.hasSuffix("/members") }
                .map(\.path)
        }

        func shutdown() async { _ = await session.logout(refreshToken: nil) }
    }

    @Test func prepareMembersFetchesOnlyTheFirstThirtyStaleSpaces() async throws {
        let rig = await Rig(spaces: 35)
        for space in rig.spaces.prefix(3) { #expect(await rig.session.ensureMembers(in: space)) }
        let before = rig.memberRequests().count

        await rig.session.prepareMembers(in: rig.spaces)

        let fetched = rig.memberRequests().dropFirst(before)
        #expect(fetched.count == Contacts.memberRefreshLimit)
        #expect(!fetched.contains { path in rig.spaces.prefix(3).contains { path.contains($0.rawValue + "/") } })
        await rig.shutdown()
    }

    @Test func ensureMembersReportsAFetchFailureAndHoldsOffDuringBackoff() async throws {
        let rig = await Rig(spaces: 2)
        let (first, second) = (rig.spaces[0], rig.spaces[1])
        rig.server.fail(.unavailable(route: .listMembers, space: first))

        #expect(await rig.session.ensureMembers(in: first) == false)
        let afterFailure = rig.memberRequests().count
        #expect(await rig.session.ensureMembers(in: second) == false)
        #expect(rig.memberRequests().count == afterFailure, "a backed-off account makes no new member requests")
        await rig.shutdown()
    }

    @Test func ensureMembersUsesAFreshCacheWithoutARequest() async throws {
        let rig = await Rig(spaces: 1)
        let space = rig.spaces[0]
        #expect(await rig.session.ensureMembers(in: space))
        #expect(try rig.session.contacts.memberships(in: space).count == 2)
        let before = rig.memberRequests().count

        #expect(await rig.session.ensureMembers(in: space))
        #expect(rig.memberRequests().count == before)
        await rig.shutdown()
    }
}
