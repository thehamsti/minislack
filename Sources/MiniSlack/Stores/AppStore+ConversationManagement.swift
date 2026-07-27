import Foundation

extension AppStore {
    func updateChannelDetails(
        conversationID: String,
        name inputName: String,
        topic inputTopic: String,
        purpose inputPurpose: String
    ) async throws {
        guard var conversation = channel(withID: conversationID) else {
            throw ConversationManagementError.channelNotFound
        }
        let name = Self.normalizedChannelName(inputName)
        guard Self.isValidChannelName(name) else {
            throw ConversationManagementError.invalidChannelName
        }
        let topic = inputTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        let purpose = inputPurpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard topic.count <= 250, purpose.count <= 250 else {
            throw ConversationManagementError.invalidChannelDetails
        }
        guard !conversation.isArchived else {
            throw ConversationManagementError.unavailable(
                "Unarchive this channel before changing its details."
            )
        }

        if let slackAPI {
            let session = try captureWorkspaceSession()
            let credentials = try await activeCredentials(for: session)
            if name != conversation.title {
                do {
                    let renamed = try await slackAPI.renameConversation(
                        channelID: conversation.id,
                        name: name,
                        accessToken: credentials.accessToken
                    )
                    try requireCurrentWorkspaceSession(session)
                    conversation.title = renamed.name ?? name
                    persistManagedChannel(conversation)
                } catch {
                    throw conversationManagementError(error, action: "rename this channel")
                }
            }
            if topic != (conversation.topic ?? "") {
                do {
                    try await slackAPI.setConversationTopic(
                        channelID: conversation.id,
                        topic: topic,
                        accessToken: credentials.accessToken
                    )
                    try requireCurrentWorkspaceSession(session)
                    conversation.topic = topic.nilIfEmpty
                    conversation.subtitle = conversation.topic ?? conversation.purpose
                    persistManagedChannel(conversation)
                } catch {
                    throw conversationManagementError(
                        error,
                        action: "change this channel’s topic"
                    )
                }
            }
            if purpose != (conversation.purpose ?? "") {
                do {
                    try await slackAPI.setConversationPurpose(
                        channelID: conversation.id,
                        purpose: purpose,
                        accessToken: credentials.accessToken
                    )
                    try requireCurrentWorkspaceSession(session)
                    conversation.purpose = purpose.nilIfEmpty
                    conversation.subtitle = conversation.topic ?? conversation.purpose
                    persistManagedChannel(conversation)
                } catch {
                    throw conversationManagementError(
                        error,
                        action: "change this channel’s description"
                    )
                }
            }
        } else {
            conversation.title = name
            conversation.topic = topic.nilIfEmpty
            conversation.purpose = purpose.nilIfEmpty
            conversation.subtitle = conversation.topic ?? conversation.purpose
            persistManagedChannel(conversation)
        }
    }

    func setChannelArchived(
        _ isArchived: Bool,
        conversationID: String
    ) async throws {
        guard var conversation = channel(withID: conversationID) else {
            throw ConversationManagementError.channelNotFound
        }
        guard conversation.isArchived != isArchived else {
            return
        }
        if let slackAPI {
            do {
                let session = try captureWorkspaceSession()
                let credentials = try await activeCredentials(for: session)
                try await slackAPI.setConversationArchived(
                    channelID: conversation.id,
                    isArchived: isArchived,
                    accessToken: credentials.accessToken
                )
                try requireCurrentWorkspaceSession(session)
            } catch {
                throw conversationManagementError(
                    error,
                    action: isArchived ? "archive this channel" : "unarchive this channel"
                )
            }
        }
        conversation.isArchived = isArchived
        persistManagedChannel(conversation)
    }

    func channelMembers(conversationID: String) async throws -> [WorkspaceUser] {
        guard var conversation = channel(withID: conversationID) else {
            throw ConversationManagementError.channelNotFound
        }
        let memberIDs: Set<String>
        if let slackAPI {
            do {
                let session = try captureWorkspaceSession()
                let credentials = try await activeCredentials(for: session)
                memberIDs = Set(
                    try await slackAPI.fetchConversationMemberIDs(
                        channelID: conversation.id,
                        accessToken: credentials.accessToken
                    )
                )
                try requireCurrentWorkspaceSession(session)
            } catch {
                throw conversationManagementError(
                    error,
                    action: "view this channel’s members"
                )
            }
        } else {
            memberIDs = Set(conversation.participants.map(\.id))
                .union(credentials.map { [$0.userID] } ?? [])
        }
        conversation.participants = users.filter { memberIDs.contains($0.id) }
        upsertConversation(conversation)
        return conversation.participants.sorted(by: userNameAscending)
    }

    func updateChannelMembers(
        conversationID: String,
        selectedUserIDs: Set<String>
    ) async throws {
        guard var conversation = channel(withID: conversationID) else {
            throw ConversationManagementError.channelNotFound
        }
        let editableUserIDs = Set(users.map(\.id))
        let currentUserID = credentials?.userID
        var desiredUserIDs = selectedUserIDs.intersection(editableUserIDs)
        if let currentUserID {
            desiredUserIDs.insert(currentUserID)
        }

        var currentUserIDs: Set<String>
        if let slackAPI {
            let session = try captureWorkspaceSession()
            let credentials = try await activeCredentials(for: session)
            do {
                currentUserIDs = Set(
                    try await slackAPI.fetchConversationMemberIDs(
                        channelID: conversation.id,
                        accessToken: credentials.accessToken
                    )
                )
                try requireCurrentWorkspaceSession(session)
            } catch {
                throw conversationManagementError(
                    error,
                    action: "view this channel’s members"
                )
            }

            let additions = desiredUserIDs.subtracting(currentUserIDs).sorted()
            for start in stride(from: 0, to: additions.count, by: 100) {
                let end = min(start + 100, additions.count)
                let chunk = Array(additions[start ..< end])
                do {
                    try await slackAPI.inviteUsers(
                        chunk,
                        to: conversation.id,
                        accessToken: credentials.accessToken
                    )
                    try requireCurrentWorkspaceSession(session)
                    currentUserIDs.formUnion(chunk)
                    conversation.participants = knownUsers(withIDs: currentUserIDs)
                    upsertConversation(conversation)
                } catch {
                    throw conversationManagementError(
                        error,
                        action: "invite people to this channel"
                    )
                }
            }

            let removals = currentUserIDs
                .intersection(editableUserIDs)
                .subtracting(desiredUserIDs)
                .filter { $0 != currentUserID }
                .sorted()
            for userID in removals {
                do {
                    try await slackAPI.removeUser(
                        userID,
                        from: conversation.id,
                        accessToken: credentials.accessToken
                    )
                    try requireCurrentWorkspaceSession(session)
                    currentUserIDs.remove(userID)
                    conversation.participants = knownUsers(withIDs: currentUserIDs)
                    upsertConversation(conversation)
                } catch {
                    throw conversationManagementError(
                        error,
                        action: "remove people from this channel"
                    )
                }
            }
        } else {
            currentUserIDs = desiredUserIDs
            conversation.participants = knownUsers(withIDs: currentUserIDs)
            upsertConversation(conversation)
        }
    }

    func replaceGroupDirectMessageParticipants(
        conversationID: String,
        with userIDs: Set<String>
    ) async throws {
        guard let source = conversations.first(where: {
            $0.id == conversationID && $0.kind == .groupDirectMessage
        }) else {
            throw ConversationManagementError.unavailable(
                "That group message is no longer available."
            )
        }
        let currentUserID = credentials?.userID
        let participantIDs = userIDs.subtracting(currentUserID.map { [$0] } ?? [])
        guard (1 ... 8).contains(participantIDs.count) else {
            throw ConversationManagementError.invalidReplacementGroupSize
        }
        let candidateIDs = Set(groupDirectMessageCandidates.map(\.id))
        guard participantIDs.isSubset(of: candidateIDs) else {
            throw ConversationManagementError.invalidGroupMembers
        }
        if participantIDs == Set(source.participants.map(\.id)) {
            return
        }

        if let existing = existingDirectConversation(for: participantIDs) {
            select(existing.id)
            return
        }

        let orderedIDs = groupDirectMessageCandidates
            .filter { participantIDs.contains($0.id) }
            .map(\.id)
        let selectedUsers = orderedIDs.compactMap { id in
            groupDirectMessageCandidates.first { $0.id == id }
        }
        let conversationID: String
        if let slackAPI {
            do {
                let session = try captureWorkspaceSession()
                let credentials = try await activeCredentials(for: session)
                conversationID = try await slackAPI.openGroupDirectMessage(
                    userIDs: orderedIDs,
                    accessToken: credentials.accessToken
                )
                try requireCurrentWorkspaceSession(session)
            } catch {
                throw conversationManagementError(
                    error,
                    action: "open a conversation with these people"
                )
            }
        } else {
            conversationID = "preview-group-\(UUID().uuidString)"
        }

        let kind: ConversationKind = selectedUsers.count == 1
            ? .directMessage
            : .groupDirectMessage
        var replacement = conversations.first(where: { $0.id == conversationID })
            ?? Conversation(
                id: conversationID,
                title: selectedUsers.map(\.displayName).joined(separator: ", "),
                kind: kind,
                subtitle: selectedUsers.count == 1
                    ? selectedUsers[0].status
                    : "Group DM · \(selectedUsers.count) people",
                isFavorite: false,
                createdAt: .now,
                participantUserID: selectedUsers.count == 1 ? selectedUsers[0].id : nil,
                avatarURL: selectedUsers.count == 1 ? selectedUsers[0].avatarURL : nil,
                participants: selectedUsers,
                unreadCount: 0,
                mentionCount: 0,
                latestActivity: .now,
                messages: []
            )
        replacement.title = selectedUsers.map(\.displayName).joined(separator: ", ")
        replacement.participants = selectedUsers
        upsertConversation(replacement)
        select(replacement.id)
    }

    func hydratePriorityGroupDirectMessages(
        session: WorkspaceSession,
        requestSpacing: Duration = .milliseconds(750)
    ) async {
        guard let slackAPI,
              let credentials = try? await activeCredentials(for: session)
        else {
            return
        }
        let conversationIDs = conversations
            .filter {
                $0.kind == .groupDirectMessage && $0.participants.isEmpty
            }
            .sorted {
                if $0.isUnread != $1.isUnread {
                    return $0.isUnread
                }
                return $0.latestActivity > $1.latestActivity
            }
            .prefix(10)
            .map(\.id)
        let usersByID = Dictionary(
            uniqueKeysWithValues: messageUsers.map { ($0.id, $0) }
        )

        for (offset, conversationID) in conversationIDs.enumerated() {
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            do {
                let memberIDs = try await slackAPI.fetchConversationMemberIDs(
                    channelID: conversationID,
                    accessToken: credentials.accessToken
                )
                try requireCurrentWorkspaceSession(session)
                let participants = memberIDs
                    .filter { $0 != credentials.userID }
                    .compactMap { usersByID[$0] }
                    .sorted(by: userNameAscending)
                guard !participants.isEmpty,
                      let index = conversations.firstIndex(where: {
                          $0.id == conversationID
                      })
                else {
                    continue
                }
                conversations[index].participants = participants
                conversations[index].title = participants
                    .map(\.displayName)
                    .joined(separator: ", ")
                conversations[index].subtitle = "Group DM · \(participants.count) people"
                workspaceSearchIndex.merge(
                    messages: conversations[index].messages,
                    conversation: conversations[index]
                )
            } catch SlackAPIClient.APIError.rateLimited(_) {
                return
            } catch {
                continue
            }

            if offset + 1 < conversationIDs.count {
                try? await Task.sleep(for: requestSpacing)
            }
        }
    }

    private func channel(withID conversationID: String) -> Conversation? {
        conversations.first {
            $0.id == conversationID && $0.kind == .channel
        }
    }

    private func persistManagedChannel(_ conversation: Conversation) {
        upsertConversation(conversation)
        guard !conversation.isPrivate else {
            return
        }
        if conversation.isArchived {
            removePublicChannel(conversation.id)
            return
        }
        let publicChannel = publicChannels.first { $0.id == conversation.id }
        updatePublicChannel(
            SlackPublicChannel(
                id: conversation.id,
                name: conversation.title,
                purpose: conversation.topic ?? conversation.purpose,
                memberCount: publicChannel?.memberCount,
                isMember: publicChannel?.isMember ?? true
            ),
            isMember: publicChannel?.isMember ?? true
        )
    }

    private func knownUsers(withIDs userIDs: Set<String>) -> [WorkspaceUser] {
        users.filter { userIDs.contains($0.id) }.sorted(by: userNameAscending)
    }

    private func existingDirectConversation(
        for participantIDs: Set<String>
    ) -> Conversation? {
        conversations.first { conversation in
            switch conversation.kind {
            case .channel:
                false
            case .directMessage:
                participantIDs.count == 1
                    && conversation.participantUserID == participantIDs.first
            case .groupDirectMessage:
                Set(conversation.participants.map(\.id)) == participantIDs
            }
        }
    }
}

private func userNameAscending(_ lhs: WorkspaceUser, _ rhs: WorkspaceUser) -> Bool {
    lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
}

private func conversationManagementError(
    _ error: Error,
    action: String
) -> Error {
    guard case let SlackAPIClient.APIError.slack(code) = error else {
        return error
    }
    switch code {
    case "missing_scope":
        return ConversationManagementError.reconnectRequired(action)
    case "not_authorized", "no_permission", "restricted_action",
         "user_is_restricted", "access_denied", "no_external_invite_permission":
        return ConversationManagementError.permissionDenied(action)
    case "method_not_supported_for_channel_type", "not_supported":
        return ConversationManagementError.unsupported(action)
    case "not_in_channel":
        return ConversationManagementError.unavailable(
            "Join this channel before trying to \(action)."
        )
    case "is_archived":
        return ConversationManagementError.unavailable(
            "Unarchive this channel before trying to \(action)."
        )
    case "cant_archive_general":
        return ConversationManagementError.unavailable("#general can’t be archived.")
    case "cant_archive_required":
        return ConversationManagementError.unavailable(
            "This workspace requires the channel to stay available."
        )
    case "cant_kick_from_general":
        return ConversationManagementError.unavailable(
            "People can’t be removed from #general."
        )
    case "cant_kick_self":
        return ConversationManagementError.unavailable(
            "Use Leave channel to remove yourself."
        )
    case "invalid_name", "invalid_name_maxlength", "invalid_name_punctuation",
         "invalid_name_required", "invalid_name_specials", "name_taken":
        return ConversationManagementError.invalidChannelName
    case "too_long":
        return ConversationManagementError.invalidChannelDetails
    case "user_not_found", "cant_invite", "cant_invite_self", "org_user_not_in_team":
        return ConversationManagementError.unavailable(
            "Slack couldn’t add or remove one of the selected people."
        )
    default:
        return error
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
