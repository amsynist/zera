import Foundation
import Security

/// The only place Zera keeps secrets (the Anthropic API key, the GitHub token): generic-password
/// items in the login Keychain. Never UserDefaults, never a file, never logged.
enum KeychainStore {
    private static let service = "ai.zera.anthropic"

    enum Account: String {
        case apiKey = "api-key"
        case githubToken = "github-token"
        var label: String { self == .apiKey ? "Zera — Anthropic API key" : "Zera — GitHub token" }
    }

    private static func query(_ account: Account) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account.rawValue]
    }

    static func read(_ account: Account) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func has(_ account: Account) -> Bool {
        var q = query(account)
        q[kSecReturnData as String] = false
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func write(_ value: String, to account: Account) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let q = query(account)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                    kSecAttrLabel as String: account.label]
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(q.merging(attrs) { a, _ in a } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: Account) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// "sk-ant-…h7Qa" — enough to recognise, never enough to use.
    static func masked(_ key: String) -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count > 12 else { return String(repeating: "•", count: max(4, k.count)) }
        return "\(k.prefix(7))…\(k.suffix(4))"
    }
}
