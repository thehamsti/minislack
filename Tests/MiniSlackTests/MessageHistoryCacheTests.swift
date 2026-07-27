import Foundation
import Testing
@testable import MiniSlack

struct MessageHistoryCacheTests {
    @Test
    func decodesPagesCachedBeforeEmojiMetadataWasAdded() throws {
        let messageID = UUID()
        let json = """
        {
          "id": "\(messageID.uuidString)",
          "author": "Maya",
          "body": "Hello",
          "timestamp": 100,
          "isCurrentUser": false,
          "reactions": []
        }
        """

        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))

        #expect(message.emojiUnicode.isEmpty)
        #expect(message.displayBody == "Hello")
        #expect(message.authorUserID == nil)
    }

    @Test
    func preparesCachedMessagesWithTheCurrentWorkspaceContext() {
        let message = Message(
            author: "Sam",
            authorUserID: "U2",
            body: "<@U1> check <#C1> :moneybag:",
            timestamp: .now,
            reactions: [Reaction(emoji: ":+1::skin-tone-3:", count: 2)]
        )
        let context = SlackMessageFormatting.Context(
            userNames: ["U1": "Maya"],
            channelNames: ["C1": "clientcredentials"]
        )

        let prepared = message.preparingForDisplay(context: context)

        #expect(prepared.displayBody == "@Maya check #clientcredentials 💰")
        #expect(prepared.authorUserID == "U2")
        #expect(prepared.reactions == [Reaction(emoji: "👍🏼", count: 2)])
    }

    @Test
    func cachedPagesRoundTripAndResumeFromTheOldestCursor() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let cache = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)
        let recent = MessageHistoryPage(
            messages: [message(id: "2", timestamp: 200)],
            nextCursor: "older-page"
        )
        let older = MessageHistoryPage(
            messages: [message(id: "1", timestamp: 100)],
            nextCursor: nil
        )

        try await cache.store(recent, channelID: "C1", index: 0)
        try await cache.store(older, channelID: "C1", index: 1)

        #expect(try await cache.page(channelID: "C1", index: 0) == recent)
        #expect(try await cache.page(channelID: "C1", index: 1) == older)
        #expect(
            try await cache.status(channelID: "C1")
                == MessageHistoryCacheStatus(
                    pageCount: 2,
                    nextCursor: nil,
                    isComplete: true
                )
        )
    }

    @Test
    func refreshingLatestPagePreservesTheExistingBackfillBoundary() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let cache = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)
        try await cache.store(
            MessageHistoryPage(
                messages: [message(id: "2", timestamp: 200)],
                nextCursor: "original-older-page"
            ),
            channelID: "C1",
            index: 0
        )

        try await cache.mergeLatest(
            MessageHistoryPage(
                messages: [
                    message(id: "2", timestamp: 200),
                    message(id: "3", timestamp: 300),
                ],
                nextCursor: "shifted-older-page"
            ),
            channelID: "C1"
        )

        let page = try #require(try await cache.page(channelID: "C1", index: 0))
        #expect(page.messages.compactMap(\.remoteID) == ["2", "3"])
        #expect(page.nextCursor == "original-older-page")
    }

    private func message(id: String, timestamp: TimeInterval) -> Message {
        Message(
            author: "Maya",
            body: id,
            timestamp: Date(timeIntervalSince1970: timestamp),
            remoteID: id
        )
    }
}
