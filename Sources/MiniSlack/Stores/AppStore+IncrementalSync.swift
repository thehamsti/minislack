import Foundation

private struct UnreadBootstrapPreparation {
    let readCursor: MessageHistoryReadCursor?
    let shouldBootstrapUnread: Bool
}

extension AppStore {
    func startIncrementalSync() {
        stopIncrementalSync()
        guard case .connected = connectionState,
              slackAPI != nil,
              let session = try? captureWorkspaceSession(),
              IncrementalSyncMode.current != .off
        else {
            return
        }

        notificationService.onOpenConversation = { [weak self] conversationID in
            guard let self,
                  self.conversations.contains(where: { $0.id == conversationID })
            else {
                return
            }
            self.select(conversationID)
        }

        Task { [notificationService] in
            await notificationService.requestAuthorizationIfNeeded()
        }

        incrementalSyncTask = Task { [weak self] in
            guard let self else {
                return
            }
            let syncStartedAt = Date.now
            var scheduler = IncrementalSyncScheduler(startedAt: syncStartedAt)
            var acceleratedConversationIDs = Set<String>()
            var acceleratedConversationCount = 0

            while !Task.isCancelled {
                let mode = IncrementalSyncMode.current
                guard let requestInterval = mode.requestInterval else {
                    return
                }

                let candidates = conversations
                    .filter { !$0.isArchived }
                    .map {
                        IncrementalSyncConversation(
                            id: $0.id,
                            isUnread: $0.isUnread,
                            latestActivity: $0.latestActivity,
                            hasPendingCatchup:
                                incrementalSyncCatchups[$0.id] != nil
                        )
                    }
                let selectedConversationID: String? =
                    if case let .conversation(id) = destination { id } else { nil }

                if let decision = scheduler.nextDecision(
                    now: .now,
                    mode: mode,
                    conversations: candidates,
                    selectedConversationID: selectedConversationID
                ) {
                    if decision.isInitialPoll {
                        acceleratedConversationIDs.insert(
                            decision.conversationID
                        )
                    }
                    let isAccelerated = acceleratedConversationIDs.contains(
                        decision.conversationID
                    )
                    let acceleratedDelay: Duration =
                        acceleratedConversationCount < 10
                            ? .milliseconds(1_250)
                            : .milliseconds(1_500)
                    do {
                        try await pollConversation(
                            decision,
                            detectingMessagesAfter: syncStartedAt,
                            session: session
                        )
                        if isAccelerated,
                           incrementalSyncCatchups[decision.conversationID] == nil
                        {
                            acceleratedConversationIDs.remove(
                                decision.conversationID
                            )
                            acceleratedConversationCount += 1
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        scheduler.recordFailure(
                            for: decision.conversationID
                        )
                    }

                    do {
                        try await Task.sleep(
                            for: isAccelerated
                                ? acceleratedDelay
                                : requestInterval
                        )
                    } catch {
                        return
                    }
                } else {
                    do {
                        try await Task.sleep(for: requestInterval)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    func stopIncrementalSync() {
        incrementalSyncTask?.cancel()
        incrementalSyncTask = nil
    }

    func restartIncrementalSync() {
        stopIncrementalSync()
        startIncrementalSync()
    }

    func isConversationMuted(_ conversationID: String) -> Bool {
        mutedConversationIDs.contains(conversationID)
    }

    func toggleConversationMute(_ conversationID: String) {
        guard conversations.contains(where: { $0.id == conversationID }) else {
            return
        }
        if mutedConversationIDs.remove(conversationID) == nil {
            mutedConversationIDs.insert(conversationID)
        }
        persistConversationMutes()
    }

    func loadConversationMutes(workspaceID: String) {
        mutedConversationIDs = Set(
            UserDefaults.standard.stringArray(
                forKey: conversationMutesKey(workspaceID: workspaceID)
            ) ?? []
        )
    }

    func refreshDockBadge() {
        dockBadgeService.update(
            unreadCount: conversations.reduce(0) {
                $0 + max(0, $1.unreadCount)
            }
        )
    }

    func pollConversation(
        _ decision: IncrementalSyncDecision,
        detectingMessagesAfter syncStartedAt: Date,
        session proposedSession: WorkspaceSession? = nil
    ) async throws {
        let session = try proposedSession ?? captureWorkspaceSession()
        guard isCurrentWorkspaceSession(session),
              let slackAPI,
              let conversationIndex = conversations.firstIndex(where: {
                  $0.id == decision.conversationID
              })
        else {
            return
        }

        let credentials = try await activeCredentials(for: session)
        let existingMessages = conversations[conversationIndex].messages
        let preparation: UnreadBootstrapPreparation
        if incrementalSyncCatchups[decision.conversationID] == nil {
            preparation = try await prepareUnreadBootstrap(
                conversationID: decision.conversationID,
                accessToken: credentials.accessToken,
                session: session
            )
        } else {
            preparation = UnreadBootstrapPreparation(
                readCursor: nil,
                shouldBootstrapUnread: false
            )
        }
        let existingLatestRemoteID = IncrementalMessageDetector.latestRemoteID(
            in: existingMessages
        )
        var catchup = incrementalSyncCatchups[decision.conversationID]
            ?? IncrementalSyncCatchupState(
                oldest: preparation.shouldBootstrapUnread
                    ? preparation.readCursor?.remoteID
                    : existingLatestRemoteID,
                latestKnownTimestamp:
                    IncrementalMessageDetector.latestRemoteTimestamp(
                        in: existingMessages
                    ),
                syncStartedAt: syncStartedAt,
                isInitialPoll:
                    decision.isInitialPoll
                        || preparation.shouldBootstrapUnread,
                existingRemoteIDs: Set(existingMessages.compactMap(\.remoteID)),
                unreadBoundary: preparation.readCursor,
                shouldBootstrapUnread:
                    preparation.shouldBootstrapUnread,
                maximumPageCount:
                    preparation.shouldBootstrapUnread
                        ? 4
                        : (decision.isInitialPoll ? 1 : nil)
            )
        let page = try await slackAPI.fetchMessagePage(
            channelID: decision.conversationID,
            cursor: catchup.nextCursor,
            oldest: catchup.oldest,
            limit: 15,
            accessToken: credentials.accessToken,
            users: messageUsers,
            channelNames: conversationNamesByID,
            currentUserID: credentials.userID
        )
        try Task.checkCancellation()
        try requireCurrentWorkspaceSession(session)
        catchup.merge(page)
        if page.nextCursor != nil, !catchup.reachedPageLimit {
            incrementalSyncCatchups[decision.conversationID] = catchup
            return
        }
        incrementalSyncCatchups[decision.conversationID] = nil
        let messages = catchup.messages
        let historyCache = self.historyCache
        if let historyCache,
           (try? await historyCache.page(
               channelID: decision.conversationID,
               index: 0
           )) != nil
        {
            try? await historyCache.mergeLatest(
                MessageHistoryPage(messages: messages, nextCursor: nil),
                channelID: decision.conversationID
            )
            try requireCurrentWorkspaceSession(session)
        }

        let currentRemoteIDs = Set(
            conversations.first { $0.id == decision.conversationID }?
                .messages.compactMap(\.remoteID) ?? []
        )
        let newMessages = IncrementalMessageDetector.newMessages(
            in: messages,
            excludingRemoteIDs:
                catchup.existingRemoteIDs.union(currentRemoteIDs),
            latestKnownTimestamp: catchup.latestKnownTimestamp,
            syncStartedAt: catchup.syncStartedAt,
            isInitialPoll: catchup.isInitialPoll
        )

        apply(
            messages,
            to: decision.conversationID,
            activityObservedAt: catchup.isInitialPoll ? nil : .now
        )
        guard let updatedIndex = conversations.firstIndex(where: {
            $0.id == decision.conversationID
        }) else {
            return
        }
        if decision.priority != .selected,
           destination != .conversation(decision.conversationID),
           conversations[updatedIndex].messages.count > 200
        {
            conversations[updatedIndex].messages = Array(
                conversations[updatedIndex].messages.suffix(200)
            )
        }
        if let latest = messages.last {
            conversations[updatedIndex].latestActivity = max(
                conversations[updatedIndex].latestActivity,
                latest.timestamp
            )
        }

        let incomingMessages = newMessages.filter {
            !$0.isCurrentUser && $0.authorUserID != credentials.userID
        }
        let isFocused =
            destination == .conversation(decision.conversationID)
            && MainWindowFocus.isFocused
        let shouldMarkRead = isFocused && markReadOnOpen
        let historicalIncomingMessages: [Message]
        if catchup.shouldBootstrapUnread {
            let boundary = catchup.unreadBoundary?.timestamp
            historicalIncomingMessages = messages.filter { message in
                !message.isCurrentUser
                    && message.authorUserID != credentials.userID
                    && message.timestamp <= catchup.syncStartedAt
                    && boundary.map { message.timestamp > $0 } != false
            }
            if shouldMarkRead {
                conversations[updatedIndex].unreadCount = 0
                conversations[updatedIndex].mentionCount = 0
            } else {
                conversations[updatedIndex].unreadCount =
                    historicalIncomingMessages.count
                conversations[updatedIndex].mentionCount =
                    historicalIncomingMessages.count {
                        $0.body.contains("<@\(credentials.userID)>")
                    }
            }
            unreadBaselinedConversationIDs.insert(
                decision.conversationID
            )
        } else {
            historicalIncomingMessages = []
        }

        if !incomingMessages.isEmpty || !historicalIncomingMessages.isEmpty {
            if shouldMarkRead {
                conversations[updatedIndex].unreadCount = 0
                conversations[updatedIndex].mentionCount = 0
                if let timestamp = messages.last?.remoteID {
                    await markLiveConversationRead(
                        channelID: decision.conversationID,
                        timestamp: timestamp,
                        session: session
                    )
                    try requireCurrentWorkspaceSession(session)
                }
            } else {
                conversations[updatedIndex].unreadCount += incomingMessages.count
                conversations[updatedIndex].mentionCount += incomingMessages.count {
                    $0.body.contains("<@\(credentials.userID)>")
                }
            }
        }

        if let latestIncoming = incomingMessages.last {
            let notificationContext = MessageNotificationContext(
                isInitialPoll:
                    catchup.isInitialPoll
                        && latestIncoming.timestamp <= catchup.syncStartedAt,
                isCurrentUserMessage: latestIncoming.isCurrentUser,
                authorUserID: latestIncoming.authorUserID,
                currentUserID: credentials.userID,
                isConversationFocused: isFocused,
                isCurrentUserDoNotDisturb:
                    currentUser?.availability.isDoNotDisturbActive(at: .now) == true,
                isConversationMuted: isConversationMuted(decision.conversationID)
            )
            if MessageNotificationPolicy.shouldNotify(notificationContext) {
                try requireCurrentWorkspaceSession(session)
                let conversation = conversations[updatedIndex]
                await notificationService.deliver(
                    LocalMessageNotification(
                        conversationID: conversation.id,
                        conversationTitle: conversation.kind == .channel
                            ? "#\(conversation.title)"
                            : conversation.title,
                        author: latestIncoming.author,
                        body: latestIncoming.compactPreviewText,
                        messageID: latestIncoming.remoteID ?? latestIncoming.id.uuidString
                    )
                )
                try requireCurrentWorkspaceSession(session)
            }
        }

        refreshDockBadge()
    }

    private func prepareUnreadBootstrap(
        conversationID: String,
        accessToken: String,
        session: WorkspaceSession
    ) async throws -> UnreadBootstrapPreparation {
        guard !unreadBaselinedConversationIDs.contains(conversationID) else {
            return UnreadBootstrapPreparation(
                readCursor: nil,
                shouldBootstrapUnread: false
            )
        }
        guard let currentUserID = credentials?.userID else {
            throw WorkspaceSessionError.changed
        }

        var readCursor = readCursorsByConversationID[conversationID]
        var hasConversationState = readCursor != nil
        if readCursor == nil, let historyCache {
            readCursor = try? await historyCache.readCursor(
                channelID: conversationID
            )
            try requireCurrentWorkspaceSession(session)
            if let readCursor {
                readCursorsByConversationID[conversationID] = readCursor
                hasConversationState = true
            }
        }

        if let slackAPI {
            do {
                let state = try await slackAPI.fetchConversationReadState(
                    channelID: conversationID,
                    accessToken: accessToken
                )
                try requireCurrentWorkspaceSession(session)
                hasConversationState = true
                if let remoteCursor = state.readCursor {
                    readCursor = remoteCursor
                    readCursorsByConversationID[conversationID] =
                        remoteCursor
                    try? await historyCache?.setReadCursor(
                        remoteCursor,
                        channelID: conversationID
                    )
                    try requireCurrentWorkspaceSession(session)
                }
                if let unreadCount = state.unreadCount,
                   let index = conversations.firstIndex(where: {
                       $0.id == conversationID
                   })
                {
                    let reconciliation = UnreadCountReconciliation.reconcile(
                        remoteUnreadCount: max(0, unreadCount),
                        currentUnreadCount: conversations[index].unreadCount,
                        currentMentionCount: conversations[index].mentionCount,
                        messages: conversations[index].messages,
                        readCursor: state.readCursor,
                        currentUserID: currentUserID
                    )
                    conversations[index].unreadCount =
                        reconciliation.unreadCount
                    conversations[index].mentionCount =
                        reconciliation.mentionCount
                    unreadBaselinedConversationIDs.insert(conversationID)
                    refreshDockBadge()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try requireCurrentWorkspaceSession(session)
            }
        }

        return UnreadBootstrapPreparation(
            readCursor: readCursor,
            shouldBootstrapUnread:
                hasConversationState
                    && !unreadBaselinedConversationIDs.contains(conversationID)
        )
    }

    private var markReadOnOpen: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "markReadOnOpen") == nil
            || defaults.bool(forKey: "markReadOnOpen")
    }

    private func persistConversationMutes() {
        guard let workspaceID = credentials?.teamID else {
            return
        }
        UserDefaults.standard.set(
            mutedConversationIDs.sorted(),
            forKey: conversationMutesKey(workspaceID: workspaceID)
        )
    }

    private func conversationMutesKey(workspaceID: String) -> String {
        "mutedConversationIDs.\(workspaceID)"
    }
}
