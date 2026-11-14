import Foundation
import Security

struct PairedPhone: Identifiable, Sendable {
    let id: UUID
    let name: String
    let lastSeen: Date?

    var isConnected: Bool {
        guard let lastSeen else { return false }
        let age = Date().timeIntervalSince(lastSeen)
        return age >= 0 && age < 10
    }
}

final class PhoneRegistry {
    private static func aliasKey(for id: UUID) -> String {
        "StatsCompanion.phoneName.\(id.uuidString)"
    }

    private struct Entry {
        var name: String
        var key: Data
        var lastSeen: Date?
        var lastPersisted: Date?
    }

    private let service: String
    private var entries: [UUID: Entry] = [:]

    init(service: String = "com.ishtiaqsyed.StatsCompanion.phone.v2") {
        self.service = service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let idString = item[kSecAttrAccount as String] as? String,
                  let id = UUID(uuidString: idString) else { continue }
            let keyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: idString,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: true
            ]
            var keyResult: CFTypeRef?
            guard SecItemCopyMatching(keyQuery as CFDictionary, &keyResult) == errSecSuccess,
                  let key = keyResult as? Data,
                  key.count == 32 else { continue }
            let name = UserDefaults.standard.string(forKey: Self.aliasKey(for: id))
                ?? (item[kSecAttrLabel as String] as? String ?? "iPhone")
            let lastSeen = UserDefaults.standard.object(forKey: "StatsCompanion.lastSeen.\(id)") as? Date
            entries[id] = Entry(name: name, key: key, lastSeen: lastSeen, lastPersisted: lastSeen)
        }
    }

    func key(for id: UUID) -> Data? { entries[id]?.key }

    func all() -> [PairedPhone] {
        entries.map { PairedPhone(id: $0.key, name: $0.value.name, lastSeen: $0.value.lastSeen) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func enroll(name: String, key: Data) -> UUID? {
        guard key.count == 32 else { return nil }
        let id = UUID()
        let values: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrLabel as String: name,
            kSecValueData as String: key
        ]
        guard SecItemAdd(values as CFDictionary, nil) == errSecSuccess else { return nil }
        entries[id] = Entry(name: name, key: key, lastSeen: nil, lastPersisted: nil)
        return id
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var entry = entries[id], !trimmed.isEmpty, trimmed.count <= 60 else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.aliasKey(for: id))
        entry.name = trimmed
        entries[id] = entry
    }

    func recordActivity(for id: UUID) {
        guard var entry = entries[id] else { return }
        let now = Date()
        entry.lastSeen = now
        if entry.lastPersisted == nil || now.timeIntervalSince(entry.lastPersisted!) > 30 {
            UserDefaults.standard.set(now, forKey: "StatsCompanion.lastSeen.\(id)")
            entry.lastPersisted = now
        }
        entries[id] = entry
    }

    @discardableResult
    func revoke(_ id: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return false }
        UserDefaults.standard.removeObject(forKey: "StatsCompanion.lastSeen.\(id)")
        UserDefaults.standard.removeObject(forKey: Self.aliasKey(for: id))
        entries.removeValue(forKey: id)
        return true
    }
}
