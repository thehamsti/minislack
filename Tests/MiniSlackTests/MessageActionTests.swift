import Foundation
import Testing
@testable import MiniSlack

@MainActor
struct MessageActionTests {
    @Test
    func ownedMessagesCanBeEditedAndDeletedWithVisibleState() async throws {
        let message = ownedMessage()
        let editStore = store(message: message)

        try await editStore.editMessage(
            conversationID: "C1",
            messageID: message.id,
            text: "Updated :tada:"
        )

        #expect(editStore.selectedConversation?.messages[0].body == "Updated :tada:")
        #expect(editStore.selectedConversation?.messages[0].displayBody == "Updated 🎉")
        #expect(editStore.selectedConversation?.messages[0].editedAt != nil)

        let deleteStore = store(message: message)
        try await deleteStore.deleteMessage(
            conversationID: "C1",
            messageID: message.id
        )

        #expect(deleteStore.selectedConversation?.messages[0].isDeleted == true)
        #expect(
            deleteStore.selectedConversation?.messages[0].displayBody
                == "This message was deleted."
        )
    }

    @Test
    func reactionsToggleAndPinsTrackLocalState() async throws {
        let message = ownedMessage()
        let store = store(message: message)

        try await store.toggleReaction(
            named: "eyes",
            conversationID: "C1",
            messageID: message.id
        )
        #expect(store.selectedConversation?.messages[0].reactions.first?.name == "eyes")
        #expect(
            store.selectedConversation?.messages[0].reactions.first?
                .isCurrentUserIncluded == true
        )

        try await store.toggleReaction(
            named: ":eyes:",
            conversationID: "C1",
            messageID: message.id
        )
        #expect(store.selectedConversation?.messages[0].reactions.isEmpty == true)

        try await store.setMessagePinned(
            true,
            conversationID: "C1",
            messageID: message.id
        )
        #expect(store.selectedConversation?.messages[0].isPinned == true)
    }

    @Test
    func failedPreviewMessagesCanRetryWithoutChangingIdentity() async throws {
        var message = ownedMessage()
        message.remoteID = nil
        message.deliveryState = .failed("Offline")
        let store = store(message: message)

        try await store.retryMessage(
            conversationID: "C1",
            messageID: message.id
        )

        #expect(store.selectedConversation?.messages[0].id == message.id)
        #expect(store.selectedConversation?.messages[0].deliveryState == .sent)
    }

    @Test
    func editingRejectsEmptyOrUnownedMessages() async {
        let owned = ownedMessage()
        let ownedStore = store(message: owned)
        await #expect(throws: MessageActionError.emptyMessage) {
            try await ownedStore.editMessage(
                conversationID: "C1",
                messageID: owned.id,
                text: " \n "
            )
        }

        let remote = Message(
            author: "Maya",
            body: "Remote",
            timestamp: .now,
            remoteID: "101"
        )
        let remoteStore = store(message: remote)
        await #expect(throws: MessageActionError.notMessageOwner) {
            try await remoteStore.deleteMessage(
                conversationID: "C1",
                messageID: remote.id
            )
        }
    }

    @Test
    func threadReplyActionsResolveAndMutateTheReply() async throws {
        let root = Message(
            author: "Maya",
            body: "Root",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100",
            thread: MessageThreadMetadata(
                rootTimestamp: "100",
                replyCount: 1,
                replyUserIDs: ["ME"],
                latestReplyAt: Date(timeIntervalSince1970: 101),
                isFollowing: true
            )
        )
        let reply = Message(
            author: "You",
            authorUserID: "ME",
            body: "Reply",
            timestamp: Date(timeIntervalSince1970: 101),
            remoteID: "101",
            isCurrentUser: true,
            deliveryState: .sent,
            thread: MessageThreadMetadata(
                rootTimestamp: "100",
                replyCount: 0,
                replyUserIDs: [],
                latestReplyAt: nil,
                isFollowing: true
            )
        )
        let store = self.store(message: root)
        let identifier = ThreadIdentifier(
            conversationID: "C1",
            rootTimestamp: "100"
        )
        var thread = ThreadState(id: identifier, root: root)
        thread.replies = [reply]
        thread.isFollowing = true
        store.threadStates[identifier] = thread

        try await store.editMessage(
            conversationID: "C1",
            messageID: reply.id,
            text: "Edited :tada:",
            threadIdentifier: identifier
        )
        try await store.toggleReaction(
            named: "eyes",
            conversationID: "C1",
            messageID: reply.id,
            threadIdentifier: identifier
        )
        try await store.setMessagePinned(
            true,
            conversationID: "C1",
            messageID: reply.id,
            threadIdentifier: identifier
        )
        try store.toggleSavedMessage(
            conversationID: "C1",
            messageID: reply.id,
            threadIdentifier: identifier
        )

        let updated = try #require(store.threadStates[identifier]?.replies.first)
        #expect(updated.body == "Edited :tada:")
        #expect(updated.displayBody == "Edited 🎉")
        #expect(updated.reactions.first?.name == "eyes")
        #expect(updated.isPinned)
        #expect(store.savedMessages.first?.message.id == reply.id)
        #expect(store.selectedConversation?.messages == [root])

        try await store.deleteMessage(
            conversationID: "C1",
            messageID: reply.id,
            threadIdentifier: identifier
        )
        #expect(store.threadStates[identifier]?.replies.first?.isDeleted == true)
        #expect(
            store.threadStates[identifier]?.replies.first?.displayBody
                == "This message was deleted."
        )
        #expect(store.selectedConversation?.messages.first?.thread?.replyCount == 0)
        #expect(store.selectedConversation?.messages.first?.thread?.replyUserIDs.isEmpty == true)
        #expect(
            store.activityItems.contains { $0.threadIdentifier == identifier }
                == false
        )
    }

    private func ownedMessage() -> Message {
        Message(
            author: "You",
            body: "Original",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100.000",
            isCurrentUser: true,
            deliveryState: .sent
        )
    }

    private func store(message: Message) -> AppStore {
        let store = AppStore(conversations: [
            Conversation(
                id: "C1",
                title: "general",
                kind: .channel,
                subtitle: nil,
                isFavorite: false,
                unreadCount: 0,
                mentionCount: 0,
                latestActivity: message.timestamp,
                messages: [message]
            )
        ])
        store.select("C1")
        return store
    }
}
