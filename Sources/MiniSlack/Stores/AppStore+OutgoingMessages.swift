import Foundation

@MainActor
extension AppStore {
    func sendOutgoingMessage(
        conversationID: String,
        semanticText: String,
        localMessageID: UUID,
        session proposedSession: WorkspaceSession? = nil
    ) async {
        guard let session = proposedSession ?? (try? captureWorkspaceSession()),
              isCurrentWorkspaceSession(session),
              slackAPI != nil,
              let location = try? messageLocation(
                  conversationID: conversationID,
                  messageID: localMessageID
              )
        else {
            return
        }
        let message = conversations[location.conversation].messages[location.message]
        let outgoing = OutgoingMessage(
            id: localMessageID,
            conversationID: conversationID,
            semanticText: semanticText,
            displayText: message.displayBody,
            createdAt: message.timestamp
        )
        let outbox = currentOutgoingMessageOutbox(for: session)
        var trackedOutbox: OutgoingMessageOutbox?

        if let outbox {
            do {
                try await outbox.enqueue(outgoing)
                guard try await outbox.claim(id: outgoing.id) != nil else {
                    return
                }
                guard isCurrentWorkspaceSession(session) else {
                    await outbox.releaseClaim(id: outgoing.id)
                    return
                }
                trackedOutbox = outbox
            } catch {
                guard isCurrentWorkspaceSession(session) else {
                    return
                }
                transientError = "Could not persist the outgoing message: \(error.localizedDescription)"
            }
        }

        do {
            try await transmitOutgoingMessage(
                outgoing,
                outbox: trackedOutbox,
                session: session
            )
        } catch {
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            transientError = error.localizedDescription
            scheduleOutgoingMessageReplay()
        }
    }

    func retryOutgoingMessage(
        conversationID: String,
        messageID: UUID
    ) async throws {
        let location = try messageLocation(
            conversationID: conversationID,
            messageID: messageID
        )
        let message = conversations[location.conversation].messages[location.message]
        guard slackAPI != nil else {
            conversations[location.conversation].messages[location.message].deliveryState = .sent
            return
        }
        let session = try captureWorkspaceSession()

        let outgoing = OutgoingMessage(
            id: message.id,
            conversationID: conversationID,
            semanticText: message.body,
            displayText: message.displayBody,
            createdAt: message.timestamp
        )
        guard let outbox = currentOutgoingMessageOutbox(for: session) else {
            try await transmitOutgoingMessage(
                outgoing,
                outbox: nil,
                session: session
            )
            return
        }

        try await outbox.enqueue(outgoing)
        guard let claimed = try await outbox.claim(id: messageID, force: true) else {
            return
        }
        do {
            try await transmitOutgoingMessage(
                claimed,
                outbox: outbox,
                session: session
            )
        } catch {
            if isCurrentWorkspaceSession(session) {
                scheduleOutgoingMessageReplay()
            }
            throw error
        }
    }

    func restoreOutgoingMessages(for workspaceID: String) async {
        guard let session = try? captureWorkspaceSession(),
              session.teamID == workspaceID
        else {
            return
        }
        let outbox: OutgoingMessageOutbox
        if let existing = outgoingMessageOutbox,
           existing.workspaceID == workspaceID
        {
            outbox = existing
        } else {
            outbox = OutgoingMessageOutbox(workspaceID: workspaceID)
            outgoingMessageOutbox = outbox
        }

        do {
            let outgoingMessages = try await outbox.load()
            try requireCurrentWorkspaceSession(session)
            let currentUser = credentials.flatMap { credentials in
                messageUsers.first { $0.id == credentials.userID }
                    ?? users.first { $0.id == credentials.userID }
            }

            for outgoing in outgoingMessages {
                guard let conversationIndex = conversations.firstIndex(where: {
                    $0.id == outgoing.conversationID
                }) else {
                    continue
                }
                if let messageIndex = conversations[conversationIndex].messages.firstIndex(
                    where: { $0.id == outgoing.id }
                ) {
                    if conversations[conversationIndex].messages[messageIndex].remoteID != nil {
                        try await outbox.complete(id: outgoing.id)
                        try requireCurrentWorkspaceSession(session)
                    } else {
                        conversations[conversationIndex].messages[messageIndex].deliveryState =
                            .failed(deliveryMessage(for: outgoing))
                    }
                    continue
                }

                let message = Message(
                    id: outgoing.id,
                    author: currentUser?.displayName ?? "You",
                    authorUserID: currentUser?.id,
                    body: outgoing.semanticText,
                    timestamp: outgoing.createdAt,
                    authorAvatarURL: currentUser?.avatarURL,
                    isCurrentUser: true,
                    displayBody: outgoing.displayText,
                    deliveryState: .failed(deliveryMessage(for: outgoing))
                )
                conversations[conversationIndex].messages.append(message)
                conversations[conversationIndex].messages.sort {
                    $0.timestamp < $1.timestamp
                }
                conversations[conversationIndex].latestActivity = max(
                    conversations[conversationIndex].latestActivity,
                    outgoing.createdAt
                )
                workspaceSearchIndex.merge(
                    messages: [message],
                    conversation: conversations[conversationIndex]
                )
            }
        } catch {
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            transientError = "Could not restore queued messages: \(error.localizedDescription)"
        }
    }

    func scheduleOutgoingMessageReplay() {
        outgoingMessageReplayTask?.cancel()
        guard case .connected = connectionState,
              let outbox = outgoingMessageOutbox,
              let session = try? captureWorkspaceSession(),
              outbox.workspaceID == session.teamID
        else {
            outgoingMessageReplayTask = nil
            return
        }
        let conversationIDs = Set(conversations.map(\.id))
        outgoingMessageReplayTask = Task { [weak self] in
            do {
                guard let nextDate = try await outbox.nextEligibleDate(
                    allowedConversationIDs: conversationIDs
                ) else {
                    return
                }
                let delay = nextDate.timeIntervalSinceNow
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else {
                    return
                }
                guard let self,
                      self.isCurrentWorkspaceSession(session)
                else {
                    return
                }
                await self.replayQueuedOutgoingMessages(session: session)
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self?.transientError =
                        "Could not replay queued messages: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelOutgoingMessageReplay() {
        outgoingMessageReplayTask?.cancel()
        outgoingMessageReplayTask = nil
    }

    func reconcileOutgoingMessages(_ messages: [Message]) {
        let ids = Set(messages.lazy.filter { $0.remoteID != nil }.map(\.id))
        guard !ids.isEmpty, let outbox = outgoingMessageOutbox else {
            return
        }
        Task {
            try? await outbox.complete(ids: ids)
        }
    }

    private func replayQueuedOutgoingMessages(
        session: WorkspaceSession
    ) async {
        guard case .connected = connectionState,
              isCurrentWorkspaceSession(session),
              let outbox = outgoingMessageOutbox,
              outbox.workspaceID == session.teamID
        else {
            return
        }
        let conversationIDs = Set(conversations.map(\.id))
        while !Task.isCancelled,
              let outgoing = try? await outbox.claimNextReady(
                  allowedConversationIDs: conversationIDs
              )
        {
            do {
                try await transmitOutgoingMessage(
                    outgoing,
                    outbox: outbox,
                    session: session
                )
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                guard isCurrentWorkspaceSession(session) else {
                    await outbox.releaseClaim(id: outgoing.id)
                    return
                }
                if case .retry = OutgoingMessageRetryPolicy.disposition(
                    for: error,
                    retryCount: outgoing.retryCount
                ) {
                    break
                }
            }
        }
        if isCurrentWorkspaceSession(session) {
            scheduleOutgoingMessageReplay()
        }
    }

    private func transmitOutgoingMessage(
        _ outgoing: OutgoingMessage,
        outbox: OutgoingMessageOutbox?,
        session: WorkspaceSession
    ) async throws {
        guard let slackAPI, isCurrentWorkspaceSession(session) else {
            return
        }
        setDeliveryState(
            .sending,
            conversationID: outgoing.conversationID,
            messageID: outgoing.id
        )

        do {
            let credentials = try await activeCredentials(for: session)
            let sent = try await slackAPI.sendMessage(
                channelID: outgoing.conversationID,
                text: outgoing.semanticText,
                clientMessageID: outgoing.id,
                accessToken: credentials.accessToken
            )
            try requireCurrentWorkspaceSession(session)
            setSent(
                remoteID: sent.timestamp,
                conversationID: outgoing.conversationID,
                messageID: outgoing.id
            )
            if let outbox {
                do {
                    try await outbox.complete(id: outgoing.id)
                    try requireCurrentWorkspaceSession(session)
                } catch {
                    guard isCurrentWorkspaceSession(session) else {
                        throw WorkspaceSessionError.changed
                    }
                    transientError =
                        "Message sent, but its outbox record could not be cleared: "
                        + error.localizedDescription
                }
            }
        } catch {
            guard isCurrentWorkspaceSession(session) else {
                await outbox?.releaseClaim(id: outgoing.id)
                throw WorkspaceSessionError.changed
            }
            let disposition = OutgoingMessageRetryPolicy.disposition(
                for: error,
                retryCount: outgoing.retryCount
            )
            try? await outbox?.recordFailure(
                id: outgoing.id,
                errorMessage: error.localizedDescription,
                disposition: disposition
            )
            let prefix = if case .retry = disposition, outbox != nil {
                "Queued to retry"
            } else {
                "Send failed"
            }
            setDeliveryState(
                .failed("\(prefix): \(error.localizedDescription)"),
                conversationID: outgoing.conversationID,
                messageID: outgoing.id
            )
            throw error
        }
    }

    private func currentOutgoingMessageOutbox(
        for session: WorkspaceSession
    ) -> OutgoingMessageOutbox? {
        guard isCurrentWorkspaceSession(session) else {
            return nil
        }
        let workspaceID = session.teamID
        if let outgoingMessageOutbox,
           outgoingMessageOutbox.workspaceID == workspaceID
        {
            return outgoingMessageOutbox
        }
        let outbox = OutgoingMessageOutbox(workspaceID: workspaceID)
        outgoingMessageOutbox = outbox
        return outbox
    }

    private func setDeliveryState(
        _ state: MessageDeliveryState,
        conversationID: String,
        messageID: UUID
    ) {
        guard let location = try? messageLocation(
            conversationID: conversationID,
            messageID: messageID
        ) else {
            return
        }
        conversations[location.conversation].messages[location.message].deliveryState = state
    }

    private func setSent(
        remoteID: String,
        conversationID: String,
        messageID: UUID
    ) {
        guard let location = try? messageLocation(
            conversationID: conversationID,
            messageID: messageID
        ) else {
            return
        }
        conversations[location.conversation].messages[location.message].remoteID = remoteID
        conversations[location.conversation].messages[location.message].deliveryState = .sent
        confirmSavedMessage(
            conversationID: conversationID,
            localMessageID: messageID,
            remoteID: remoteID
        )
    }

    private func deliveryMessage(for outgoing: OutgoingMessage) -> String {
        switch outgoing.state {
        case .queued:
            "Queued to send when Slack reconnects."
        case .waitingToRetry:
            outgoing.lastError.map { "Queued to retry: \($0)" }
                ?? "Queued to retry."
        case .permanentlyFailed:
            outgoing.lastError.map { "Send failed: \($0)" }
                ?? "Send failed. Retry when ready."
        }
    }
}
