import Foundation

extension AppStore {
    func searchWorkspaceLocally(
        _ query: String,
        limit: Int = WorkspaceSearchIndex.maximumResultCount
    ) -> [WorkspaceSearchResult] {
        let entities = searchWorkspaceEntities(query, limit: min(20, limit))
        let messages = workspaceSearchIndex.searchMessages(
            query: query,
            limit: max(0, limit - entities.count)
        )
        return WorkspaceSearchIndex.boundedMerge(
            entities: entities,
            content: messages,
            limit: limit
        )
    }

    func searchWorkspaceEntities(
        _ query: String,
        limit: Int = 20
    ) -> [WorkspaceSearchResult] {
        WorkspaceSearchIndex.searchEntities(
            query: query,
            users: users,
            conversations: conversations,
            limit: limit
        )
    }

    func searchWorkspaceHistory(
        _ query: String,
        limit: Int = WorkspaceSearchIndex.maximumResultCount
    ) async throws -> [WorkspaceSearchResult] {
        guard let historyCache else {
            return []
        }
        let session = try? captureWorkspaceSession()
        let hits = try await historyCache.searchMessages(
            query: query,
            limit: limit
        )
        try Task.checkCancellation()
        if let session {
            try requireCurrentWorkspaceSession(session)
        } else {
            guard self.historyCache === historyCache, credentials == nil else {
                return []
            }
        }
        let conversationsByID = Dictionary(
            uniqueKeysWithValues: conversations.map { ($0.id, $0) }
        )
        return hits.compactMap { hit -> WorkspaceSearchResult? in
            guard let conversation = conversationsByID[hit.channelID] else {
                return nil
            }
            return WorkspaceSearchResult(
                id: "local-message-\(hit.channelID)-\(hit.remoteID ?? hit.localID.uuidString)",
                kind: .message,
                source: .local,
                title: "\(hit.author) in \(WorkspaceSearchIndex.conversationLabel(conversation))",
                detail: hit.detail,
                conversationID: hit.channelID,
                userID: nil,
                messageID: hit.localID,
                timestamp: hit.timestamp,
                permalink: nil,
                cacheStableID: hit.stableID
            )
        }
    }

    func searchWorkspaceRemotely(
        _ query: String,
        limit: Int = WorkspaceSearchIndex.maximumResultCount
    ) async throws -> [WorkspaceSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let slackAPI else {
            return []
        }
        let session = try captureWorkspaceSession()
        let credentials = try await activeCredentials(for: session)
        async let messageResults = slackAPI.searchMessages(
            query: query,
            accessToken: credentials.accessToken
        )
        async let fileResults = slackAPI.searchFiles(
            query: query,
            accessToken: credentials.accessToken
        )
        let (messages, files) = try await (messageResults, fileResults)
        try requireCurrentWorkspaceSession(session)
        let boundedLimit = min(
            max(0, limit),
            WorkspaceSearchIndex.maximumResultCount
        )
        guard boundedLimit > 0 else {
            return []
        }
        let fileQuota = min(files.count, max(1, boundedLimit / 4))
        let messageQuota = min(messages.count, boundedLimit - fileQuota)
        var remoteResults = Array(messages.prefix(messageQuota))
        remoteResults.append(contentsOf: files.prefix(boundedLimit - remoteResults.count))
        if remoteResults.count < boundedLimit {
            remoteResults.append(
                contentsOf: messages
                    .dropFirst(messageQuota)
                    .prefix(boundedLimit - remoteResults.count)
            )
        }
        return remoteResults.map { workspaceSearchResult(from: $0) }
    }

    @discardableResult
    func openWorkspaceSearchResult(_ result: WorkspaceSearchResult) -> URL? {
        switch result.kind {
        case .person:
            if let userID = result.userID {
                startDirectMessage(with: userID)
            }
            return nil
        case .channel, .message:
            if let conversationID = result.conversationID,
               conversations.contains(where: { $0.id == conversationID })
            {
                if result.kind == .message, let messageID = result.messageID {
                    openMessage(conversationID: conversationID, messageID: messageID)
                } else {
                    select(conversationID)
                }
                return nil
            }
            return result.permalink
        case .file:
            return result.permalink
        }
    }

    func openWorkspaceSearchResultLoadingMessage(
        _ result: WorkspaceSearchResult
    ) async -> URL? {
        guard result.kind == .message,
              result.source == .local,
              let conversationID = result.conversationID,
              let messageID = result.messageID,
              let stableID = result.cacheStableID,
              let historyCache,
              let conversationIndex = conversations.firstIndex(where: {
                  $0.id == conversationID
              }),
              !conversations[conversationIndex].messages.contains(where: {
                  $0.id == messageID
              })
        else {
            return openWorkspaceSearchResult(result)
        }

        let session = try? captureWorkspaceSession()
        let cachedMessage = try? await historyCache.message(
            channelID: conversationID,
            stableID: stableID
        )
        guard session.map(isCurrentWorkspaceSession)
            ?? (self.historyCache === historyCache && credentials == nil)
        else {
            return nil
        }
        if let cachedMessage,
           let currentIndex = conversations.firstIndex(where: {
               $0.id == conversationID
           }),
           !conversations[currentIndex].messages.contains(where: {
               $0.id == messageID
           })
        {
            let context = SlackMessageFormatting.Context(
                userNames: Dictionary(
                    uniqueKeysWithValues: messageUsers.map {
                        ($0.id, $0.displayName)
                    }
                ),
                channelNames: conversationNamesByID
            )
            conversations[currentIndex].messages.append(
                cachedMessage.preparingForDisplay(context: context)
            )
            conversations[currentIndex].messages.sort {
                $0.timestamp < $1.timestamp
            }
            workspaceSearchIndex.merge(
                messages: [cachedMessage],
                conversation: conversations[currentIndex]
            )
        }
        return openWorkspaceSearchResult(result)
    }

    private func workspaceSearchResult(
        from result: SlackSearchResult
    ) -> WorkspaceSearchResult {
        let kind: WorkspaceSearchResult.Kind = switch result.kind {
        case .message:
            .message
        case .file:
            .file
        }
        let detail: String = if result.kind == .message {
            SlackEmoji.replacingUnicodeShortcodes(
                in: SlackMessageFormatting.render(
                    in: result.detail,
                    context: SlackMessageFormatting.Context(
                        userNames: Dictionary(
                            uniqueKeysWithValues: messageUsers.map {
                                ($0.id, $0.displayName)
                            }
                        ),
                        channelNames: conversationNamesByID
                    )
                )
            )
        } else {
            result.detail
        }
        return WorkspaceSearchResult(
            id: "remote-\(result.id)",
            kind: kind,
            source: .remote,
            title: result.title,
            detail: detail,
            conversationID: result.conversationID,
            userID: nil,
            messageID: nil,
            timestamp: result.timestamp.flatMap(Double.init).map {
                Date(timeIntervalSince1970: $0)
            },
            permalink: result.permalink
        )
    }
}
