import Foundation
import Security

protocol SlackAppTokenStoring: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

protocol SlackClientIDStoring: Sendable {
    func load() throws -> String?
    func save(_ clientID: String) throws
    func delete() throws
}

struct SlackAppTokenStore: SlackAppTokenStoring, Sendable {
    typealias StoreError = SlackKeychainStoreError

    private let account = "socket-mode-app-token"

    func load() throws -> String? {
        guard let data = try SlackKeychainItem.read(account: account) else {
            return nil
        }
        guard
              let token = String(data: data, encoding: .utf8)
        else {
            throw StoreError.keychain(errSecDecode)
        }
        return token
    }

    func save(_ token: String) throws {
        try SlackKeychainItem.write(Data(token.utf8), account: account)
    }

    func delete() throws {
        try SlackKeychainItem.delete(account: account)
    }
}

struct SlackClientIDStore: SlackClientIDStoring, Sendable {
    private let store = SlackKeychainStringStore(account: "slack-client-id")

    func load() throws -> String? {
        try store.load()
    }

    func save(_ clientID: String) throws {
        try store.save(clientID)
    }

    func delete() throws {
        try store.delete()
    }
}

private struct SlackKeychainStringStore: Sendable {
    let account: String

    func load() throws -> String? {
        guard let data = try SlackKeychainItem.read(account: account) else {
            return nil
        }
        guard
              let value = String(data: data, encoding: .utf8)
        else {
            throw SlackAppTokenStore.StoreError.keychain(errSecDecode)
        }
        return value
    }

    func save(_ value: String) throws {
        try SlackKeychainItem.write(Data(value.utf8), account: account)
    }

    func delete() throws {
        try SlackKeychainItem.delete(account: account)
    }
}
