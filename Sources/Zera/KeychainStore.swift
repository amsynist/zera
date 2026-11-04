import Foundation
import Security

/// The only place Zera keeps secrets (the Anthropic API key, the GitHub token): generic-password
/// items in the login Keychain. Never UserDefaults, never a file, never logged.
enum KeychainStore {
    private static let service = "ai.zera.anthropic"

    enum Account: String {
        // Keychain account names. The stored strings stay as they were: changing them would
        // orphan secrets people have already saved.
        case apiKey = "api-key"
        case github = "github-token"
        var label: String { self == .apiKey ? "Zera — Anthropic API key" : "Zera — GitHub token" }
    }

    private static func query(_ account: Account) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account.rawValue]
    }

    /// Accounts whose item exists but macOS wants your OK before Zera may read it (it was saved by
    /// a differently signed build). Reading them quietly fails instead of popping a password
    /// prompt — a prompt nobody asked for hides the keyboard from every app until answered.
    private(set) static var locked: Set<Account> = []
    private static let lock = NSLock()

    static func isLocked(_ account: Account) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return locked.contains(account)
    }

    /// The secret, or nil. Non-interactive unless you asked for it (`interactive`): then macOS
    /// may show its "allow access" prompt, and "Always Allow" ends the question for good.
    static func read(_ account: Account, interactive: Bool = false) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var out: CFTypeRef?
        // The login keychain is a file keychain, where only this switch reliably stops macOS from
        // showing its "allow access" prompt (the query flag alone isn't always honoured).
        var allowed: DarwinBoolean = true
        if !interactive {
            SecKeychainGetUserInteractionAllowed(&allowed)
            SecKeychainSetUserInteractionAllowed(false)
        }
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if !interactive { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        lock.lock()
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed { locked.insert(account) }
        else if status == errSecSuccess || status == errSecItemNotFound { locked.remove(account) }
        lock.unlock()
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func has(_ account: Account) -> Bool {
        var q = query(account)
        q[kSecReturnData as String] = false
        q[kSecReturnAttributes as String] = true
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
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
