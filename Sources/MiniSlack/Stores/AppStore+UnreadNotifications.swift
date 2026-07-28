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
        openMessage(
            conversationID: entry.conversationID,
            messageID: entry.messageID
        )
    }

    /// Marks the conversation read through the entry's message timestamp. Older
    /// unreads clear; newer ones remain. Keeps the notification dropdown usable
    /// for multi-clear without jumping away.
    func markUnreadNotificationRead(_ entry: UnreadNotificationEntry) {
        guard let index = conversations.firstIndex(where: { $0.id == entry.conversationID }),
              conversations[index].isUnread
        else {
            return
        }
        guard let message = conversations[index].messages.first(where: { $0.id == entry.messageID })
        else {
            return
        }
        if let existingCursor = readCursorsByConversationID[entry.conversationID]?.timestamp,
           message.timestamp <= existingCursor
        {
            return
        }

        let remoteTimestamp = message.remoteID
            ?? Self.slackTimestamp(for: message.timestamp)
        let cursor = MessageHistoryReadCursor(
            remoteID: remoteTimestamp,
            timestamp: message.timestamp
        )
        readCursorsByConversationID[entry.conversationID] = cursor

        let remaining = conversations[index].messages.filter { candidate in
            candidate.timestamp > message.timestamp
                && !candidate.isCurrentUser
                && !candidate.isDeleted
        }
        conversations[index].unreadCount = remaining.count
        conversations[index].mentionCount = remaining.count {
            $0.mentions(userID: credentials?.userID)
        }
        refreshDockBadge()
        scheduleWorkspaceStatePersist()

        if let remoteTimestamp, slackAPI != nil {
            startWorkspaceOperation { [weak self] session in
                await self?.markLiveConversationRead(
                    channelID: entry.conversationID,
                    timestamp: remoteTimestamp,
                    session: session
                )
            }
        }
    }

    func markAllUnreadsRead() {
        markConversationsRead(unreadConversations.map(\.id))
    }
}
