import Foundation
import Security
import Testing

@testable import ChatKeychain

struct SecretStoreTests {
    let id = SecretID(service: "io.github.drekinov.gchat-mac.test", account: "a")

    @Test func inMemoryRoundTrip() throws {
        let store = InMemorySecretStore()
        #expect(try store.read(id) == nil)
        try store.write(Data("one".utf8), for: id)
        try store.write(Data("two".utf8), for: id)
        #expect(try store.read(id) == Data("two".utf8))
        try store.delete(id)
        try store.delete(id)
        #expect(try store.read(id) == nil)
    }

    @Test func injectedFailureIsNeverAbsent() throws {
        let store = InMemorySecretStore()
        try store.write(Data("k".utf8), for: id)
        store.setFailure(.interactionNotAllowed, for: id)
        #expect(throws: SecretStoreError.interactionNotAllowed) { try store.read(id) }
        #expect(throws: SecretStoreError.interactionNotAllowed) { try store.delete(id) }
        store.setFailure(nil, for: id)
        #expect(try store.read(id) == Data("k".utf8))
    }

    @Test(arguments: [
        (errSecInteractionNotAllowed, SecretStoreError.interactionNotAllowed),
        (errSecAuthFailed, .authorizationFailed),
        (errSecUserCanceled, .authorizationFailed),
        (errSecMissingEntitlement, .missingEntitlement),
        (errSecDecode, .unexpectedStatus(errSecDecode)),
    ])
    func statusMapping(status: OSStatus, expected: SecretStoreError) {
        #expect(Keychain.error(for: status) == expected)
    }
}
