import Foundation

public struct SecretID: Hashable, Sendable, CustomStringConvertible {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public var description: String { "\(service)/\(account)" }
}

/// Failures that are never "absent": callers must not treat any of these as a missing item.
public enum SecretStoreError: Error, Sendable, Equatable {
    /// A prompt would be needed (keychain locked, or the item's ACL doesn't trust this app).
    case interactionNotAllowed
    case authorizationFailed
    case missingEntitlement
    case unexpectedData
    case unexpectedStatus(Int32)
}

public protocol SecretStore: Sendable {
    /// `nil` only when the item definitively doesn't exist.
    func read(_ id: SecretID) throws(SecretStoreError) -> Data?
    func write(_ data: Data, for id: SecretID) throws(SecretStoreError)
    /// Deleting an item that doesn't exist succeeds.
    func delete(_ id: SecretID) throws(SecretStoreError)
}
