import Foundation
import Testing
@testable import MiniSlack

struct WorkspaceSearchTests {
    @Test
    func indexesMessagesAcrossLoadedConversationsAndRanksRecentMatches() {
        let older = message(id: 1, author: "Maya", body: "Launch résumé", time: 100)
        let newer = message(id: 2, author: "Sam", body: "Launch checklist", time: 200)
        let conversations = [
            conversation(id: "design", title: "design", messages: [older]),
            conversation(id: "launch", title: "launch", messages: [newer]),
        ]
        let index = WorkspaceSearchIndex(conversations: conversations)

        let launchResults = index.searchMessages(query: "launch")
        let foldedResults = index.searchMessages(query: "resume")
        let prefixResults = index.searchMessages(query: "check")

        #expect(launchResults.map(\.messageID) == [newer.id, older.id])
        #expect(foldedResults.map(\.messageID) == [older.id])
        #expect(prefixResults.map(\.messageID) == [newer.id])
        #expect(launchResults.allSatisfy { $0.source == .local })
    }

    @Test
    func mergedCachedPagesUpdateExistingDocumentsWithoutDuplicates() {
        let original = message(
            id: 1,
            author: "Maya",
            body: "Old launch copy",
            time: 100,
            remoteID: "100.000"
        )
        let updated = message(
            id: 2,
            author: "Maya",
            body: "Updated launch copy",
            time: 100,
            remoteID: "100.000"
        )
        let channel = conversation(id: "launch", title: "launch")
        var index = WorkspaceSearchIndex()

        index.merge(messages: [original], conversation: channel)
        index.merge(messages: [updated], conversation: channel)

        let results = index.searchMessages(query: "launch")
        #expect(results.count == 1)
        #expect(results.first?.detail == "Updated launch copy")
    }

    @Test
    func entitySearchFindsPeopleAndConversationsInBothModes() {
        let user = WorkspaceUser(
            id: "U1",
            displayName: "Maya Chen",
            status: "Launching",
            isActive: true
        )
        let channel = conversation(id: "C1", title: "launch-room")

        let people = WorkspaceSearchIndex.searchEntities(
            query: "maya",
            users: [user],
            conversations: [channel]
        )
        let channels = WorkspaceSearchIndex.searchEntities(
            query: "launch",
            users: [user],
            conversations: [channel]
        )

        #expect(people.map(\.kind) == [.person])
        #expect(channels.contains { $0.conversationID == channel.id })
    }

    @Test
    func resultSetsStayBoundedAndDeduplicated() {
        let duplicate = WorkspaceSearchResult(
            id: "same",
            kind: .channel,
            source: .local,
            title: "#same",
            detail: "Channel",
            conversationID: "same",
            userID: nil,
            messageID: nil,
            timestamp: nil,
            permalink: nil
        )
        let content = (0 ..< 150).map { index in
            WorkspaceSearchResult(
                id: index == 0 ? duplicate.id : "message-\(index)",
                kind: .message,
                source: .remote,
                title: "Result \(index)",
                detail: "Detail",
                conversationID: nil,
                userID: nil,
                messageID: nil,
                timestamp: nil,
                permalink: nil
            )
        }

        let results = WorkspaceSearchIndex.boundedMerge(
            entities: [duplicate],
            content: content
        )

        #expect(results.count == WorkspaceSearchIndex.maximumResultCount)
        #expect(results.filter { $0.id == duplicate.id }.count == 1)
    }

    @Test
    func prefixPostingLookupStaysFastWithALargeVocabulary() {
        let messages = (0 ..< 5_000).map { index in
            Message(
                author: "Author \(index)",
                body: "uniqueword\(index) project\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let index = WorkspaceSearchIndex(
            conversations: [
                conversation(id: "large", title: "large", messages: messages)
            ]
        )
        let clock = ContinuousClock()
        var matchCount = 0

        let duration = clock.measure {
            for _ in 0 ..< 20 {
                matchCount += index.searchMessages(query: "u").count
            }
        }

        #expect(matchCount == 2_000)
        #expect(duration < .seconds(1))
    }

    @Test
    func hotIndexCardinalityStaysBoundedAcrossFiftyThousandMessages() {
        let channel = conversation(id: "large", title: "large")
        var index = WorkspaceSearchIndex()
        let clock = ContinuousClock()
        let messageCount = 50_001

        let duration = clock.measure {
            for batchStart in stride(from: 0, to: messageCount, by: 500) {
                let batchEnd = min(batchStart + 500, messageCount)
                let batch = (batchStart ..< batchEnd).map { offset in
                    Message(
                        author: "Author",
                        body: "commonterm unique\(offset)",
                        timestamp: Date(
                            timeIntervalSince1970: TimeInterval(offset)
                        ),
                        remoteID: "\(offset).000"
                    )
                }
                index.merge(messages: batch, conversation: channel)
            }
        }
        let metrics = index.metrics

        #expect(metrics.documentCount == WorkspaceSearchIndex.maximumHotMessageCount)
        #expect(metrics.postingCount <= WorkspaceSearchIndex.maximumPostingCount)
        #expect(
            metrics.retentionEntryCount
                <= WorkspaceSearchIndex.maximumHotMessageCount * 2
        )
        #expect(index.searchMessages(query: "unique0").isEmpty)
        #expect(
            index.searchMessages(query: "unique50000").first?.timestamp
                == Date(timeIntervalSince1970: 50_000)
        )
        #expect(index.searchMessages(query: "commonterm").count == 100)
        #expect(duration < .seconds(15))
    }

    @Test
    @MainActor
    func diskSearchLoadsAndFocusesAnExactMessageWithoutHydratingItsPage() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let cachedMessage = Message(
            author: "Maya",
            body: "A durable search needle",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100.000"
        )
        let cache = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)
        try await cache.store(
            MessageHistoryPage(messages: [cachedMessage], nextCursor: nil),
            channelID: "C1",
            index: 4
        )
        let channel = conversation(id: "C1", title: "launch")
        let store = AppStore(conversations: [channel])
        store.historyCache = cache

        let result = try #require(
            try await store.searchWorkspaceHistory("needle").first
        )
        #expect(store.conversations[0].messages.isEmpty)

        #expect(
            await store.openWorkspaceSearchResultLoadingMessage(result) == nil
        )
        #expect(store.destination == .conversation("C1"))
        #expect(store.conversations[0].messages.map(\.id) == [cachedMessage.id])
        #expect(
            store.workspaceSearchFocus
                == WorkspaceSearchFocus(
                    conversationID: "C1",
                    messageID: cachedMessage.id
                )
        )
    }

    @Test
    @MainActor
    func appStoreSearchOpensLocalHitsAndReturnsExternalFileLinks() throws {
        let user = WorkspaceUser(
            id: "U1",
            displayName: "Maya Chen",
            status: "Launching",
            isActive: true
        )
        let channel = conversation(
            id: "C1",
            title: "launch",
            messages: [message(id: 1, author: "Maya", body: "Ship today", time: 100)]
        )
        let store = AppStore(conversations: [channel], users: [user])
        let messageResult = try #require(
            store.searchWorkspaceLocally("ship").first { $0.kind == .message }
        )

        #expect(store.openWorkspaceSearchResult(messageResult) == nil)
        #expect(store.destination == .conversation(channel.id))

        let personResult = try #require(
            store.searchWorkspaceLocally("maya").first { $0.kind == .person }
        )
        #expect(store.openWorkspaceSearchResult(personResult) == nil)
        #expect(store.selectedConversation?.participantUserID == user.id)

        let fileURL = try #require(URL(string: "https://example.slack.com/files/F1"))
        let file = WorkspaceSearchResult(
            id: "remote-file",
            kind: .file,
            source: .remote,
            title: "Launch brief",
            detail: "PDF",
            conversationID: channel.id,
            userID: nil,
            messageID: nil,
            timestamp: nil,
            permalink: fileURL
        )
        #expect(store.openWorkspaceSearchResult(file) == fileURL)
    }

    @Test
    @MainActor
    func workspaceSearchPresentationIsWindowScopedAndExclusive() {
        let focusedWindow = WindowState()
        let backgroundWindow = WindowState()
        focusedWindow.presentQuickSwitcher()

        focusedWindow.presentWorkspaceSearch()

        #expect(focusedWindow.isWorkspaceSearchPresented)
        #expect(!focusedWindow.isQuickSwitcherPresented)
        #expect(!backgroundWindow.isWorkspaceSearchPresented)
    }

    private func message(
        id: UInt8,
        author: String,
        body: String,
        time: TimeInterval,
        remoteID: String? = nil
    ) -> Message {
        Message(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, id)),
            author: author,
            body: body,
            timestamp: Date(timeIntervalSince1970: time),
            remoteID: remoteID
        )
    }

    private func conversation(
        id: String,
        title: String,
        messages: [Message] = []
    ) -> Conversation {
        Conversation(
            id: id,
            title: title,
            kind: .channel,
            subtitle: nil,
            isFavorite: false,
            unreadCount: 0,
            mentionCount: 0,
            latestActivity: messages.last?.timestamp ?? .distantPast,
            messages: messages
        )
    }
}
