import Foundation
import OmakeyProtocol
import os
import Security

/// Paired computers, with their pairing keys, as one JSON item in the
/// Keychain. `ThisDeviceOnly` and not synchronizable: the keys never leave
/// this phone (no iCloud Keychain, no restore onto another device).
@MainActor
final class HostStore {
    private static let service = "com.gladimdim.omakey.hosts"
    private static let account = "paired"
    private static let installedKey = "installed"
    private static let log = Logger(subsystem: "com.gladimdim.omakey", category: "hosts")

    private var cache: [HostRecord]?

    /// Keychain items outlive deleting the app. Android loses its pairings
    /// on uninstall, and so do we: a fresh install (no marker in
    /// UserDefaults, which deleting the app clears) starts with none.
    static func wipeIfFreshInstall(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: installedKey) else { return }
        SecItemDelete(baseQuery() as CFDictionary)
        defaults.set(true, forKey: installedKey)
    }

    /// Most recently used first.
    func all() -> [HostRecord] {
        if let cache { return cache }
        var q = Self.baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        var list: [HostRecord] = []
        if status == errSecSuccess, let data = out as? Data {
            list = (try? JSONDecoder().decode([HostRecord].self, from: data)) ?? []
        } else if status != errSecItemNotFound {
            Self.log.error("can't read the pairings: \(status)")
        }
        cache = list
        return list
    }

    func get(_ hostId: String) -> HostRecord? { all().first { $0.hostId == hostId } }

    /// Adds or replaces the computer with the same id (re-pairing), first in line.
    func put(_ host: HostRecord) { save([host] + all().filter { $0.hostId != host.hostId }) }

    func remove(_ hostId: String) { save(all().filter { $0.hostId != hostId }) }

    /// Remember the address that answered, first in line for next time.
    func rememberAddress(_ hostId: String, _ address: String) {
        let list = all()
        guard let h = list.first(where: { $0.hostId == hostId }), h.addresses.first != address else { return }
        save(list.map { h in
            guard h.hostId == hostId else { return h }
            var c = h
            c.addresses = Array(([address] + h.addresses.filter { $0 != address }).prefix(6))
            return c
        })
    }

    private func save(_ hosts: [HostRecord]) {
        cache = hosts
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        let q = Self.baseQuery()
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        // Kept in memory for this run either way; only a broken Keychain loses them at exit.
        if status != errSecSuccess { Self.log.error("can't save the pairings: \(status)") }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
