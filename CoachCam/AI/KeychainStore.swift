import Foundation
import Security

/// Stores the Claude API key in the iPhone Keychain (encrypted, this device only).
/// It is never written to the code, the repo, logs, or UserDefaults.
enum KeychainStore {
    private static let service = "CoachCam"
    private static let account = "anthropic-api-key"

    static func saveAPIKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess { Log.error("Keychain save failed (\(status))") }
        return status == errSecSuccess
    }

    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// e.g. "sk-ant-…a1b2" (for showing that a key is saved, without revealing it).
    static var maskedKey: String? {
        guard let key = loadAPIKey(), key.count > 10 else { return nil }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }
}
