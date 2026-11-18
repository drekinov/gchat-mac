import ChatKeychain
import ChatModel
import Foundation
import Testing

@testable import ChatAuth

struct CredentialVaultTests {
    let store = InMemorySecretStore()
    let account = AccountID()
    var vault: CredentialVault { CredentialVault(secrets: store) }
    var id: SecretID { CredentialVault.secretID(for: account) }

    static func credentials(refresh: String = "rt-1", scope: String = OAuthScopes.required.joined(separator: " "))
        -> StoredCredentials
    {
        StoredCredentials(
            client: OAuthClientConfig(clientID: "1.apps.googleusercontent.com", clientSecret: "sec", projectID: "p"),
            refreshToken: refresh, grantedScope: scope,
            identity: .init(subject: "42", email: "ada@example.com", name: "Ada"))
    }

    @Test func roundTrip() throws {
        let gate = SessionGate()
        let saved = Self.credentials()
        try vault.save(saved, for: account, gate: gate, generation: gate.current!)
        #expect(try vault.load(account) == saved)
        #expect(store.storedIDs == [id])
    }

    @Test func saveInitialThenLoad() throws {
        try vault.saveInitial(Self.credentials(), for: account)
        #expect(try vault.load(account)?.refreshToken == "rt-1")
    }

    @Test func absentIsNilNotAnError() throws {
        #expect(try vault.load(account) == nil)
    }

    @Test func accountsAreIsolated() throws {
        let other = AccountID()
        try vault.saveInitial(Self.credentials(refresh: "a"), for: account)
        try vault.saveInitial(Self.credentials(refresh: "b"), for: other)
        #expect(try vault.load(account)?.refreshToken == "a")
        #expect(try vault.load(other)?.refreshToken == "b")
        #expect(CredentialVault.secretID(for: account) != CredentialVault.secretID(for: other))
    }

    @Test func corruptDataIsAnErrorNotNil() throws {
        try store.write(Data("{not json".utf8), for: id)
        #expect(throws: AuthError.vault("corrupt")) { try vault.load(account) }
    }

    @Test func wrongShapeIsCorrupt() throws {
        try store.write(Data(#"{"refreshToken":"x"}"#.utf8), for: id)
        #expect(throws: AuthError.vault("corrupt")) { try vault.load(account) }
    }

    @Test(arguments: [
        SecretStoreError.interactionNotAllowed, .authorizationFailed, .missingEntitlement, .unexpectedData,
        .unexpectedStatus(-25308),
    ])
    func storeFailureOnReadIsNeverNil(failure: SecretStoreError) throws {
        try vault.saveInitial(Self.credentials(), for: account)
        store.setFailure(failure, for: id)
        #expect(throws: AuthError.vault(String(describing: failure))) { try vault.load(account) }
    }

    @Test func storeFailureOnWriteAndDeleteSurfaces() {
        store.setFailure(.interactionNotAllowed, for: id)
        let gate = SessionGate()
        #expect(throws: AuthError.vault("interactionNotAllowed")) {
            try vault.save(Self.credentials(), for: account, gate: gate, generation: gate.current!)
        }
        #expect(throws: AuthError.vault("interactionNotAllowed")) {
            try vault.saveInitial(Self.credentials(), for: account)
        }
        #expect(throws: AuthError.vault("interactionNotAllowed")) { try vault.delete(account) }
    }

    @Test func saveThroughRetiredGateWritesNothing() throws {
        let gate = SessionGate()
        let generation = try #require(gate.current)
        gate.retire()
        #expect(throws: AuthError.retired) {
            try vault.save(Self.credentials(), for: account, gate: gate, generation: generation)
        }
        #expect(store.storedIDs.isEmpty)
    }

    @Test func staleGenerationAfterReloginIsRetired() throws {
        let gate = SessionGate()
        let old = try #require(gate.current)
        gate.retire()
        let fresh = gate.activate()
        #expect(throws: AuthError.retired) {
            try vault.save(Self.credentials(refresh: "old"), for: account, gate: gate, generation: old)
        }
        try vault.save(Self.credentials(refresh: "new"), for: account, gate: gate, generation: fresh)
        #expect(try vault.load(account)?.refreshToken == "new")
    }

    @Test func retiredSaveLeavesExistingEntryAlone() throws {
        let gate = SessionGate()
        let generation = try #require(gate.current)
        try vault.save(Self.credentials(refresh: "kept"), for: account, gate: gate, generation: generation)
        gate.retire()
        #expect(throws: AuthError.retired) {
            try vault.save(Self.credentials(refresh: "late"), for: account, gate: gate, generation: generation)
        }
        #expect(try vault.load(account)?.refreshToken == "kept")
    }

    @Test func deleteIsIdempotent() throws {
        try vault.delete(account)
        try vault.saveInitial(Self.credentials(), for: account)
        try vault.delete(account)
        try vault.delete(account)
        #expect(try vault.load(account) == nil)
        #expect(store.storedIDs.isEmpty)
    }

    @Test func storedJSONHasNoAccessToken() throws {
        try vault.saveInitial(Self.credentials(), for: account)
        let data = try #require(try store.read(id))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("access"))
    }

    @Test func needsReconsentTracksGrantedScopes() {
        #expect(!Self.credentials().needsReconsent)
        #expect(Self.credentials(scope: "openid email").needsReconsent)
        #expect(Self.credentials(scope: "").needsReconsent)
    }
}
