import Foundation

@MainActor
extension AppStore {
    func showSavedMessages() {
        destination = .savedMessages
    }

    func isMessageSaved(conversationID: String, message: Message) -> Bool {
        savedMessages.contains {
            $0.matches(conversationID: conversationID, message: message)
        }
    }

    func toggleSavedMessage(
        conversationID: String,
        messageID: UUID,
        threadIdentifier: ThreadIdentifier? = nil
    ) throws {
        guard let conversation = conversations.first(where: {
            $0.id == conversationID
        }) else {
            throw MessageActionError.conversationNotFound
        }
        let message = try messageForAction(
            conversationID: conversationID,
            messageID: messageID,
            threadIdentifier: threadIdentifier
        )

        if let index = savedMessages.firstIndex(where: {
            $0.matches(conversationID: conversationID, message: message)
        }) {
            savedMessages.remove(at: index)
        } else {
            savedMessages.insert(
                SavedMessage(
                    conversationID: conversationID,
                    conversationTitle: conversation.title,
                    message: message
                ),
                at: 0
            )
        }
        persistSavedMessages()
    }

    func openSavedMessage(_ savedMessage: SavedMessage) {
        select(savedMessage.conversationID)
    }

    func removeSavedMessage(id: String) {
        savedMessages.removeAll { $0.id == id }
        persistSavedMessages()
    }

    func refreshSavedMessageSnapshots(
        _ messages: [Message],
        conversationID: String
    ) {
        var changed = false
        for message in messages {
            guard let index = savedMessages.firstIndex(where: {
                $0.matches(conversationID: conversationID, message: message)
            }) else {
                continue
            }
            let refreshed = savedMessages[index].replacingMessage(message)
            guard savedMessages[index] != refreshed
            else {
                continue
            }
            savedMessages[index] = refreshed
            changed = true
        }
        if changed {
            persistSavedMessages()
        }
    }

    func confirmSavedMessage(
        conversationID: String,
        localMessageID: UUID,
        remoteID: String
    ) {
        guard let index = savedMessages.firstIndex(where: {
            $0.conversationID == conversationID
                && $0.message.id == localMessageID
        }) else {
            return
        }
        var confirmedMessage = savedMessages[index].message
        confirmedMessage.remoteID = remoteID
        confirmedMessage.deliveryState = .sent
        savedMessages[index] = savedMessages[index].replacingMessage(
            confirmedMessage
        )
        persistSavedMessages()
    }

    func loadSavedMessages(
        for workspaceID: String,
        session: WorkspaceSession
    ) async {
        let store = SavedMessageStore(workspaceID: workspaceID)
        let loadedMessages = (try? await store.load()) ?? []
        guard session.teamID == workspaceID,
              isCurrentWorkspaceSession(session)
        else {
            return
        }
        savedMessageStore = store
        savedMessages = loadedMessages
        savedMessageRevision = 0
    }

    func persistSavedMessages() {
        guard let savedMessageStore else {
            return
        }
        savedMessageRevision += 1
        let revision = savedMessageRevision
        let snapshot = savedMessages
        Task {
            do {
                try await savedMessageStore.save(snapshot, revision: revision)
            } catch {
                transientError = error.localizedDescription
            }
        }
    }
}
