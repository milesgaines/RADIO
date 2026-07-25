import Foundation
import Security

/// Somewhere to keep a credential that must never sit in plain text on disk.
/// The Navidrome server URL and username are ordinary preferences and live in
/// `UserDefaults`; the password comes from here instead.
public protocol SecretStore: Sendable {
    func secret(forKey key: String) -> String?
    func setSecret(_ value: String, forKey key: String) throws
    func removeSecret(forKey key: String) throws
}

/// Keychain-backed store: one `kSecClassGenericPassword` item per key, all of
/// them namespaced under this app's service name.
public struct KeychainSecretStore: SecretStore {
    public static let shared = KeychainSecretStore()

    /// `kSecAttrService` — namespaces our items inside the app's keychain.
    public let service: String

    public init(service: String = "com.radioplus.credentials") {
        self.service = service
    }

    public enum Failure: Error, LocalizedError {
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String?
                return detail ?? "Keychain error \(status)."
            }
        }
    }

    private func query(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func secret(forKey key: String) -> String? {
        var query = self.query(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let query = self.query(forKey: key)

        // Update in place when the item already exists, add it when it doesn't.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw Failure.keychain(updateStatus) }

        var insert = query
        insert[kSecValueData as String] = data
        // The station reloads its catalog without anyone unlocking the screen,
        // so the item has to outlive a lock — but it must never leave the
        // device, not even in an encrypted backup.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure.keychain(addStatus) }
    }

    public func removeSecret(forKey key: String) throws {
        let status = SecItemDelete(query(forKey: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }
}

/// In-memory stand-in so the credential tests exercise the real
/// `NavidromeConfig` code paths without depending on a keychain the test host
/// may not have (unit-test bundles run unsigned in CI).
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]

    public init(_ storage: [String: String] = [:]) {
        self.storage = storage
    }

    public func secret(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func setSecret(_ value: String, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    public func removeSecret(forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}
