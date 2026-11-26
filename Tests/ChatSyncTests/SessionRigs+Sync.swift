import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat

@testable import ChatSync

extension SessionTiming {
    /// After its first sync the loop has nothing due for an hour of virtual time.
    static var syncParked: SessionTiming {
        var timing = SessionTiming()
        timing.sidebarInterval = .seconds(3600)
        timing.inactiveSidebarInterval = .seconds(3600)
        timing.liveSidebarInterval = .seconds(3600)
        timing.focusInterval = 600...600
        timing.idleSleep = .seconds(3600)
        return timing
    }

    /// The sidebar polls every 10 s of virtual time and a focused space every 5 s; the loop wakes for nothing else.
    static var syncPolling: SessionTiming {
        var timing = SessionTiming()
        timing.sidebarInterval = .seconds(10)
        timing.inactiveSidebarInterval = .seconds(10)
        timing.liveSidebarInterval = .seconds(10)
        timing.focusInterval = 5...5
        timing.idleSleep = .seconds(3600)
        return timing
    }
}

extension SimWorld {
    func syncClient(_ account: FakeAccount) -> GoogleChatClient {
        GoogleChatClient(transport: transport(), tokens: StaticTokens(token: account.token))
    }

    /// A session of this world for `account`. The world logs it out when the test ends, unless the test did.
    func syncSession(
        _ account: FakeAccount, api: (any ChatAPI)? = nil, store: any AccountStore = InMemoryAccountStore(),
        clock: SimClock? = nil, timing: SessionTiming = .syncParked, notifications: (any NotificationPoster)? = nil,
        scratch: ScratchDirectory = ScratchDirectory()
    ) -> AccountSession {
        let session = AccountSession(
            account: AccountID(), me: account.user.name, api: api ?? syncClient(account), store: store,
            clock: clock ?? self.clock(),
            logoutRunner: LogoutRunner(eraser: NoopEraser(), tombstones: LogoutTombstones(root: scratch.url)),
            timing: timing, notifications: notifications, executor: executor)
        onTeardown { [weak self] in
            // The tombstone directory lives as long as the session can write to it.
            _ = scratch
            guard let self, await !session.closing else { return }
            _ = try? await perform { await session.logout(refreshToken: nil) }
        }
        return session
    }

    /// `start` for an operation that throws: the task's value is its result.
    func syncStart<Value: Sendable, Failure: Error>(
        _ operation: @escaping @Sendable () async throws(Failure) -> Value
    ) -> SimTask<Result<Value, Failure>> {
        start { () async -> Result<Value, Failure> in
            do throws(Failure) {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
    }

    /// `perform` for an operation that throws: its own error comes back in the result, a stall is thrown.
    func syncAttempt<Value: Sendable, Failure: Error>(
        _ operation: @escaping @Sendable () async throws(Failure) -> Value
    ) async throws -> Result<Value, Failure> {
        let task = syncStart(operation)
        guard await run(upTo: .seconds(86_400), until: { task.isFinished }) else {
            task.cancel()
            throw SimError.stalled(dump())
        }
        return await task.value
    }

    /// How many requests of `account` matched, in the order the server answered them.
    func syncRequests(of account: FakeAccount, _ method: String, suffix: String) -> Int {
        server.requests.filter { $0.account == account && $0.method == method && $0.path.hasSuffix(suffix) }.count
    }
}
