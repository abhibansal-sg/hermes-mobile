import Foundation
import Security

/// Stores the per-server session token in the iOS keychain.
///
/// Items are scoped to service `ai.hermes.mobile` with the server string as the
/// account, so each gateway the user connects to keeps its own token. Loads are
/// non-throwing (a missing or unreadable item simply yields `nil`).
enum KeychainService {
    private static let service = "ai.hermes.mobile"

    /// Persist `token` for `server`, replacing any existing value.
    /// - Throws: ``KeychainError/unexpectedStatus(_:)`` if the keychain rejects the write.
    static func saveToken(_ token: String, server: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
        ]
        let status = SecItemAdd(
            query.merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { _, new in new } as CFDictionary,
            nil
        )

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Return the stored token for `server`, or `nil` if none exists or it is unreadable.
    static func loadToken(server: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    /// Remove the stored token for `server`. No-op if nothing is stored.
    static func deleteToken(server: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Failures that can occur while writing to the keychain.
enum KeychainError: Error, LocalizedError, Sendable {
    /// The token string could not be UTF-8 encoded.
    case encodingFailed
    /// The Security framework returned an unexpected `OSStatus`.
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode the token for secure storage"
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error \(status)" + (message.map { ": \($0)" } ?? "")
        }
    }
}
