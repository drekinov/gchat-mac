import Foundation
import Security

/// Generic-password items in the user's keychain. Reads and writes never show UI; a prompt surfaces as
/// `SecretStoreError.interactionNotAllowed`.
public struct Keychain: SecretStore {
    public enum Backend: String, Sendable, CaseIterable {
        /// File-based login keychain; the item ACL trusts the creating app's designated requirement.
        case legacy
        /// Needs an application-identifier entitlement, i.e. a provisioning profile.
        case dataProtection
    }

    public let backend: Backend

    public init(backend: Backend = .legacy) {
        self.backend = backend
    }

    public func read(_ id: SecretID) throws(SecretStoreError) -> Data? {
        var query = baseQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        addNoUI(to: &query)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw .unexpectedData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(for: status)
        }
    }

    public func write(_ data: Data, for id: SecretID) throws(SecretStoreError) {
        var match = baseQuery(id)
        addNoUI(to: &match)
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(match as CFDictionary, update)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery(id)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = id.service
            if backend == .dataProtection {
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Self.error(for: addStatus) }
        default:
            throw Self.error(for: status)
        }
    }

    public func delete(_ id: SecretID) throws(SecretStoreError) {
        var query = baseQuery(id)
        addNoUI(to: &query)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(for: status) }
    }

    private func baseQuery(_ id: SecretID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: id.service,
            kSecAttrAccount as String: id.account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: backend == .dataProtection,
        ]
    }

    private func addNoUI(to query: inout [String: Any]) {
        // The only no-UI switch the legacy keychain honours; the LAContext replacement covers data protection only.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }

    static func error(for status: OSStatus) -> SecretStoreError {
        switch status {
        case errSecInteractionNotAllowed: .interactionNotAllowed
        case errSecAuthFailed, errSecUserCanceled: .authorizationFailed
        case errSecMissingEntitlement: .missingEntitlement
        default: .unexpectedStatus(status)
        }
    }
}
