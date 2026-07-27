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
    typealias StoreError = SlackKeychainStoreError

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
        try SlackKeychainItem.read(account: account)
    }

    private func write(_ collection: SlackCredentialCollection) throws {
        let data = try JSONEncoder().encode(collection)
        try SlackKeychainItem.write(data, account: collectionAccount)
    }

    private func deleteItem(account: String) throws {
        try SlackKeychainItem.delete(account: account)
    }
}
