import Foundation

enum SlackAppSetupError: LocalizedError, Equatable {
    case invalidClientID
    case invalidAppToken

    var errorDescription: String? {
        switch self {
        case .invalidClientID:
            "Enter the Client ID from your Slack app's Basic Information page."
        case .invalidAppToken:
            "Enter an app-level token beginning with xapp-."
        }
    }
}

@MainActor
extension AppStore {
    func startSocketMode() {
        stopSocketMode()
        guard case .connected = connectionState,
              let appTokenStore,
              let socketModeClient,
              let session = try? captureWorkspaceSession()
        else {
            socketModeState = .notConfigured
            return
        }
        let appToken: String
        do {
            guard let storedToken = try appTokenStore.load(), !storedToken.isEmpty else {
                socketModeState = .notConfigured
                return
            }
            appToken = storedToken
        } catch {
            socketModeState = .reconnecting(error.localizedDescription)
            return
        }

        socketModeState = .connecting
        socketModeTask = Task { [weak self] in
            var retryDelay: Duration = .seconds(1)
            while !Task.isCancelled {
                guard let self, self.isCurrentWorkspaceSession(session) else {
                    return
                }
                do {
                    let events = socketModeClient.events(appToken: appToken)
                    retryDelay = .seconds(1)
                    for try await event in events {
                        try Task.checkCancellation()
                        guard self.isCurrentWorkspaceSession(session) else {
                            return
                        }
                        await self.applySocketModeEvent(event, session: session)
                    }
                    throw SlackSocketModeClient.ClientError.disconnected(
                        "connection_closed"
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isCurrentWorkspaceSession(session) else {
                        return
                    }
                    self.socketModeState = .reconnecting(error.localizedDescription)
                    do {
                        try await Task.sleep(for: retryDelay)
                    } catch {
                        return
                    }
                    retryDelay = min(retryDelay * 2, .seconds(30))
                    self.socketModeState = .connecting
                }
            }
        }
    }

    func stopSocketMode() {
        socketModeTask?.cancel()
        socketModeTask = nil
        socketModeState = .notConfigured
    }

    func restartSocketMode() {
        stopSocketMode()
        startSocketMode()
    }

    private func applySocketModeEvent(
        _ event: SlackSocketModeEvent,
        session: WorkspaceSession
    ) async {
        switch event {
        case .connected:
            socketModeState = .connected
        case let .message(teamID, channelID, dto):
            guard teamID == session.teamID else {
                return
            }
            await applyRealtimeMessage(dto, channelID: channelID, session: session)
        case let .messageDeleted(teamID, channelID, timestamp):
            guard teamID == session.teamID else {
                return
            }
            await applyRealtimeDeletion(
                timestamp: timestamp,
                channelID: channelID,
                session: session
            )
        }
    }

    private func applyRealtimeMessage(
        _ dto: SlackMessageDTO,
        channelID: String,
        session: WorkspaceSession
    ) async {
        guard let credentials,
              let conversationIndex = conversations.firstIndex(where: {
                  $0.id == channelID
              })
        else {
            return
        }
        let message = dto.message(
            users: Dictionary(
                uniqueKeysWithValues: messageUsers.map { ($0.id, $0) }
            ),
            currentUserID: credentials.userID,
            formattingContext: SlackMessageFormatting.Context(
                userNames: Dictionary(
                    uniqueKeysWithValues: messageUsers.map {
                        ($0.id, $0.displayName)
                    }
                ),
                channelNames: conversationNamesByID
            )
        )

        if let rootTimestamp = dto.threadTimestamp,
           rootTimestamp != dto.timestamp
        {
            let identifier = ThreadIdentifier(
                conversationID: channelID,
                rootTimestamp: rootTimestamp
            )
            if threadStates[identifier] != nil {
                threadStates[identifier]?.merge([message], nextCursor: nil)
                updateThreadMetadata(identifier, from: threadStates[identifier])
                updateThreadActivity(identifier, from: threadStates[identifier])
            }
            return
        }

        let isNew = !conversations[conversationIndex].messages.contains {
            $0.remoteID == message.remoteID
        }
        apply([message], to: channelID, activityObservedAt: isNew ? .now : nil)
        guard let updatedIndex = conversations.firstIndex(where: {
            $0.id == channelID
        }) else {
            return
        }
        conversations[updatedIndex].latestActivity = max(
            conversations[updatedIndex].latestActivity,
            message.timestamp
        )
        if let historyCache {
            try? await historyCache.mergeLatest(
                MessageHistoryPage(messages: [message], nextCursor: nil),
                channelID: channelID
            )
            guard isCurrentWorkspaceSession(session) else {
                return
            }
        }

        guard isNew,
              !message.isCurrentUser,
              message.authorUserID != credentials.userID
        else {
            return
        }
        let isFocused =
            destination == .conversation(channelID) && MainWindowFocus.isFocused
        let defaults = UserDefaults.standard
        let markReadOnOpen =
            defaults.object(forKey: "markReadOnOpen") == nil
                || defaults.bool(forKey: "markReadOnOpen")
        if isFocused && markReadOnOpen {
            conversations[updatedIndex].unreadCount = 0
            conversations[updatedIndex].mentionCount = 0
            await markLiveConversationRead(
                channelID: channelID,
                timestamp: dto.timestamp,
                session: session
            )
            guard isCurrentWorkspaceSession(session) else {
                return
            }
        } else {
            conversations[updatedIndex].unreadCount += 1
            if message.body.contains("<@\(credentials.userID)>") {
                conversations[updatedIndex].mentionCount += 1
            }
        }

        let context = MessageNotificationContext(
            isInitialPoll: false,
            isCurrentUserMessage: false,
            authorUserID: message.authorUserID,
            currentUserID: credentials.userID,
            isConversationFocused: isFocused,
            isCurrentUserDoNotDisturb:
                currentUser?.availability.isDoNotDisturbActive(at: .now) == true,
            isConversationMuted: isConversationMuted(channelID)
        )
        if MessageNotificationPolicy.shouldNotify(context) {
            let conversation = conversations[updatedIndex]
            await notificationService.deliver(
                LocalMessageNotification(
                    conversationID: channelID,
                    conversationTitle: conversation.kind == .channel
                        ? "#\(conversation.title)"
                        : conversation.title,
                    author: message.author,
                    body: message.compactPreviewText,
                    messageID: dto.timestamp
                )
            )
        }
        refreshDockBadge()
    }

    private func applyRealtimeDeletion(
        timestamp: String,
        channelID: String,
        session: WorkspaceSession
    ) async {
        var deletedMessage: Message?
        if let conversationIndex = conversations.firstIndex(where: {
            $0.id == channelID
        }), let messageIndex = conversations[conversationIndex].messages.firstIndex(
            where: { $0.remoteID == timestamp }
        ) {
            var message = conversations[conversationIndex].messages[messageIndex]
            message.body = ""
            message.displayBody = "This message was deleted."
            message.richText = nil
            message.isDeleted = true
            deletedMessage = message
            apply([message], to: channelID, activityObservedAt: .now)
        }

        for identifier in threadStates.keys where identifier.conversationID == channelID {
            if threadStates[identifier]?.root.remoteID == timestamp {
                threadStates[identifier]?.root.body = ""
                threadStates[identifier]?.root.displayBody = "This message was deleted."
                threadStates[identifier]?.root.richText = nil
                threadStates[identifier]?.root.isDeleted = true
            }
            if let index = threadStates[identifier]?.replies.firstIndex(where: {
                $0.remoteID == timestamp
            }) {
                threadStates[identifier]?.replies[index].body = ""
                threadStates[identifier]?.replies[index].displayBody =
                    "This message was deleted."
                threadStates[identifier]?.replies[index].richText = nil
                threadStates[identifier]?.replies[index].isDeleted = true
                deletedMessage = threadStates[identifier]?.replies[index]
                updateThreadMetadata(identifier, from: threadStates[identifier])
                updateThreadActivity(identifier, from: threadStates[identifier])
            }
        }
        if let deletedMessage, let historyCache {
            try? await historyCache.mergeLatest(
                MessageHistoryPage(messages: [deletedMessage], nextCursor: nil),
                channelID: channelID
            )
            guard isCurrentWorkspaceSession(session) else {
                return
            }
        }
    }
}
