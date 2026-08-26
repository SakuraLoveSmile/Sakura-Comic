import Foundation
import Security

/// Credential storage on the Keychain (services: `KeychainStore.service`).
///
/// ServerProfile stores only `credentialRef` (the keychain account); the
/// secret itself never touches SQLite or UserDefaults. `credentialRef` for
/// a server with id X is `keychain:<X>` — see the app layer for the
/// convention. All operations are idempotent: delete on a missing item
/// succeeds, save overwrites.
public struct KeychainStore: Sendable {
    public static let service = "com.example.comic.komga"

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case conversionFailed
    }

    public init() {}

    /// Credential ref for a server id (shared convention, both platforms).
    public static func credentialRef(serverID: String) -> String {
        "keychain:\(serverID)"
    }

    /// Store or overwrite a secret under `ref`.
    public func save(secret: String, for ref: String) throws {
        let data = Data(secret.utf8)
        var query = baseQuery(ref: ref)
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Overwrite instead.
            let attributes = [kSecValueData as String: data] as CFDictionary
            let updateStatus = SecItemUpdate(baseQuery(ref: ref) as CFDictionary, attributes)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Read the secret under `ref`; nil when absent.
    public func read(ref: String) throws -> String? {
        var query = baseQuery(ref: ref)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw KeychainError.conversionFailed
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Delete the secret under `ref` (idempotent).
    public func delete(ref: String) throws {
        let status = SecItemDelete(baseQuery(ref: ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(ref: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: ref,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }
}