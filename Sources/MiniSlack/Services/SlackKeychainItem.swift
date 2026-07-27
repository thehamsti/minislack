import Foundation
import Security

enum SlackKeychainNamespace {
    static let currentService = "com.hamsti.minislack.slack.v2"
    static let legacyServices = [
        "com.hamsti.minislack.slack",
    ]
}

struct SlackKeychainMigration {
    let data: Data?
    let needsMigration: Bool

    static func resolve(current: Data?, legacy: Data?) -> Self {
        if let current {
            return Self(data: current, needsMigration: false)
        }
        return Self(data: legacy, needsMigration: legacy != nil)
    }
}

enum SlackKeychainStoreError: LocalizedError {
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

enum SlackKeychainItem {
    static func read(account: String) throws -> Data? {
        let current = try SlackKeychainHelper.read(
            service: SlackKeychainNamespace.currentService,
            account: account
        )
        var legacyService: String?
        var legacy: Data?
        if current == nil {
            for service in SlackKeychainNamespace.legacyServices {
                if let data = try SlackKeychainHelper.read(
                    service: service,
                    account: account
                ) {
                    legacyService = service
                    legacy = data
                    break
                }
            }
        }
        let migration = SlackKeychainMigration.resolve(current: current, legacy: legacy)

        if migration.needsMigration,
           let data = migration.data,
           let legacyService
        {
            try write(data, account: account)
            try delete(
                service: legacyService,
                account: account
            )
        }
        return migration.data
    }

    static func write(_ data: Data, account: String) throws {
        try SlackKeychainHelper.write(
            data,
            service: SlackKeychainNamespace.currentService,
            account: account
        )
    }

    static func delete(account: String) throws {
        try delete(
            service: SlackKeychainNamespace.currentService,
            account: account
        )
        for service in SlackKeychainNamespace.legacyServices {
            try delete(
                service: service,
                account: account
            )
        }
    }

    private static func delete(service: String, account: String) throws {
        try SlackKeychainHelper.delete(service: service, account: account)
    }
}

private enum SlackKeychainHelper {
    static func read(service: String, account: String) throws -> Data? {
        let result = try run(operation: "read", service: service, account: account)
        if result.status == 44 {
            return nil
        }
        try check(result)
        return result.output
    }

    static func write(_ data: Data, service: String, account: String) throws {
        let result = try run(
            operation: "write",
            service: service,
            account: account,
            input: data
        )
        try check(result)
    }

    static func delete(service: String, account: String) throws {
        let result = try run(operation: "delete", service: service, account: account)
        try check(result)
    }

    private static func run(
        operation: String,
        service: String,
        account: String,
        input: Data? = nil
    ) throws -> (status: Int32, output: Data, error: Data) {
        let helper = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/MiniSlackKeychainHelper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw SlackKeychainStoreError.keychain(errSecUnimplemented)
        }
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = helper
        process.arguments = [operation, service, account]
        process.standardOutput = output
        process.standardError = error

        if let input {
            let standardInput = Pipe()
            process.standardInput = standardInput
            try process.run()
            standardInput.fileHandleForWriting.write(input)
            try standardInput.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        return (
            process.terminationStatus,
            output.fileHandleForReading.readDataToEndOfFile(),
            error.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private static func check(
        _ result: (status: Int32, output: Data, error: Data)
    ) throws {
        guard result.status == 0 else {
            let status = String(data: result.error, encoding: .utf8)
                .flatMap(Int32.init) ?? errSecInternalError
            throw SlackKeychainStoreError.keychain(status)
        }
    }
}
