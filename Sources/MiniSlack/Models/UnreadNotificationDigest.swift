import Foundation

/// One unread message the conversation header bell can jump to.
struct UnreadNotificationEntry: Identifiable, Hashable, Sendable {
    let messageID: UUID
    let conversationID: String
    let conversationTitle: String
    let conversationSystemImage: String
    let isDirectMessage: Bool
    let authorDisplayName: String
    let authorInitials: String
    let authorAvatarURL: URL?
    let preview: String
    let timestamp: Date
    let isMention: Bool

    var id: UUID { messageID }
}

/// Bounded snapshot of workspace unreads behind the header bell. Counts stay
/// cheap so the badge can render on every header pass, while `entries` are only
/// built when the dropdown is open.
struct UnreadNotificationDigest: Equatable, Sendable {
    static let maximumEntryCount = 40
    static let maximumEntriesPerConversation = 4
    static let maximumPreviewLength = 160

    var entries: [UnreadNotificationEntry] = []
    var conversationCount = 0
    var messageCount = 0
    var mentionCount = 0

    var isEmpty: Bool {
        messageCount == 0 && conversationCount == 0
    }

    /// Unread messages the bounded entry list could not show.
    var hiddenMessageCount: Int {
        max(0, messageCount - entries.count)
    }

    /// Badge text; caps so a busy workspace cannot stretch the toolbar.
    var badgeLabel: String? {
        guard messageCount > 0 else {
            return nil
        }
        return messageCount > 99 ? "99+" : "\(messageCount)"
    }

    var summary: String {
        guard messageCount > 0 else {
            return "No unread messages"
        }
        var parts = [
            "\(conversationCount) \(conversationCount == 1 ? "conversation" : "conversations")",
            "\(messageCount) unread",
        ]
        if mentionCount > 0 {
            parts.append("\(mentionCount) \(mentionCount == 1 ? "mention" : "mentions")")
        }
        return parts.joined(separator: " · ")
    }

    var accessibilityLabel: String {
        guard messageCount > 0 else {
            return "Unread messages: none"
        }
        return "Unread messages: \(summary)"
    }

    /// Counts only, for the badge.
    static func counts(for conversations: [Conversation]) -> UnreadNotificationDigest {
        let unread = conversations.filter(\.isUnread)
        return UnreadNotificationDigest(
            entries: [],
            conversationCount: unread.count,
            messageCount: unread.reduce(0) { $0 + $1.unreadCount },
            mentionCount: unread.reduce(0) { $0 + $1.mentionCount }
        )
    }

    static func make(
        conversations: [Conversation],
        currentUserID: String?,
        unreadMessages: (Conversation) -> [Message],
        resolveUser: (String) -> WorkspaceUser?
    ) -> UnreadNotificationDigest {
        var digest = counts(for: conversations)
        var entries: [UnreadNotificationEntry] = []

        for conversation in conversations where conversation.isUnread {
            let candidates = unreadMessages(conversation)
                .filter { !$0.isCurrentUser && !$0.isDeleted }
                .suffix(maximumEntriesPerConversation)
            for message in candidates {
                let user = message.authorUserID.flatMap(resolveUser)
                entries.append(
                    UnreadNotificationEntry(
                        messageID: message.id,
                        conversationID: conversation.id,
                        conversationTitle: conversation.title,
                        conversationSystemImage: conversation.systemImage,
                        isDirectMessage: conversation.isDirectMessage,
                        authorDisplayName: user?.displayName ?? message.author,
                        authorInitials: user?.initials ?? message.initials,
                        authorAvatarURL: user?.avatarURL ?? message.authorAvatarURL,
                        preview: previewText(for: message),
                        timestamp: message.timestamp,
                        isMention: message.mentions(userID: currentUserID)
                    )
                )
            }
        }

        digest.entries = Array(
            entries
                .sorted {
                    if $0.isMention != $1.isMention {
                        return $0.isMention
                    }
                    if $0.timestamp != $1.timestamp {
                        return $0.timestamp > $1.timestamp
                    }
                    return $0.messageID.uuidString < $1.messageID.uuidString
                }
                .prefix(maximumEntryCount)
        )
        return digest
    }

    /// Fixed-width age label so notification rows keep their time column
    /// aligned: "now", "12m", "3h", "2d".
    static func shortRelativeLabel(for date: Date, now: Date = .now) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 {
            return "now"
        }
        if elapsed < 3_600 {
            return "\(Int(elapsed / 60))m"
        }
        if elapsed < 86_400 {
            return "\(Int(elapsed / 3_600))h"
        }
        return "\(Int(elapsed / 86_400))d"
    }

    /// Single-line preview so rows keep a predictable height.
    static func previewText(for message: Message) -> String {
        let collapsed = message.compactPreviewText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if collapsed.count <= maximumPreviewLength {
            return collapsed
        }
        return collapsed.prefix(maximumPreviewLength)
            .trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension Message {
    /// Slack encodes mentions as `<@U123>` and broadcasts as `<!here…>`.
    func mentions(userID: String?) -> Bool {
        guard !isCurrentUser, !isDeleted else {
            return false
        }
        if let userID, !userID.isEmpty, body.contains("<@\(userID)>") {
            return true
        }
        return ["<!here", "<!channel", "<!everyone"].contains { body.contains($0) }
    }
}
