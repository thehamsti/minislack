import Foundation
import Testing
@testable import MiniSlack

struct SavedMessageTests {
    @Test
    func savedMessagesPersistPerWorkspaceInNewestFirstOrder() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let store = SavedMessageStore(workspaceID: "T1", rootURL: rootURL)
        let older = savedMessage(remoteID: "100", savedAt: Date(timeIntervalSince1970: 100))
        let newer = savedMessage(remoteID: "200", savedAt: Date(timeIntervalSince1970: 200))

        try await store.save([older, newer])

        #expect(try await store.load().map(\.id) == [newer.id, older.id])
        #expect(
            try await SavedMessageStore(workspaceID: "T2", rootURL: rootURL)
                .load()
                .isEmpty
        )

        try await store.save([newer], revision: 2)
        try await store.save([older], revision: 1)
        #expect(try await store.load().map(\.id) == [newer.id])
    }

    @Test @MainActor
    func appStoreTogglesAStableSavedMessageRecord() throws {
        let message = Message(
            author: "Maya",
            body: "Remember this",
            timestamp: .now,
            remoteID: "123.456"
        )
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

        try store.toggleSavedMessage(
            conversationID: "C1",
            messageID: message.id
        )
        #expect(store.savedMessages.count == 1)
        #expect(store.isMessageSaved(conversationID: "C1", message: message))

        try store.toggleSavedMessage(
            conversationID: "C1",
            messageID: message.id
        )
        #expect(store.savedMessages.isEmpty)
    }

    @Test @MainActor
    func savedOptimisticMessageMigratesWhenSlackConfirmsIt() throws {
        let localID = UUID()
        let optimistic = Message(
            id: localID,
            author: "You",
            body: "Keep this",
            timestamp: .now,
            isCurrentUser: true,
            deliveryState: .sending
        )
        let store = AppStore(conversations: [
            Conversation(
                id: "C1",
                title: "general",
                kind: .channel,
                subtitle: nil,
                isFavorite: false,
                unreadCount: 0,
                mentionCount: 0,
                latestActivity: optimistic.timestamp,
                messages: [optimistic]
            )
        ])

        try store.toggleSavedMessage(
            conversationID: "C1",
            messageID: localID
        )
        store.confirmSavedMessage(
            conversationID: "C1",
            localMessageID: localID,
            remoteID: "123.456"
        )

        let saved = try #require(store.savedMessages.first)
        #expect(store.savedMessages.count == 1)
        #expect(saved.id == "C1:123.456")
        #expect(saved.message.id == localID)
        #expect(saved.message.remoteID == "123.456")
        #expect(saved.message.deliveryState == .sent)
        #expect(store.isMessageSaved(conversationID: "C1", message: saved.message))
    }

    @Test @MainActor
    func refreshedRemoteSnapshotMatchesByTimestampWhenItsUUIDChanges() throws {
        let original = Message(
            author: "Maya",
            body: "Remember this",
            timestamp: .now,
            remoteID: "123.456"
        )
        let store = AppStore(conversations: [
            Conversation(
                id: "C1",
                title: "general",
                kind: .channel,
                subtitle: nil,
                isFavorite: false,
                unreadCount: 0,
                mentionCount: 0,
                latestActivity: original.timestamp,
                messages: [original]
            )
        ])
        try store.toggleSavedMessage(
            conversationID: "C1",
            messageID: original.id
        )
        let refreshed = Message(
            author: "Maya",
            body: "Edited remotely",
            timestamp: original.timestamp,
            remoteID: "123.456",
            editedAt: .now
        )

        store.refreshSavedMessageSnapshots(
            [refreshed],
            conversationID: "C1"
        )

        #expect(store.savedMessages.count == 1)
        #expect(store.savedMessages[0].id == "C1:123.456")
        #expect(store.savedMessages[0].message.id == refreshed.id)
        #expect(store.savedMessages[0].message.body == "Edited remotely")
        #expect(store.isMessageSaved(conversationID: "C1", message: refreshed))
    }

    @Test @MainActor
    func openingASavedMessageFocusesTheLiveMessage() throws {
        let original = Message(
            author: "Maya",
            body: "Remember this",
            timestamp: .now,
            remoteID: "123.456"
        )
        let store = AppStore(conversations: [
            Conversation(
                id: "C1",
                title: "general",
                kind: .channel,
                subtitle: nil,
                isFavorite: false,
                unreadCount: 0,
                mentionCount: 0,
                latestActivity: original.timestamp,
                messages: [original]
            )
        ])
        try store.toggleSavedMessage(conversationID: "C1", messageID: original.id)
        let saved = try #require(store.savedMessages.first)

        // A history reload rebuilds the message with a fresh UUID.
        let reloaded = Message(
            author: "Maya",
            body: "Remember this",
            timestamp: original.timestamp,
            remoteID: "123.456"
        )
        store.conversations[0].messages = [reloaded]

        store.openSavedMessage(saved)

        #expect(store.destination == .conversation("C1"))
        #expect(store.workspaceSearchFocus?.conversationID == "C1")
        #expect(store.workspaceSearchFocus?.messageID == reloaded.id)
    }

    private func savedMessage(remoteID: String, savedAt: Date) -> SavedMessage {
        SavedMessage(
            conversationID: "C1",
            conversationTitle: "general",
            message: Message(
                author: "Maya",
                body: remoteID,
                timestamp: savedAt,
                remoteID: remoteID
            ),
            savedAt: savedAt
        )
    }
}
