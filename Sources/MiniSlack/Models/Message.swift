import Foundation

struct Message: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let author: String
    let authorUserID: String?
    var body: String
    let timestamp: Date
    let authorAvatarURL: URL?
    var remoteID: String?
    let isCurrentUser: Bool
    var displayBody: String
    var richText: MessageRichText?
    let context: MessageRichText?
    let integration: MessageIntegration?
    let attachments: [MessageAttachment]
    let files: [MessageFile]
    let images: [MessageImage]
    let actions: [SlackMessageAction]
    var reactions: [Reaction]
    let emojiUnicode: [String: String]
    var editedAt: Date?
    var isDeleted: Bool
    var deliveryState: MessageDeliveryState
    var thread: MessageThreadMetadata?
    var isPinned: Bool

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
        richText: MessageRichText? = nil,
        context: MessageRichText? = nil,
        integration: MessageIntegration? = nil,
        attachments: [MessageAttachment] = [],
        files: [MessageFile] = [],
        images: [MessageImage] = [],
        actions: [SlackMessageAction] = [],
        reactions: [Reaction] = [],
        emojiUnicode: [String: String] = [:],
        editedAt: Date? = nil,
        isDeleted: Bool = false,
        deliveryState: MessageDeliveryState = .received,
        thread: MessageThreadMetadata? = nil,
        isPinned: Bool = false
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
        self.richText = richText
        self.context = context
        self.integration = integration
        self.attachments = attachments
        self.files = files
        self.images = images
        self.actions = actions
        self.reactions = reactions
        self.emojiUnicode = emojiUnicode
        self.editedAt = editedAt
        self.isDeleted = isDeleted
        self.deliveryState = deliveryState
        self.thread = thread
        self.isPinned = isPinned
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

    var copyText: String {
        let messageText = richText?.plainText ?? displayBody
        if !messageText.isEmpty {
            return messageText
        }
        return (
            attachments.compactMap(\.summary)
                + files.map(\.displayName)
                + images.map(\.altText)
                + actions.map(\.label)
        )
        .joined(separator: "\n")
    }

    var compactPreviewText: String {
        let messageText = richText?.plainText ?? displayBody
        if !messageText.isEmpty {
            return messageText
        }
        if let summary = attachments.lazy.compactMap(\.summary).first {
            return summary
        }
        if let file = files.first {
            return file.displayName
        }
        if let image = images.first {
            return image.altText
        }
        if let action = actions.first {
            return action.label
        }
        return integration.map { "Message from \($0.name)" } ?? "Slack message"
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
            displayBody: isDeleted
                ? displayBody
                : SlackEmoji.replacingUnicodeShortcodes(
                    in: SlackMessageFormatting.render(in: body, context: context),
                    messageEmoji: emojiUnicode
                ),
            richText: richText?.resolving(context: context, messageEmoji: emojiUnicode),
            context: self.context?.resolving(
                context: context,
                messageEmoji: emojiUnicode
            ),
            integration: integration,
            attachments: attachments.map {
                $0.resolving(context: context, messageEmoji: emojiUnicode)
            },
            files: files,
            images: images,
            actions: actions,
            reactions: reactions.map {
                Reaction(
                    name: $0.name,
                    emoji: SlackEmoji.replacingUnicodeShortcodes(
                        in: $0.emoji,
                        messageEmoji: emojiUnicode
                    ),
                    count: $0.count,
                    userIDs: $0.userIDs,
                    isCurrentUserIncluded: $0.isCurrentUserIncluded
                )
            },
            emojiUnicode: emojiUnicode,
            editedAt: editedAt,
            isDeleted: isDeleted,
            deliveryState: deliveryState,
            thread: thread,
            isPinned: isPinned
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
        case richText
        case context
        case integration
        case attachments
        case files
        case images
        case actions
        case reactions
        case emojiUnicode
        case editedAt
        case isDeleted
        case deliveryState
        case thread
        case isPinned
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
        richText = try container.decodeIfPresent(MessageRichText.self, forKey: .richText)
        context = try container.decodeIfPresent(MessageRichText.self, forKey: .context)
        integration = try container.decodeIfPresent(
            MessageIntegration.self,
            forKey: .integration
        )
        attachments = try container.decodeIfPresent(
            [MessageAttachment].self,
            forKey: .attachments
        ) ?? []
        files = try container.decodeIfPresent([MessageFile].self, forKey: .files) ?? []
        images = try container.decodeIfPresent([MessageImage].self, forKey: .images) ?? []
        actions = try container.decodeIfPresent(
            [SlackMessageAction].self,
            forKey: .actions
        ) ?? []
        editedAt = try container.decodeIfPresent(Date.self, forKey: .editedAt)
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        deliveryState = try container.decodeIfPresent(
            MessageDeliveryState.self,
            forKey: .deliveryState
        ) ?? .received
        thread = try container.decodeIfPresent(
            MessageThreadMetadata.self,
            forKey: .thread
        )
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

struct Reaction: Codable, Hashable, Sendable {
    let name: String
    let emoji: String
    var count: Int
    var userIDs: [String]
    var isCurrentUserIncluded: Bool

    init(
        name: String = "",
        emoji: String,
        count: Int,
        userIDs: [String] = [],
        isCurrentUserIncluded: Bool = false
    ) {
        self.name = name
        self.emoji = emoji
        self.count = count
        self.userIDs = userIDs
        self.isCurrentUserIncluded = isCurrentUserIncluded
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case emoji
        case count
        case userIDs
        case isCurrentUserIncluded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try container.decode(String.self, forKey: .emoji)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? emoji.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        count = try container.decode(Int.self, forKey: .count)
        userIDs = try container.decodeIfPresent([String].self, forKey: .userIDs) ?? []
        isCurrentUserIncluded = try container.decodeIfPresent(
            Bool.self,
            forKey: .isCurrentUserIncluded
        ) ?? false
    }

    /// Display names for known reactors, preserving reaction order.
    /// Falls back to the raw user ID when a name cannot be resolved.
    func reactorDisplayNames(resolveName: (String) -> String?) -> [String] {
        userIDs.map { userID in
            let resolved = resolveName(userID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolved, !resolved.isEmpty {
                return resolved
            }
            return userID
        }
    }

    /// Compact hover/accessibility summary, e.g. "Ada and Linus reacted with 👍".
    func hoverSummary(resolveName: (String) -> String?) -> String {
        let names = reactorDisplayNames(resolveName: resolveName)
        if names.isEmpty {
            if count <= 1 {
                return "1 person reacted with \(emoji)"
            }
            return "\(count) people reacted with \(emoji)"
        }

        let joined: String
        switch names.count {
        case 1:
            joined = names[0]
        case 2:
            joined = "\(names[0]) and \(names[1])"
        default:
            let leading = names.dropLast().joined(separator: ", ")
            joined = "\(leading), and \(names[names.count - 1])"
        }
        return "\(joined) reacted with \(emoji)"
    }
}
