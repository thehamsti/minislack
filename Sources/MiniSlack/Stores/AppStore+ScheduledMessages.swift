import Foundation

extension AppStore {
    func scheduledMessages(for conversationID: String) -> [SlackScheduledMessage] {
        scheduledMessagesState.messages
            .filter { $0.conversationID == conversationID }
            .sorted { $0.postAt < $1.postAt }
    }

    func scheduledMessageDisplayText(_ message: SlackScheduledMessage) -> String {
        let context = SlackMessageFormatting.Context(
            userNames: Dictionary(
                uniqueKeysWithValues: messageUsers.map { ($0.id, $0.displayName) }
            ),
            channelNames: conversationNamesByID
        )
        return SlackEmoji.replacingUnicodeShortcodes(
            in: SlackMessageFormatting.render(in: message.text, context: context)
        )
    }

    func scheduleDraft(at postAt: Date, now: Date = .now) async throws {
        let draft = composerDraft
        let displayText = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let slackText = draft.slackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayText.isEmpty else {
            throw ScheduledMessageError.emptyMessage
        }
        guard case let .conversation(conversationID) = destination,
              conversations.contains(where: { $0.id == conversationID })
        else {
            throw ScheduledMessageError.missingConversation
        }
        guard Self.isValidScheduledDate(postAt, now: now) else {
            throw ScheduledMessageError.invalidDate
        }

        do {
            let scheduledMessage: SlackScheduledMessage
            if let slackAPI {
                let session = try captureWorkspaceSession()
                let credentials = try await activeCredentials(for: session)
                scheduledMessage = try await slackAPI.scheduleMessage(
                    channelID: conversationID,
                    text: slackText,
                    postAt: postAt,
                    accessToken: credentials.accessToken
                )
                try requireCurrentWorkspaceSession(session)
            } else {
                scheduledMessage = SlackScheduledMessage(
                    id: "preview-\(UUID().uuidString)",
                    conversationID: conversationID,
                    text: slackText,
                    postAt: postAt
                )
            }

            scheduledMessagesState.messages.removeAll {
                $0.id == scheduledMessage.id
            }
            scheduledMessagesState.messages.append(scheduledMessage)
            scheduledMessagesState.messages.sort { $0.postAt < $1.postAt }
            scheduledMessagesState.hasLoaded = true
            scheduledMessagesState.errorMessage = nil
            if composerDraft == draft {
                composerDraft = ComposerDraft()
            }
        } catch {
            if error is WorkspaceSessionError {
                throw error
            }
            scheduledMessagesState.errorMessage = error.localizedDescription
            throw error
        }
    }

    func refreshScheduledMessages() async {
        guard let slackAPI else {
            scheduledMessagesState.hasLoaded = true
            scheduledMessagesState.errorMessage = nil
            return
        }
        guard let session = try? captureWorkspaceSession() else {
            return
        }

        scheduledMessagesState.isLoading = true

        do {
            let credentials = try await activeCredentials(for: session)
            var messages: [SlackScheduledMessage] = []
            var cursor: String?
            repeat {
                let page = try await slackAPI.fetchScheduledMessages(
                    cursor: cursor,
                    accessToken: credentials.accessToken
                )
                try requireCurrentWorkspaceSession(session)
                messages.append(contentsOf: page.0)
                cursor = page.1
            } while cursor != nil

            scheduledMessagesState.messages = messages.sorted { $0.postAt < $1.postAt }
            scheduledMessagesState.hasLoaded = true
            scheduledMessagesState.errorMessage = nil
        } catch {
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            scheduledMessagesState.errorMessage = error.localizedDescription
        }
        guard isCurrentWorkspaceSession(session) else {
            return
        }
        scheduledMessagesState.isLoading = false
    }

    func deleteScheduledMessage(_ message: SlackScheduledMessage) async throws {
        guard scheduledMessagesState.messages.contains(where: { $0.id == message.id }) else {
            throw ScheduledMessageError.messageNotFound
        }

        do {
            if let slackAPI {
                let session = try captureWorkspaceSession()
                let credentials = try await activeCredentials(for: session)
                try await slackAPI.deleteScheduledMessage(
                    id: message.id,
                    channelID: message.conversationID,
                    accessToken: credentials.accessToken
                )
                try requireCurrentWorkspaceSession(session)
            }
            scheduledMessagesState.messages.removeAll { $0.id == message.id }
            scheduledMessagesState.errorMessage = nil
        } catch {
            if error is WorkspaceSessionError {
                throw error
            }
            scheduledMessagesState.errorMessage = error.localizedDescription
            throw error
        }
    }

    static func isValidScheduledDate(_ date: Date, now: Date = .now) -> Bool {
        let interval = date.timeIntervalSince(now)
        return interval >= 60 && interval <= 120 * 86_400
    }
}
