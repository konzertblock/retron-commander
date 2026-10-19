import Foundation
import Security

struct FTPProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var serverAddress: String
    var username: String
    var proxyAddress: String
    var resumeTransfers: Bool
}

enum FTPProfileService {
    private static let storageKey = "ftpProfiles"
    private static let keychainService = "com.konzertblock.RetronCommander.ftp"

    static func load(defaults: UserDefaults = .standard) -> [FTPProfile] {
        guard let data = defaults.data(forKey: storageKey),
              let profiles = try? JSONDecoder().decode([FTPProfile].self, from: data) else { return [] }
        return profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func save(_ profiles: [FTPProfile], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func password(for profile: FTPProfile) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: profile.id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for profile: FTPProfile) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: profile.id.uuidString
        ]
        if password.isEmpty {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw FTPProfileError.keychain(status) }
            return
        }
        let data = Data(password.utf8)
        let updateStatus = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw FTPProfileError.keychain(updateStatus) }
        var item = identity
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw FTPProfileError.keychain(addStatus) }
    }

    static func delete(_ profile: FTPProfile) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: profile.id.uuidString
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw FTPProfileError.keychain(status) }
    }
}

private enum FTPProfileError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        guard case .keychain(let status) = self else { return nil }
        return "Could not save FTP credentials in Keychain (error \(status))."
    }
}
