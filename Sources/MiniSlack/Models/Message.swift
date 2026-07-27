import Foundation

struct Message: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let author: String
    let body: String
    let timestamp: Date
    let authorAvatarURL: URL?
    var remoteID: String?
    let isCurrentUser: Bool
    let reactions: [Reaction]

    init(
        id: UUID = UUID(),
        author: String,
        body: String,
        timestamp: Date,
        authorAvatarURL: URL? = nil,
        remoteID: String? = nil,
        isCurrentUser: Bool = false,
        reactions: [Reaction] = []
    ) {
        self.id = id
        self.author = author
        self.body = body
        self.timestamp = timestamp
        self.authorAvatarURL = authorAvatarURL
        self.remoteID = remoteID
        self.isCurrentUser = isCurrentUser
        self.reactions = reactions
    }

    var initials: String {
        author
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

struct Reaction: Codable, Hashable, Sendable {
    let emoji: String
    let count: Int
}
