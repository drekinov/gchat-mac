import ChatModel
import Foundation

@testable import ChatSync

extension SessionTiming {
    /// The app's cadences, spelled out so a test's deadlines don't move with the defaults.
    static var lifecycle: SessionTiming {
        var timing = SessionTiming()
        timing.sidebarInterval = .seconds(60)
        timing.inactiveSidebarInterval = .seconds(30)
        timing.liveSidebarInterval = .seconds(120)
        timing.idleSleep = .seconds(600)
        timing.logoutDrain = .seconds(2)
        return timing
    }
}

extension SimWorld {
    /// `perform` for an operation that can throw, such as a manager's logout or reconnect.
    @discardableResult
    func lifecyclePerform<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await perform { () -> Result<Value, any Error> in
            do { return .success(try await operation()) } catch { return .failure(error) }
        }.get()
    }

    /// Logs `session` out through its drain deadline.
    @discardableResult
    func lifecycleLogout(
        _ session: AccountSession, refreshToken: String? = nil
    ) async throws -> AccountSession.LogoutReport {
        try await perform { await session.logout(refreshToken: refreshToken) }
    }

    /// Logs `session` out when the world ends, unless the test already retired it.
    func lifecycleRetireAtTeardown(_ session: AccountSession) {
        onTeardown { [self] in
            guard await !session.closing else { return }
            _ = try? await lifecycleLogout(session)
        }
    }
}
