import Foundation
import Synchronization

/// Test double with injectable failures per item.
public final class InMemorySecretStore: SecretStore {
    private let state = Mutex(State())

    private struct State {
        var items: [SecretID: Data] = [:]
        var failures: [SecretID: SecretStoreError] = [:]
    }

    public init() {}

    public func read(_ id: SecretID) throws(SecretStoreError) -> Data? {
        try state.withLock { state throws(SecretStoreError) in
            if let failure = state.failures[id] { throw failure }
            return state.items[id]
        }
    }

    public func write(_ data: Data, for id: SecretID) throws(SecretStoreError) {
        try state.withLock { state throws(SecretStoreError) in
            if let failure = state.failures[id] { throw failure }
            state.items[id] = data
        }
    }

    public func delete(_ id: SecretID) throws(SecretStoreError) {
        try state.withLock { state throws(SecretStoreError) in
            if let failure = state.failures[id] { throw failure }
            state.items[id] = nil
        }
    }

    public func setFailure(_ failure: SecretStoreError?, for id: SecretID) {
        state.withLock { $0.failures[id] = failure }
    }

    public var storedIDs: Set<SecretID> {
        state.withLock { Set($0.items.keys) }
    }
}
