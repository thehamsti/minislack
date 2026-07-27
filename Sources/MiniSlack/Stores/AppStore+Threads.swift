import Foundation

@MainActor
extension AppStore {
    func prepareThread(
        conversationID: String,
        messageID: UUID
    ) throws -> ThreadIdentifier {
        guard let conversation = conversations.first(where: {
            $0.id == conversationID
        }) else {
            throw MessageActionError.conversationNotFound
        }
        guard let message = conversation.messages.first(where: {
            $0.id == messageID
        }) else {
            throw MessageActionError.messageNotFound
        }
        guard let rootTimestamp = message.thread?.rootTimestamp ?? message.remoteID else {
            throw MessageActionError.messageNotSent
        }
        let identifier = ThreadIdentifier(
            conversationID: conversationID,
            rootTimestamp: rootTimestamp
        )
        if threadStates[identifier] == nil {
            var state = ThreadState(id: identifier, root: message)
            state.isFollowing = message.thread?.isFollowing == true
            threadStates[identifier] = state
        }
        return identifier
    }

    func threadState(for identifier: ThreadIdentifier) -> ThreadState? {
        threadStates[identifier]
    }

    func threadDraft(for identifier: ThreadIdentifier) -> ComposerDraft {
        threadStates[identifier]?.draft ?? ComposerDraft()
    }

    func setThreadDraft(
        _ draft: ComposerDraft,
        for identifier: ThreadIdentifier
    ) {
        threadStates[identifier]?.draft = draft
    }

    func loadThread(
        _ identifier: ThreadIdentifier,
        loadMore: Bool = false
    ) async {
        guard let session = try? captureWorkspaceSession(),
              var state = threadStates[identifier],
              !state.isLoading
        else {
            return
        }
        if loadMore, state.nextCursor == nil {
            return
        }
        state.isLoading = true
        state.errorMessage = nil
        threadStates[identifier] = state

        guard let slackAPI else {
            threadStates[identifier]?.isLoading = false
            return
        }
        do {
            let credentials = try await activeCredentials(for: session)
            let page = try await slackAPI.fetchThreadPage(
                channelID: identifier.conversationID,
                threadTimestamp: identifier.rootTimestamp,
                cursor: loadMore ? state.nextCursor : nil,
                accessToken: credentials.accessToken,
                users: messageUsers,
                channelNames: conversationNamesByID,
                currentUserID: credentials.userID
            )
            guard isCurrentWorkspaceSession(session),
                  threadStates[identifier] != nil
            else {
                return
            }
            threadStates[identifier]?.merge(
                page.messages,
                nextCursor: page.nextCursor
            )
            threadStates[identifier]?.isLoading = false
            updateThreadMetadata(
                identifier,
                from: threadStates[identifier]
            )
            updateThreadActivity(
                identifier,
                from: threadStates[identifier]
            )
        } catch {
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            threadStates[identifier]?.isLoading = false
            threadStates[identifier]?.errorMessage = error.localizedDescription
        }
    }

    func sendThreadDraft(_ identifier: ThreadIdentifier) async {
        guard var state = threadStates[identifier], !state.isSending else {
            return
        }
        let session = slackAPI.flatMap { _ in
            try? captureWorkspaceSession()
        }
        guard slackAPI == nil || session != nil else {
            return
        }
        let draft = state.draft
        let displayText = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let slackText = draft.slackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayText.isEmpty else {
            return
        }
        let currentUser = credentials.flatMap { credentials in
            user(withID: credentials.userID)
        }
        let optimistic = Message(
            author: currentUser?.displayName ?? "You",
            authorUserID: currentUser?.id,
            body: slackText,
            timestamp: .now,
            authorAvatarURL: currentUser?.avatarURL,
            isCurrentUser: true,
            displayBody: SlackEmoji.replacingUnicodeShortcodes(in: displayText),
            deliveryState: slackAPI == nil ? .sent : .sending,
            thread: MessageThreadMetadata(
                rootTimestamp: identifier.rootTimestamp,
                replyCount: 0,
                replyUserIDs: [],
                latestReplyAt: nil,
                isFollowing: state.isFollowing
            )
        )
        state.appendOptimistic(optimistic)
        state.draft = ComposerDraft()
        state.isSending = slackAPI != nil
        threadStates[identifier] = state
        updateThreadMetadata(identifier, from: state)
        updateThreadActivity(identifier, from: state)

        guard let slackAPI else {
            return
        }
        guard let session else {
            return
        }
        do {
            let credentials = try await activeCredentials(for: session)
            let response = try await slackAPI.sendThreadReply(
                channelID: identifier.conversationID,
                threadTimestamp: identifier.rootTimestamp,
                text: slackText,
                accessToken: credentials.accessToken
            )
            try requireCurrentWorkspaceSession(session)
            threadStates[identifier]?.confirm(
                localID: optimistic.id,
                remoteTimestamp: response.timestamp
            )
            confirmSavedMessage(
                conversationID: identifier.conversationID,
                localMessageID: optimistic.id,
                remoteID: response.timestamp
            )
            threadStates[identifier]?.isSending = false
            updateThreadMetadata(identifier, from: threadStates[identifier])
            updateThreadActivity(identifier, from: threadStates[identifier])
        } catch {
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            threadStates[identifier]?.isSending = false
            threadStates[identifier]?.errorMessage = error.localizedDescription
            if let index = threadStates[identifier]?.replies.firstIndex(where: {
                $0.id == optimistic.id
            }) {
                threadStates[identifier]?.replies[index].deliveryState =
                    .failed(error.localizedDescription)
            }
        }
    }

    func updateThreadMetadata(
        _ identifier: ThreadIdentifier,
        from state: ThreadState?
    ) {
        guard let state,
              let conversationIndex = conversations.firstIndex(where: {
                  $0.id == identifier.conversationID
              }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: {
                  $0.remoteID == identifier.rootTimestamp
              })
        else {
            return
        }
        let existing = conversations[conversationIndex].messages[messageIndex].thread
        let visibleReplies = state.replies.filter { !$0.isDeleted }
        var seenParticipants = Set<String>()
        let replyParticipants = visibleReplies.compactMap(\.authorUserID).filter {
            seenParticipants.insert($0).inserted
        }
        conversations[conversationIndex].messages[messageIndex].thread =
            MessageThreadMetadata(
                rootTimestamp: identifier.rootTimestamp,
                replyCount: visibleReplies.count,
                replyUserIDs: replyParticipants,
                latestReplyAt: visibleReplies.last?.timestamp,
                isFollowing: state.isFollowing || existing?.isFollowing == true
            )
    }

    func updateThreadActivity(
        _ identifier: ThreadIdentifier,
        from state: ThreadState?
    ) {
        guard let state,
              let conversation = conversations.first(where: {
                  $0.id == identifier.conversationID
              })
        else {
            return
        }
        activityIndex.merge(
            thread: state,
            conversation: conversation,
            currentUserID: credentials?.userID
        )
    }
}
