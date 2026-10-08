import Foundation
import Security

/// Small secrets kept in the login Keychain, one per id, never in preferences or the tunnels file.
struct KeychainSecrets: Sendable {
    let service: String
    let label: String

    func secret(for id: UUID) -> String? {
        var query = baseQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func set(_ secret: String, for id: UUID) -> Bool {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(baseQuery(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = baseQuery(id)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = label
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func delete(for id: UUID) {
        SecItemDelete(baseQuery(id) as CFDictionary)
    }

    private func baseQuery(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }
}

/// Passwords for password-protected shares. The service name dates from when the app was called
/// TunnelBar; it stays so existing passwords keep working.
enum SharePasswordStore {
    private static let store = KeychainSecrets(service: "com.tunnelbar.share-password", label: "OpenTraffic share password")

    static func password(for id: UUID) -> String? { store.secret(for: id) }
    @discardableResult
    static func setPassword(_ password: String, for id: UUID) -> Bool { store.set(password, for: id) }
    static func deletePassword(for id: UUID) { store.delete(for: id) }
}

/// Signing secrets of webhook endpoints; the endpoints themselves are kept in preferences.
enum WebhookSecretStore {
    static let store = KeychainSecrets(service: "se.medda.opentraffic.webhook-secret", label: "OpenTraffic webhook secret")
}
