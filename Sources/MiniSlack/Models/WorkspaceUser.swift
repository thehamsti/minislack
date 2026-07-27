import Foundation

struct WorkspaceUser: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let status: String
    let isActive: Bool
    var avatarURL: URL? = nil

    var initials: String {
        displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}
