import Foundation

enum MessageMutationError: LocalizedError, Equatable {
    case conflict
    case messageUnavailable

    var errorDescription: String? {
        switch self {
        case .conflict:
            "The message changed in Slack. Review it before retrying your change."
        case .messageUnavailable:
            "Load the message before retrying this change."
        }
    }
}

@MainActor
extension AppStore {
    func enqueueEditMutation(
        conversationID: String,
        message: Message,
        text: String
    ) async throws {
        try await enqueueMessageMutation(
            MessageMutation(
                messageID: message.id,
                target: MessageMutationTarget(
                    conversationID: conversationID,
                    remoteTimestamp: try remoteTimestamp(for: message)
                ),
                baseVersion: MessageMutationVersion(message: message),
                operation: .edit(text: text)
            )
        )
    }

    func enqueueDeleteMutation(
        conversationID: String,
        message: Message
    ) async throws {
        try await enqueueMessageMutation(
            MessageMutation(
                messageID: message.id,
                target: MessageMutationTarget(
                    conversationID: conversationID,
                    remoteTimestamp: try remoteTimestamp(for: message)
                ),
                baseVersion: MessageMutationVersion(message: message),
                operation: .delete
            )
        )
    }

    func restoreMessageMutations(for workspaceID: String) async {
        guard let session = try? captureWorkspaceSession(),
              session.teamID == workspaceID
        else {
            return
        }
        let queue: MessageMutationQueue
        if let existing = messageMutationQueue,
           existing.workspaceID == workspaceID
        {
            queue = existing
        } else {
            queue = MessageMutationQueue(workspaceID: workspaceID)
            messageMutationQueue = queue
        }

        do {
            let mutations = try await queue.load()
            try requireCurrentWorkspaceSession(session)
            messageMutationsByTarget = Dictionary(
                uniqueKeysWithValues: mutations.map { ($0.target, $0) }
            )
            await reconcileRestoredMessageMutations(
                mutations,
                queue: queue,
                session: session
            )
        } catch {
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            transientError =
                "Could not restore queued message changes: \(error.localizedDescription)"
        }
    }

    func scheduleMessageMutationReplay() {
        messageMutationReplayTask?.cancel()
        guard case .connected = connectionState,
              let queue = messageMutationQueue,
              let session = try? captureWorkspaceSession(),
              queue.workspaceID == session.teamID
        else {
            messageMutationReplayTask = nil
            return
        }
        let availableTargets = availableMessageMutationTargets
        messageMutationReplayTask = Task { [weak self] in
            do {
                guard let nextDate = try await queue.nextEligibleDate(
                    availableTargets: availableTargets
                ) else {
                    return
                }
                let delay = nextDate.timeIntervalSinceNow
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled,
                      let self,
                      self.isCurrentWorkspaceSession(session)
                else {
                    return
                }
                await self.replayQueuedMessageMutations(session: session)
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self?.transientError =
                        "Could not replay queued message changes: "
                        + error.localizedDescription
                }
            }
        }
    }

    func cancelMessageMutationReplay() {
        messageMutationReplayTask?.cancel()
        messageMutationReplayTask = nil
    }

    func messageMutationDisplayState(
        conversationID: String,
        message: Message,
        threadIdentifier: ThreadIdentifier?
    ) -> MessageMutationDisplayState? {
        guard threadIdentifier == nil,
              let remoteTimestamp = message.remoteID,
              let mutation = messageMutationsByTarget[
                  MessageMutationTarget(
                      conversationID: conversationID,
                      remoteTimestamp: remoteTimestamp
                  )
              ]
        else {
            return nil
        }
        let action = mutation.operation.actionName
        switch mutation.state {
        case .queued, .waitingToRetry:
            return .pending(action: action)
        case .permanentlyFailed:
            return .failed(
                action: action,
                message: mutation.lastError ?? "\(action) failed."
            )
        case .conflict:
            return .conflict(
                action: action,
                message: mutation.lastError
                    ?? "The message changed in Slack. Review it before retrying."
            )
        }
    }

    func retryMessageMutation(
        conversationID: String,
        messageID: UUID
    ) async throws {
        let message = try messageForAction(
            conversationID: conversationID,
            messageID: messageID
        )
        let target = MessageMutationTarget(
            conversationID: conversationID,
            remoteTimestamp: try remoteTimestamp(for: message)
        )
        guard let mutation = messageMutationsByTarget[target],
              let session = try? captureWorkspaceSession(),
              let queue = currentMessageMutationQueue(for: session)
        else {
            return
        }

        let claimed: MessageMutation?
        if mutation.state == .conflict {
            claimed = try await queue.rebaseAndClaim(
                id: mutation.id,
                baseVersion: MessageMutationVersion(message: message)
            )
        } else {
            claimed = try await queue.claim(id: mutation.id, force: true)
        }
        guard let claimed else {
            return
        }
        messageMutationsByTarget[target] = claimed
        do {
            try await transmitMessageMutation(
                claimed,
                queue: queue,
                session: session,
                validatesServerVersion: true
            )
        } catch {
            if isCurrentWorkspaceSession(session) {
                scheduleMessageMutationReplay()
            }
            throw error
        }
    }

    func reconcileMessageMutations(
        _ messages: [Message],
        conversationID: String
    ) {
        guard let queue = messageMutationQueue,
              let session = try? captureWorkspaceSession(),
              queue.workspaceID == session.teamID
        else {
            return
        }
        let matches = messages.compactMap { message -> (MessageMutation, Message)? in
            guard let remoteTimestamp = message.remoteID,
                  let mutation = messageMutationsByTarget[
                      MessageMutationTarget(
                          conversationID: conversationID,
                          remoteTimestamp: remoteTimestamp
                      )
                  ]
            else {
                return nil
            }
            return (mutation, message)
        }
        guard !matches.isEmpty else {
            return
        }
        let hasReplayableMutation = matches.contains { mutation, message in
            !isMutationApplied(mutation, to: message)
                && MessageMutationVersion(message: message) == mutation.baseVersion
                && mutation.state != .permanentlyFailed
                && mutation.state != .conflict
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            for (mutation, message) in matches {
                guard self.isCurrentWorkspaceSession(session) else {
                    return
                }
                if self.isMutationApplied(mutation, to: message) {
                    try? await queue.complete(id: mutation.id)
                    guard self.isCurrentWorkspaceSession(session) else {
                        return
                    }
                    self.messageMutationsByTarget[mutation.target] = nil
                } else if MessageMutationVersion(message: message) != mutation.baseVersion {
                    await self.recordMessageMutationConflict(
                        mutation,
                        queue: queue,
                        session: session
                    )
                }
            }
        }
        if hasReplayableMutation {
            scheduleMessageMutationReplay()
        }
    }

    private func enqueueMessageMutation(
        _ mutation: MessageMutation
    ) async throws {
        let session = try captureWorkspaceSession()
        guard let queue = currentMessageMutationQueue(for: session) else {
            throw WorkspaceSessionError.changed
        }
        try await queue.enqueue(mutation)
        try requireCurrentWorkspaceSession(session)
        messageMutationsByTarget[mutation.target] = mutation
        guard let claimed = try await queue.claim(id: mutation.id) else {
            return
        }
        do {
            try await transmitMessageMutation(
                claimed,
                queue: queue,
                session: session,
                validatesServerVersion: false
            )
        } catch {
            if isCurrentWorkspaceSession(session) {
                scheduleMessageMutationReplay()
            }
            throw error
        }
    }

    private func replayQueuedMessageMutations(
        session: WorkspaceSession
    ) async {
        guard case .connected = connectionState,
              isCurrentWorkspaceSession(session),
              let queue = messageMutationQueue,
              queue.workspaceID == session.teamID
        else {
            return
        }

        while !Task.isCancelled,
              let mutation = try? await queue.claimNextReady(
                  availableTargets: availableMessageMutationTargets
              )
        {
            do {
                try await transmitMessageMutation(
                    mutation,
                    queue: queue,
                    session: session,
                    validatesServerVersion: true
                )
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                guard isCurrentWorkspaceSession(session) else {
                    await queue.releaseClaim(id: mutation.id)
                    return
                }
                if case .retry = OutgoingMessageRetryPolicy.disposition(
                    for: error,
                    retryCount: mutation.retryCount
                ) {
                    break
                }
            }
        }
        if isCurrentWorkspaceSession(session) {
            scheduleMessageMutationReplay()
        }
    }

    private func transmitMessageMutation(
        _ mutation: MessageMutation,
        queue: MessageMutationQueue,
        session: WorkspaceSession,
        validatesServerVersion: Bool
    ) async throws {
        guard let slackAPI,
              isCurrentWorkspaceSession(session),
              queue.workspaceID == session.teamID
        else {
            await queue.releaseClaim(id: mutation.id)
            throw WorkspaceSessionError.changed
        }
        guard let message = rootMessage(for: mutation.target) else {
            await queue.releaseClaim(id: mutation.id)
            throw MessageMutationError.messageUnavailable
        }

        if isMutationApplied(mutation, to: message) {
            try await completeMessageMutation(
                mutation,
                queue: queue,
                session: session
            )
            return
        }
        guard MessageMutationVersion(message: message) == mutation.baseVersion else {
            await recordMessageMutationConflict(
                mutation,
                queue: queue,
                session: session
            )
            throw MessageMutationError.conflict
        }

        do {
            let credentials = try await activeCredentials(for: session)
            if validatesServerVersion {
                let page = try await slackAPI.fetchMessagePage(
                    channelID: mutation.target.conversationID,
                    oldest: mutation.target.remoteTimestamp,
                    latest: mutation.target.remoteTimestamp,
                    limit: 1,
                    accessToken: credentials.accessToken,
                    users: messageUsers,
                    channelNames: conversationNamesByID,
                    currentUserID: credentials.userID
                )
                try requireCurrentWorkspaceSession(session)
                guard let remoteMessage = page.messages.first(where: {
                    $0.remoteID == mutation.target.remoteTimestamp
                }) else {
                    if mutation.operation == .delete {
                        try await completeMessageMutation(
                            mutation,
                            queue: queue,
                            session: session
                        )
                        try applyCompletedMessageMutation(mutation, to: message)
                        return
                    }
                    await recordMessageMutationConflict(
                        mutation,
                        queue: queue,
                        session: session
                    )
                    throw MessageMutationError.conflict
                }
                if isMutationApplied(mutation, to: remoteMessage) {
                    try await completeMessageMutation(
                        mutation,
                        queue: queue,
                        session: session
                    )
                    apply(
                        [remoteMessage],
                        to: mutation.target.conversationID
                    )
                    return
                }
                guard MessageMutationVersion(message: remoteMessage)
                    == mutation.baseVersion
                else {
                    await recordMessageMutationConflict(
                        mutation,
                        queue: queue,
                        session: session
                    )
                    apply(
                        [remoteMessage],
                        to: mutation.target.conversationID
                    )
                    throw MessageMutationError.conflict
                }
            }
            switch mutation.operation {
            case let .edit(text):
                try await slackAPI.updateMessage(
                    channelID: mutation.target.conversationID,
                    timestamp: mutation.target.remoteTimestamp,
                    text: text,
                    accessToken: credentials.accessToken
                )
            case .delete:
                try await slackAPI.deleteMessage(
                    channelID: mutation.target.conversationID,
                    timestamp: mutation.target.remoteTimestamp,
                    accessToken: credentials.accessToken
                )
            }
            try requireCurrentWorkspaceSession(session)
            try await completeMessageMutation(
                mutation,
                queue: queue,
                session: session
            )
            try applyCompletedMessageMutation(mutation, to: message)
        } catch {
            guard isCurrentWorkspaceSession(session) else {
                await queue.releaseClaim(id: mutation.id)
                throw WorkspaceSessionError.changed
            }
            if isIdempotentDeleteCompletion(mutation: mutation, error: error) {
                try await completeMessageMutation(
                    mutation,
                    queue: queue,
                    session: session
                )
                try applyCompletedMessageMutation(mutation, to: message)
                return
            }
            if let mutationError = error as? MessageMutationError,
               mutationError == .conflict
            {
                throw error
            }
            let disposition = OutgoingMessageRetryPolicy.disposition(
                for: error,
                retryCount: mutation.retryCount
            )
            do {
                try await queue.recordFailure(
                    id: mutation.id,
                    errorMessage: error.localizedDescription,
                    disposition: disposition
                )
                try requireCurrentWorkspaceSession(session)
                await refreshMessageMutation(mutation.id, from: queue)
            } catch {
                transientError =
                    "The message change is queued, but its retry state could not be saved: "
                    + error.localizedDescription
            }
            throw error
        }
    }

    private func completeMessageMutation(
        _ mutation: MessageMutation,
        queue: MessageMutationQueue,
        session: WorkspaceSession
    ) async throws {
        try await queue.complete(id: mutation.id)
        try requireCurrentWorkspaceSession(session)
        messageMutationsByTarget[mutation.target] = nil
    }

    private func applyCompletedMessageMutation(
        _ mutation: MessageMutation,
        to message: Message
    ) throws {
        switch mutation.operation {
        case let .edit(text):
            try applyEditedMessage(
                message,
                text: text,
                conversationID: mutation.target.conversationID,
                messageID: message.id,
                threadIdentifier: nil
            )
        case .delete:
            try applyDeletedMessage(
                message,
                conversationID: mutation.target.conversationID,
                messageID: message.id,
                threadIdentifier: nil
            )
        }
    }

    private func reconcileRestoredMessageMutations(
        _ mutations: [MessageMutation],
        queue: MessageMutationQueue,
        session: WorkspaceSession
    ) async {
        for mutation in mutations {
            guard isCurrentWorkspaceSession(session),
                  let message = rootMessage(for: mutation.target)
            else {
                continue
            }
            if isMutationApplied(mutation, to: message) {
                try? await queue.complete(id: mutation.id)
                guard isCurrentWorkspaceSession(session) else {
                    return
                }
                messageMutationsByTarget[mutation.target] = nil
            } else if MessageMutationVersion(message: message) != mutation.baseVersion {
                await recordMessageMutationConflict(
                    mutation,
                    queue: queue,
                    session: session
                )
            }
        }
    }

    private func recordMessageMutationConflict(
        _ mutation: MessageMutation,
        queue: MessageMutationQueue,
        session: WorkspaceSession
    ) async {
        let message = "The message changed in Slack. Review it before retrying."
        do {
            try await queue.recordConflict(id: mutation.id, message: message)
            try requireCurrentWorkspaceSession(session)
            await refreshMessageMutation(mutation.id, from: queue)
        } catch {
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            transientError =
                "Could not save the message edit conflict: \(error.localizedDescription)"
        }
    }

    private func refreshMessageMutation(
        _ id: UUID,
        from queue: MessageMutationQueue
    ) async {
        guard let mutation = try? await queue.load().first(where: { $0.id == id }),
              queue.workspaceID == credentials?.teamID
        else {
            return
        }
        messageMutationsByTarget[mutation.target] = mutation
    }

    private func rootMessage(for target: MessageMutationTarget) -> Message? {
        conversations.first(where: { $0.id == target.conversationID })?
            .messages.first(where: { $0.remoteID == target.remoteTimestamp })
    }

    private var availableMessageMutationTargets: Set<MessageMutationTarget> {
        Set(messageMutationsByTarget.keys.filter { rootMessage(for: $0) != nil })
    }

    private func isMutationApplied(
        _ mutation: MessageMutation,
        to message: Message
    ) -> Bool {
        switch mutation.operation {
        case let .edit(text):
            !message.isDeleted && message.body == text
        case .delete:
            message.isDeleted
        }
    }

    private func isIdempotentDeleteCompletion(
        mutation: MessageMutation,
        error: any Error
    ) -> Bool {
        guard mutation.operation == .delete,
              case let SlackAPIClient.APIError.slack(code) = error
        else {
            return false
        }
        return code == "message_not_found"
    }

    private func currentMessageMutationQueue(
        for session: WorkspaceSession
    ) -> MessageMutationQueue? {
        guard isCurrentWorkspaceSession(session) else {
            return nil
        }
        if let messageMutationQueue,
           messageMutationQueue.workspaceID == session.teamID
        {
            return messageMutationQueue
        }
        let queue = MessageMutationQueue(workspaceID: session.teamID)
        messageMutationQueue = queue
        return queue
    }
}
