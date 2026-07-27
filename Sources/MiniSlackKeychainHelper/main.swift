import Foundation
import Security

private enum Operation: String {
    case delete
    case read
    case write
}

private func query(service: String, account: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
}

private func fail(_ status: OSStatus) -> Never {
    FileHandle.standardError.write(Data("\(status)".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4,
      let operation = Operation(rawValue: CommandLine.arguments[1])
else {
    exit(2)
}

let service = CommandLine.arguments[2]
let account = CommandLine.arguments[3]
let itemQuery = query(service: service, account: account)

switch operation {
case .read:
    var readQuery = itemQuery
    readQuery[kSecReturnData as String] = true
    readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
    if status == errSecItemNotFound {
        exit(44)
    }
    guard status == errSecSuccess, let data = result as? Data else {
        fail(status)
    }
    FileHandle.standardOutput.write(data)
case .write:
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let status = SecItemUpdate(
        itemQuery as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
    )
    if status == errSecItemNotFound {
        var addQuery = itemQuery
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            fail(addStatus)
        }
    } else if status != errSecSuccess {
        fail(status)
    }
case .delete:
    let status = SecItemDelete(itemQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        fail(status)
    }
}
