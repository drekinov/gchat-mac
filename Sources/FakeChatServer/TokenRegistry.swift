import Synchronization

/// Bearer tokens are globally unique, so concurrent fakes in parallel tests never see each other's traffic.
enum TokenRegistry {
    struct Entry: Sendable {
        weak let server: FakeChatServer?
        let account: FakeAccount
        var revoked: Bool
    }

    private static let entries = Mutex<[String: Entry]>([:])

    static func register(_ account: FakeAccount, server: FakeChatServer) {
        entries.withLock { $0[account.token] = Entry(server: server, account: account, revoked: false) }
    }

    static func lookup(_ token: String) -> Entry? {
        entries.withLock { $0[token] }
    }

    static func revoke(_ token: String) {
        entries.withLock { $0[token]?.revoked = true }
    }

    static func remove(_ tokens: [String]) {
        entries.withLock { entries in
            for token in tokens { entries[token] = nil }
        }
    }
}
