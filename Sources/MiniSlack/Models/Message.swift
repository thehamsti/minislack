import Foundation

struct Message: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let author: String
    let authorUserID: String?
    let body: String
    let timestamp: Date
    let authorAvatarURL: URL?
    var remoteID: String?
    let isCurrentUser: Bool
    let displayBody: String
    let reactions: [Reaction]
    let emojiUnicode: [String: String]

    init(
        id: UUID = UUID(),
        author: String,
        authorUserID: String? = nil,
        body: String,
        timestamp: Date,
        authorAvatarURL: URL? = nil,
        remoteID: String? = nil,
        isCurrentUser: Bool = false,
        displayBody: String? = nil,
        reactions: [Reaction] = [],
        emojiUnicode: [String: String] = [:]
    ) {
        self.id = id
        self.author = author
        self.authorUserID = authorUserID
        self.body = body
        self.timestamp = timestamp
        self.authorAvatarURL = authorAvatarURL
        self.remoteID = remoteID
        self.isCurrentUser = isCurrentUser
        self.displayBody = displayBody ?? SlackEmoji.replacingUnicodeShortcodes(
            in: body,
            messageEmoji: emojiUnicode
        )
        self.reactions = reactions
        self.emojiUnicode = emojiUnicode
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

    func preparingForDisplay(context: SlackMessageFormatting.Context) -> Message {
        Message(
            id: id,
            author: author,
            authorUserID: authorUserID,
            body: body,
            timestamp: timestamp,
            authorAvatarURL: authorAvatarURL,
            remoteID: remoteID,
            isCurrentUser: isCurrentUser,
            displayBody: SlackEmoji.replacingUnicodeShortcodes(
                in: SlackMessageFormatting.render(in: body, context: context),
                messageEmoji: emojiUnicode
            ),
            reactions: reactions.map {
                Reaction(
                    emoji: SlackEmoji.replacingUnicodeShortcodes(
                        in: $0.emoji,
                        messageEmoji: emojiUnicode
                    ),
                    count: $0.count
                )
            },
            emojiUnicode: emojiUnicode
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case author
        case authorUserID
        case body
        case timestamp
        case authorAvatarURL
        case remoteID
        case isCurrentUser
        case displayBody
        case reactions
        case emojiUnicode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        author = try container.decode(String.self, forKey: .author)
        authorUserID = try container.decodeIfPresent(String.self, forKey: .authorUserID)
        body = try container.decode(String.self, forKey: .body)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        authorAvatarURL = try container.decodeIfPresent(URL.self, forKey: .authorAvatarURL)
        remoteID = try container.decodeIfPresent(String.self, forKey: .remoteID)
        isCurrentUser = try container.decode(Bool.self, forKey: .isCurrentUser)
        reactions = try container.decode([Reaction].self, forKey: .reactions)
        emojiUnicode = try container.decodeIfPresent(
            [String: String].self,
            forKey: .emojiUnicode
        ) ?? [:]
        displayBody = try container.decodeIfPresent(
            String.self,
            forKey: .displayBody
        ) ?? SlackEmoji.replacingUnicodeShortcodes(
            in: body,
            messageEmoji: emojiUnicode
        )
    }
}

struct Reaction: Codable, Hashable, Sendable {
    let emoji: String
    let count: Int
}
