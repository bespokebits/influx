import Foundation
import Synchronization
#if canImport(Security)
import Security
#endif

/// Where an account's credentials live: the keychain in the app, shared
/// with the reader's other devices through iCloud Keychain, and
/// memory in tests. Each account keeps one blob, so a connector stores whatever its
/// service needs (tokens, a DPoP key, a client ID) as a single value and
/// replaces it in one write.
public protocol CredentialStore: Sendable {
    func data(for account: String) throws -> Data?
    func setData(_ data: Data, for account: String) throws
    func deleteData(for account: String) throws
    /// Every account with credentials here, in no particular order.
    func accounts() throws -> [String]
}

extension CredentialStore {
    public func load<Value: Decodable>(_ type: Value.Type, for account: String) throws -> Value? {
        try data(for: account).map { try JSONDecoder().decode(Value.self, from: $0) }
    }

    public func save<Value: Encodable>(_ value: Value, for account: String) throws {
        try setData(JSONEncoder().encode(value), for: account)
    }

    public func delete(for account: String) throws {
        try deleteData(for: account)
    }
}

/// A credential store in memory, for tests and previews.
public final class InMemoryCredentialStore: CredentialStore {
    private let blobs = Mutex<[String: Data]>([:])

    public init() {}

    public func data(for account: String) throws -> Data? {
        blobs.withLock { $0[account] }
    }

    public func setData(_ data: Data, for account: String) throws {
        blobs.withLock { $0[account] = data }
    }

    public func deleteData(for account: String) throws {
        _ = blobs.withLock { $0.removeValue(forKey: account) }
    }

    public func accounts() throws -> [String] {
        blobs.withLock { Array($0.keys) }
    }
}

#if canImport(Security)
/// Credentials in the keychain, as generic passwords under one service.
///
/// With `synchronizes` (the app), items go in iCloud Keychain, so an
/// account signed in on one of the reader's devices is signed in on the
/// others: end-to-end encrypted, and readable after the first
/// unlock, so a background refresh can use them. An item from before, kept
/// on this device only, moves to iCloud Keychain the first time it's read.
/// Without it (tests), items stay on this device.
///
/// `syncsAccount` keeps some accounts on this device even then: those whose
/// refresh tokens rotate (Bluesky). A spent refresh token used again
/// is a replay, and the service ends the whole session for it, so two
/// devices sharing one session sign each other out. Each device signs
/// those accounts in by itself instead. An item of theirs an earlier
/// Influx put in iCloud Keychain is claimed by the first device to read it:
/// copied here and deleted from iCloud, so the others sign in afresh.
///
/// It uses the data-protection keychain. A Mac build that isn't signed with
/// a team (local and test builds) isn't allowed
/// to: there, writes fail with `errSecMissingEntitlement` and reads just find
/// nothing. So the store checks once per process which keychain it may use,
/// and then uses only that one, falling back to the login keychain, which is
/// device-only and doesn't sync.
///
/// No query names a keychain access group, so reads, updates and deletes
/// search every group in the app's `keychain-access-groups` entitlement, and
/// a new item goes in the first one: the app's own. The app was
/// `dev.bespokebits.flux` until the rename, and its sign-ins sit in that
/// app's group, which the entitlement lists second, so they keep working
/// where they are (ADR 0032).
public struct KeychainCredentialStore: CredentialStore {
    public struct Failure: Error, Hashable {
        public let status: OSStatus
    }

    public let service: String
    public let synchronizes: Bool
    /// Whether an account's item may go in iCloud Keychain when the store
    /// `synchronizes`.
    public let syncsAccount: @Sendable (String) -> Bool

    /// The service keeps the app's name from before the rename: it is part
    /// of every stored item's key, so a new one would find no sign-ins.
    public init(
        service: String = "dev.bespokebits.flux.credentials", synchronizes: Bool = false,
        syncsAccount: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        self.service = service
        self.synchronizes = synchronizes
        self.syncsAccount = syncsAccount
    }

    /// Whether this process may use the data-protection keychain, found by
    /// adding and removing a throwaway item the first time it's needed.
    private static let dataProtection = Mutex<Bool?>(nil)

    private var usesDataProtection: Bool {
        Self.dataProtection.withLock { known in
            if let known { return known }
            var probe: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "dev.bespokebits.influx.keychain-probe",
                kSecAttrAccount as String: UUID().uuidString,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true,
            ]
            probe[kSecValueData as String] = Data()
            let status = SecItemAdd(probe as CFDictionary, nil)
            probe[kSecValueData as String] = nil
            _ = SecItemDelete(probe as CFDictionary)
            let usable = status != errSecMissingEntitlement
            known = usable
            return usable
        }
    }

    /// Whether items may go in iCloud Keychain at all: only the
    /// data-protection keychain syncs.
    private var syncs: Bool { synchronizes && usesDataProtection }

    /// Whether `account`'s item goes in iCloud Keychain.
    private func syncs(_ account: String) -> Bool { syncs && syncsAccount(account) }

    /// `synchronizable` is true, false, or `kSecAttrSynchronizableAny`.
    private func query(_ account: String, synchronizable: Any) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
        ]
        if usesDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    public func data(for account: String) throws -> Data? {
        let synced = syncs(account)
        if let data = try read(query(account, synchronizable: synced)) { return data }
        if synced {
            guard let local = try read(query(account, synchronizable: false)) else { return nil }
            // Kept on this device by an earlier Influx: move it to iCloud Keychain.
            try? setData(local, for: account)
            return local
        }
        guard syncs, let shared = try read(query(account, synchronizable: true)) else { return nil }
        // Shared by an earlier Influx: claim it for this device. setData
        // also deletes the shared copy, so other devices sign in afresh.
        try setData(shared, for: account)
        return shared
    }

    private func read(_ query: [String: Any]) throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw Failure(status: status)
        }
    }

    public func setData(_ data: Data, for account: String) throws {
        var attributes: [String: Any] = [kSecValueData as String: data]
        if usesDataProtection {
            // The login keychain ignores this.
            attributes[kSecAttrAccessible as String] = syncs(account)
                ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let synced = syncs(account)
        let query = query(account, synchronizable: synced)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
        if synced {
            // A device-only copy from before would be stale from now on.
            _ = SecItemDelete(self.query(account, synchronizable: false) as CFDictionary)
        } else if syncs {
            // A shared copy from before would be stale too, and another
            // device spending it would end this device's session.
            _ = SecItemDelete(self.query(account, synchronizable: true) as CFDictionary)
        }
    }

    /// Deletes the item here and, when it syncs, on the reader's other
    /// devices.
    public func deleteData(for account: String) throws {
        let status = SecItemDelete(query(account, synchronizable: kSecAttrSynchronizableAny) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    /// The accounts of every item under the service, synced or not. Only
    /// attributes are asked for: the keychain can't return every item's
    /// data in one query.
    public func accounts() throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if usesDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? []
            return Array(Set(items.compactMap { $0[kSecAttrAccount as String] as? String }))
        case errSecItemNotFound: return []
        default: throw Failure(status: status)
        }
    }
}
#endif
