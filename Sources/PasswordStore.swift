import Foundation
import Security

enum ZipPasswordAccount: String, CaseIterable {
    case common = "zip.common"
    case specific = "zip.specific"
}

enum PasswordStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return message ?? "Keychain error \(status)"
        }
    }
}

/// Passwords live in the macOS Keychain, never in `config.json`.
enum PasswordStore {
    private static let service = "com.backuper.app.zip-passwords"

    static func load(_ account: ZipPasswordAccount) -> Result<String?, Error> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return .success(nil)
        }
        guard status == errSecSuccess else {
            return .failure(PasswordStoreError.keychain(status))
        }
        guard let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return .success(nil)
        }
        return .success(password)
    }

    static func save(_ password: String, account: ZipPasswordAccount) -> Result<Void, Error> {
        guard !password.isEmpty else { return delete(account) }

        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            // The password only needs to survive until the user resets it. It
            // is not synced to other Macs through iCloud Keychain.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecParam {
                // The file-based login keychain ignores this attribute on some
                // macOS versions; retry without it rather than losing the password.
                item.removeValue(forKey: kSecAttrAccessible as String)
                status = SecItemAdd(item as CFDictionary, nil)
            }
        }
        guard status == errSecSuccess else {
            return .failure(PasswordStoreError.keychain(status))
        }
        return .success(())
    }

    static func delete(_ account: ZipPasswordAccount) -> Result<Void, Error> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return .failure(PasswordStoreError.keychain(status))
        }
        return .success(())
    }
}
