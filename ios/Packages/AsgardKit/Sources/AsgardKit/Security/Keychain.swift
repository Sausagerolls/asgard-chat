import Foundation
import Security

/// Stores the session and device keys in the shared keychain so the
/// notification and share extensions can decrypt and send.
public enum Keychain {
    public struct Account: Codable, Sendable, Equatable {
        public var serverURL: URL
        public var token: String
        public var userID: UUID
        public var deviceID: UUID
        public var identityPrivate: Data
        public var signingPrivate: Data

        public init(serverURL: URL, token: String, userID: UUID, deviceID: UUID, identityPrivate: Data, signingPrivate: Data) {
            self.serverURL = serverURL; self.token = token; self.userID = userID; self.deviceID = deviceID
            self.identityPrivate = identityPrivate; self.signingPrivate = signingPrivate
        }

        public func deviceKeys() throws -> DeviceKeys {
            try DeviceKeys(identityRaw: identityPrivate, signingRaw: signingPrivate)
        }
    }

    static let service = "com.giantmushroom.asgardchat.account"

    /// Resolved at runtime from the app's entitlements; nil in tests and previews.
    static var accessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String, !prefix.isEmpty else { return nil }
        return prefix + AppGroup.keychainGroupSuffix
    }

    static func baseQuery() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "primary", kSecUseDataProtectionKeychain as String: true]
        if let group = accessGroup { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    public static func load() -> Account? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    public static func save(_ account: Account) throws {
        let data = try JSONEncoder().encode(account)
        SecItemDelete(baseQuery() as CFDictionary)
        var q = baseQuery()
        q[kSecValueData as String] = data
        // Readable by the Notification Service Extension while the phone is locked.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
        deleteSecret("history")
    }

    // Extra secrets (the history recovery key) stored next to the account.
    static func secretQuery(_ name: String) -> [String: Any] {
        var q = baseQuery()
        q[kSecAttrAccount as String] = name
        return q
    }

    public static func loadSecret(_ name: String) -> Data? {
        var q = secretQuery(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public static func saveSecret(_ data: Data, name: String) {
        SecItemDelete(secretQuery(name) as CFDictionary)
        var q = secretQuery(name)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    public static func deleteSecret(_ name: String) {
        SecItemDelete(secretQuery(name) as CFDictionary)
    }
}

/// Pluggable account persistence (keychain in the app, memory in tests).
public struct AccountStore: Sendable {
    public var load: @Sendable () -> Keychain.Account?
    public var save: @Sendable (Keychain.Account) throws -> Void
    public var delete: @Sendable () -> Void
    public var loadSecret: @Sendable (String) -> Data? = Keychain.loadSecret
    public var saveSecret: @Sendable (Data, String) -> Void = { Keychain.saveSecret($0, name: $1) }
    public var deleteSecret: @Sendable (String) -> Void = Keychain.deleteSecret

    public static let keychain = AccountStore(load: Keychain.load, save: Keychain.save, delete: Keychain.delete)

    public static func memory() -> AccountStore {
        final class Box: @unchecked Sendable { var account: Keychain.Account?; var secrets: [String: Data] = [:] }
        let box = Box()
        return AccountStore(load: { box.account }, save: { box.account = $0 }, delete: { box.account = nil; box.secrets = [:] },
                            loadSecret: { box.secrets[$0] }, saveSecret: { box.secrets[$1] = $0 }, deleteSecret: { box.secrets[$0] = nil })
    }
}
