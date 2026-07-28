import Foundation

extension AppStore {
    /// Cheap counts for the header bell badge.
    var unreadNotificationCounts: UnreadNotificationDigest {
        .counts(for: conversations)
    }

    /// Full digest for the header bell dropdown. Built on demand because it
    /// walks unread message tails.
    func makeUnreadNotificationDigest() -> UnreadNotificationDigest {
        UnreadNotificationDigest.make(
            conversations: unreadConversations,
            currentUserID: credentials?.userID,
            unreadMessages: { [self] in unreadMessages(for: $0) },
            resolveUser: { [self] in user(withID: $0) }
        )
    }

    /// Opens the entry's conversation and focuses the message when it is still
    /// in loaded history.
    func openUnreadNotification(_ entry: UnreadNotificationEntry) {
        select(entry.conversationID)
        workspaceSearchFocus = WorkspaceSearchFocus(
            conversationID: entry.conversationID,
            messageID: entry.messageID
        )
    }

    func markAllUnreadsRead() {
        markConversationsRead(unreadConversations.map(\.id))
    }
}
