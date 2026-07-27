import Foundation
import Testing
@testable import MiniSlack

struct MessageHistoryCacheTests {
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
