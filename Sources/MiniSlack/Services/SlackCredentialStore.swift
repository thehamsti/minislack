import Foundation
import Security

protocol SlackCredentialStoring: Sendable {
    func load() throws -> SlackCredentials?
    func loadCollection() throws -> SlackCredentialCollection
    func save(_ credentials: SlackCredentials) throws
    func select(teamID: String) throws -> SlackCredentials
    func delete(teamID: String) throws
}

extension SlackCredentialStoring {
    func delete() throws {
        guard let teamID = try loadCollection().activeWorkspaceID else {
            return
        }
        try delete(teamID: teamID)
    }
}

struct SlackCredentialStore: SlackCredentialStoring, Sendable {
    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case workspaceNotFound

        var errorDescription: String? {
            switch self {
            case let .keychain(status):
                "Keychain operation failed with status \(status)."
            case .workspaceNotFound:
                "That saved Slack workspace is no longer available."
            }
        }
    }

    private let service = "com.hamsti.minislack.slack"
    private let legacyAccount = "slack-oauth"
    private let collectionAccount = "slack-oauth-accounts-v2"

    func load() throws -> SlackCredentials? {
        try loadCollection().activeCredentials
    }

    func loadCollection() throws -> SlackCredentialCollection {
        if let data = try read(account: collectionAccount) {
            return try JSONDecoder().decode(SlackCredentialCollection.self, from: data)
        }
        guard let legacyData = try read(account: legacyAccount) else {
            return SlackCredentialCollection()
        }

        let legacyCredentials = try JSONDecoder().decode(
            SlackCredentials.self,
            from: legacyData
        )
        let collection = SlackCredentialCollection(
            credentials: [legacyCredentials],
            activeWorkspaceID: legacyCredentials.teamID
        )
        try write(collection)
        try deleteItem(account: legacyAccount)
        return collection
    }

    func save(_ credentials: SlackCredentials) throws {
        var collection = try loadCollection()
        collection.upsert(credentials)
        try write(collection)
    }

    func select(teamID: String) throws -> SlackCredentials {
        var collection = try loadCollection()
        guard let credentials = collection.select(teamID) else {
            throw StoreError.workspaceNotFound
        }
        try write(collection)
        return credentials
    }

    func delete(teamID: String) throws {
        var collection = try loadCollection()
        collection.remove(teamID)
        try write(collection)
    }

    private func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw StoreError.keychain(status)
        }
        return data
    }

    private func write(_ collection: SlackCredentialCollection) throws {
        let data = try JSONEncoder().encode(collection)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: collectionAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw StoreError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw StoreError.keychain(status)
        }
    }

    private func deleteItem(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }
}
