import Foundation

enum MessageActionError: LocalizedError, Equatable {
    case conversationNotFound
    case messageNotFound
    case messageNotSent
    case notMessageOwner
    case emptyMessage
    case invalidReaction

    var errorDescription: String? {
        switch self {
        case .conversationNotFound:
            "The conversation is no longer available."
        case .messageNotFound:
            "The message is no longer available."
        case .messageNotSent:
            "Wait for the message to finish sending, then try again."
        case .notMessageOwner:
            "Slack only allows you to edit or delete your own messages."
        case .emptyMessage:
            "A message can’t be empty."
        case .invalidReaction:
            "Choose a valid emoji reaction."
        }
    }
}

@MainActor
extension AppStore {
    func editMessage(
        conversationID: String,
        messageID: UUID,
        text: String,
        threadIdentifier: ThreadIdentifier? = nil
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MessageActionError.emptyMessage
        }
        let message = try messageForAction(
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )
        guard message.isCurrentUser else {
            throw MessageActionError.notMessageOwner
        }
        if slackAPI != nil, threadIdentifier == nil {
            try await enqueueEditMutation(
                conversationID: conversationID,
                message: message,
                text: trimmed
            )
            return
        }
        if let slackAPI {
            let session = try captureWorkspaceSession()
            let timestamp = try remoteTimestamp(for: message)
            let credentials = try await activeCredentials(for: session)
            try await slackAPI.updateMessage(
                channelID: conversationID,
                timestamp: timestamp,
                text: trimmed,
                accessToken: credentials.accessToken
            )
            try requireCurrentWorkspaceSession(session)
        }
        try applyEditedMessage(
            message,
            text: trimmed,
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )
    }

    func deleteMessage(
        conversationID: String,
        messageID: UUID,
        threadIdentifier: ThreadIdentifier? = nil
    ) async throws {
        let message = try messageForAction(
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )
        guard message.isCurrentUser else {
            throw MessageActionError.notMessageOwner
        }
        if slackAPI != nil, threadIdentifier == nil {
            try await enqueueDeleteMutation(
                conversationID: conversationID,
                message: message
            )
            return
        }
        if let slackAPI {
            let session = try captureWorkspaceSession()
            let timestamp = try remoteTimestamp(for: message)
            let credentials = try await activeCredentials(for: session)
            try await slackAPI.deleteMessage(
                channelID: conversationID,
                timestamp: timestamp,
                accessToken: credentials.accessToken
            )
            try requireCurrentWorkspaceSession(session)
        }
        try applyDeletedMessage(
            message,
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )
    }

    func toggleReaction(
        named rawName: String,
        conversationID: String,
        messageID: UUID,
        threadIdentifier: ThreadIdentifier? = nil
    ) async throws {
        let name = rawName.trimmingCharacters(
            in: CharacterSet(charactersIn: ":").union(.whitespacesAndNewlines)
        )
        guard !name.isEmpty else {
            throw MessageActionError.invalidReaction
        }
        let message = try messageForAction(
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )
        let reactionIndex = message.reactions.firstIndex { $0.name == name }
        let isRemoving = reactionIndex.map {
            message.reactions[$0].isCurrentUserIncluded
        } == true

        if let slackAPI {
            let session = try captureWorkspaceSession()
            let timestamp = try remoteTimestamp(for: message)
            let credentials = try await activeCredentials(for: session)
            try await slackAPI.setReaction(
                name: name,
                channelID: conversationID,
                timestamp: timestamp,
                isRemoving: isRemoving,
                accessToken: credentials.accessToken
            )
            try requireCurrentWorkspaceSession(session)
        }

        var updated = message
        let currentUserID = credentials?.userID
        if let reactionIndex {
            if isRemoving {
                updated.reactions[reactionIndex].count -= 1
                updated.reactions[reactionIndex].isCurrentUserIncluded = false
                if let currentUserID {
                    updated.reactions[reactionIndex].userIDs.removeAll {
                        $0 == currentUserID
                    }
                }
                if updated.reactions[reactionIndex].count <= 0 {
                    updated.reactions.remove(at: reactionIndex)
                }
            } else {
                updated.reactions[reactionIndex].count += 1
                updated.reactions[reactionIndex].isCurrentUserIncluded = true
                if let currentUserID,
                   !updated.reactions[reactionIndex].userIDs.contains(currentUserID)
                {
                    updated.reactions[reactionIndex].userIDs.append(currentUserID)
                }
            }
        } else {
            updated.reactions.append(
                Reaction(
                    name: name,
                    emoji: SlackEmoji.replacingUnicodeShortcodes(in: ":\(name):"),
                    count: 1,
                    userIDs: currentUserID.map { [$0] } ?? [],
                    isCurrentUserIncluded: true
                )
            )
        }
        try replaceMessageForAction(
            updated,
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )
    }

    func setMessagePinned(
        _ isPinned: Bool,
        conversationID: String,
        messageID: UUID,
        threadIdentifier: ThreadIdentifier? = nil
    ) async throws {
        var message = try messageForAction(
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )
        if let slackAPI {
            let session = try captureWorkspaceSession()
            let timestamp = try remoteTimestamp(for: message)
            let credentials = try await activeCredentials(for: session)
            try await slackAPI.setPinned(
                isPinned,
                channelID: conversationID,
                timestamp: timestamp,
                accessToken: credentials.accessToken
            )
            try requireCurrentWorkspaceSession(session)
        }
        message.isPinned = isPinned
        try replaceMessageForAction(
            message,
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )
    }

    func addMessageReminder(
        conversationID: String,
        messageID: UUID,
        at date: Date,
        threadIdentifier: ThreadIdentifier? = nil
    ) async throws {
        let message = try messageForAction(
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )
        guard let slackAPI else {
            return
        }
        let session = try captureWorkspaceSession()
        let credentials = try await activeCredentials(for: session)
        let permalink = try await slackAPI.permalink(
            channelID: conversationID,
            timestamp: try remoteTimestamp(for: message),
            accessToken: credentials.accessToken
        )
        try await slackAPI.addReminder(
            text: "Follow up on \(permalink.absoluteString)",
            at: date,
            accessToken: credentials.accessToken
        )
        try requireCurrentWorkspaceSession(session)
    }

    func messagePermalink(
        conversationID: String,
        messageID: UUID,
        threadIdentifier: ThreadIdentifier? = nil
    ) async throws -> URL? {
        let message = try messageForAction(
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )
        guard let slackAPI else {
            return nil
        }
        let session = try captureWorkspaceSession()
        let credentials = try await activeCredentials(for: session)
        let permalink = try await slackAPI.permalink(
            channelID: conversationID,
            timestamp: try remoteTimestamp(for: message),
            accessToken: credentials.accessToken
        )
        try requireCurrentWorkspaceSession(session)
        return permalink
    }

    func retryMessage(
        conversationID: String,
        messageID: UUID,
        threadIdentifier: ThreadIdentifier? = nil
    ) async throws {
        var message = try messageForAction(
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )
        guard case .failed = message.deliveryState else {
            return
        }
        if let threadIdentifier {
            guard let slackAPI else {
                message.deliveryState = .sent
                try replaceMessageForAction(
                    message,
                    conversationID: conversationID,
                    messageID: messageID,
                    threadIdentifier: threadIdentifier
                )
                return
            }
            let session = try captureWorkspaceSession()
            let credentials = try await activeCredentials(for: session)
            let sent = try await slackAPI.sendThreadReply(
                channelID: conversationID,
                threadTimestamp: threadIdentifier.rootTimestamp,
                text: message.body,
                accessToken: credentials.accessToken
            )
            try requireCurrentWorkspaceSession(session)
            message.remoteID = sent.timestamp
            message.deliveryState = .sent
            try replaceMessageForAction(
                message,
                conversationID: conversationID,
                messageID: messageID,
                threadIdentifier: threadIdentifier
            )
            return
        }
        try await retryOutgoingMessage(
            conversationID: conversationID,
            messageID: messageID
        )
    }

    func messageLocation(
        conversationID: String,
        messageID: UUID
    ) throws -> (conversation: Int, message: Int) {
        guard let conversationIndex = conversations.firstIndex(where: {
            $0.id == conversationID
        }) else {
            throw MessageActionError.conversationNotFound
        }
        guard let messageIndex = conversations[conversationIndex].messages.firstIndex(where: {
            $0.id == messageID
        }) else {
            throw MessageActionError.messageNotFound
        }
        return (conversationIndex, messageIndex)
    }

    func messageForAction(
        conversationID: String,
        messageID: UUID,
        threadIdentifier: ThreadIdentifier? = nil
    ) throws -> Message {
        if let threadIdentifier,
           threadIdentifier.conversationID == conversationID,
           let thread = threadStates[threadIdentifier]
        {
            if thread.root.id == messageID {
                return thread.root
            }
            if let reply = thread.replies.first(where: { $0.id == messageID }) {
                return reply
            }
        }
        let location = try messageLocation(
            conversationID: conversationID,
            messageID: messageID
        )
        return conversations[location.conversation].messages[location.message]
    }

    func applyEditedMessage(
        _ message: Message,
        text: String,
        conversationID: String,
        messageID: UUID,
        threadIdentifier: ThreadIdentifier?
    ) throws {
        var updated = message
        updated.body = text
        updated.displayBody = SlackEmoji.replacingUnicodeShortcodes(
            in: SlackMessageFormatting.render(
                in: text,
                context: SlackMessageFormatting.Context(
                    userNames: Dictionary(
                        uniqueKeysWithValues: messageUsers.map {
                            ($0.id, $0.displayName)
                        }
                    ),
                    channelNames: conversationNamesByID
                )
            ),
            messageEmoji: updated.emojiUnicode
        )
        updated.richText = nil
        updated.editedAt = .now
        try replaceMessageForAction(
            updated,
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )
    }

    func applyDeletedMessage(
        _ message: Message,
        conversationID: String,
        messageID: UUID,
        threadIdentifier: ThreadIdentifier?
    ) throws {
        var deleted = message
        deleted.body = ""
        deleted.displayBody = "This message was deleted."
        deleted.richText = nil
        deleted.isDeleted = true
        deleted.editedAt = nil
        deleted.reactions = []
        try replaceMessageForAction(
            deleted,
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )
    }

    func replaceMessageForAction(
        _ message: Message,
        conversationID: String,
        messageID: UUID,
        threadIdentifier: ThreadIdentifier?
    ) throws {
        if let threadIdentifier,
           threadIdentifier.conversationID == conversationID,
           var thread = threadStates[threadIdentifier]
        {
            if thread.root.id == messageID {
                thread.root = message
                threadStates[threadIdentifier] = thread
                replaceConversationMessageIfPresent(
                    message,
                    conversationID: conversationID,
                    messageID: messageID
                )
                return
            }
            if let index = thread.replies.firstIndex(where: { $0.id == messageID }) {
                thread.replies[index] = message
                threadStates[threadIdentifier] = thread
                refreshSavedMessageSnapshots(
                    [message],
                    conversationID: conversationID
                )
                updateThreadMetadata(threadIdentifier, from: thread)
                updateThreadActivity(threadIdentifier, from: thread)
                return
            }
        }
        let location = try messageLocation(
            conversationID: conversationID,
            messageID: messageID
        )
        conversations[location.conversation].messages[location.message] = message
        apply([message], to: conversationID)
    }

    private func replaceConversationMessageIfPresent(
        _ message: Message,
        conversationID: String,
        messageID: UUID
    ) {
        guard let conversationIndex = conversations.firstIndex(where: {
            $0.id == conversationID
        }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: {
                  $0.id == messageID
                      || (
                          message.remoteID != nil
                              && $0.remoteID == message.remoteID
                      )
              })
        else {
            refreshSavedMessageSnapshots(
                [message],
                conversationID: conversationID
            )
            return
        }
        conversations[conversationIndex].messages[messageIndex] = message
        apply([message], to: conversationID)
    }

    func remoteTimestamp(for message: Message) throws -> String {
        guard let timestamp = message.remoteID else {
            throw MessageActionError.messageNotSent
        }
        return timestamp
    }
}
