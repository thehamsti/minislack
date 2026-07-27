import Foundation
import SQLite3
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
        #expect(FileManager.default.fileExists(atPath: cache.databaseURL.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: rootURL
                    .appending(path: "T1/v2/C1/page-0.json")
                    .path
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

    @Test
    func refreshingLatestPageCapsItsHotMessageWindow() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let cache = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)
        try await cache.store(
            MessageHistoryPage(
                messages: (1 ... 5).map {
                    message(id: String($0), timestamp: TimeInterval($0))
                },
                nextCursor: "older-page"
            ),
            channelID: "C1",
            index: 0
        )

        try await cache.mergeLatest(
            MessageHistoryPage(
                messages: (6 ... 8).map {
                    message(id: String($0), timestamp: TimeInterval($0))
                },
                nextCursor: "shifted-page"
            ),
            channelID: "C1",
            maximumMessages: 4
        )

        let page = try #require(try await cache.page(channelID: "C1", index: 0))
        #expect(page.messages.compactMap(\.remoteID) == ["5", "6", "7", "8"])
        #expect(page.nextCursor == "older-page")
        let overflow = try #require(
            try await cache.page(channelID: "C1", index: 1)
        )
        #expect(overflow.messages.compactMap(\.remoteID) == ["1", "2", "3", "4"])
        #expect(overflow.nextCursor == "older-page")
        #expect(try await cache.indexSummary(channelID: "C1").messageCount == 8)
    }

    @Test
    func overwritingTheLastPageUpdatesTheBackfillBoundary() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let cache = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)
        try await cache.store(
            MessageHistoryPage(
                messages: [message(id: "2", timestamp: 200)],
                nextCursor: "page-one"
            ),
            channelID: "C1",
            index: 0
        )
        try await cache.store(
            MessageHistoryPage(
                messages: [message(id: "1", timestamp: 100)],
                nextCursor: "still-older"
            ),
            channelID: "C1",
            index: 1
        )

        try await cache.store(
            MessageHistoryPage(
                messages: [message(id: "1", timestamp: 100)],
                nextCursor: nil
            ),
            channelID: "C1",
            index: 1
        )

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
    func normalizedIndexesAndReadCursorRoundTripSemanticMessages() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let cache = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)
        let remoteID = "1700000000.000100"
        let richMessage = Message(
            id: UUID(),
            author: "Maya",
            authorUserID: "U1",
            body: "<@U2> launch",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            remoteID: remoteID,
            richText: MessageRichText(
                blocks: [
                    .section([
                        MessageRichText.Run(
                            content: .user(id: "U2", displayName: "Alex"),
                            style: MessageRichText.Style(isBold: true)
                        ),
                        MessageRichText.Run(
                            content: .text(raw: " launch", display: " launch"),
                            style: MessageRichText.Style()
                        ),
                    ])
                ]
            ),
            files: [
                MessageFile(
                    id: "F1",
                    name: "brief.pdf",
                    title: "Brief",
                    mimeType: "application/pdf",
                    prettyType: "PDF",
                    size: 4_096,
                    mode: "hosted",
                    contentSource: MessageMediaSource(
                        url: URL(string: "https://files.slack.com/F1/brief.pdf")!,
                        requiresSlackAuthorization: true
                    ),
                    thumbnailSource: nil,
                    permalink: nil,
                    previewText: nil,
                    altText: nil,
                    originalWidth: nil,
                    originalHeight: nil
                )
            ],
            images: [
                MessageImage(
                    title: "Launch",
                    altText: "Launch graph",
                    source: MessageMediaSource(
                        url: URL(string: "https://cdn.example.com/launch.png")!,
                        requiresSlackAuthorization: false
                    ),
                    slackFileID: nil
                )
            ],
            reactions: [
                Reaction(
                    name: "eyes",
                    emoji: "👀",
                    count: 2,
                    userIDs: ["U1", "U2"],
                    isCurrentUserIncluded: true
                )
            ],
            thread: MessageThreadMetadata(
                rootTimestamp: remoteID,
                replyCount: 3,
                replyUserIDs: ["U2", "U3"],
                latestReplyAt: Date(timeIntervalSince1970: 1_700_000_100),
                isFollowing: true
            )
        )
        try await cache.store(
            MessageHistoryPage(messages: [richMessage], nextCursor: nil),
            channelID: "C1",
            index: 0
        )

        #expect(
            try await cache.indexSummary(channelID: "C1")
                == MessageHistoryIndexSummary(
                    messageCount: 1,
                    reactionCount: 1,
                    fileCount: 1,
                    mediaCount: 1,
                    threadCount: 1
                )
        )
        #expect(
            try await cache.message(channelID: "C1", remoteID: remoteID)
                == richMessage
        )
        let cursor = MessageHistoryReadCursor(
            remoteID: remoteID,
            timestamp: richMessage.timestamp
        )
        try await cache.setReadCursor(cursor, channelID: "C1")
        #expect(try await cache.readCursor(channelID: "C1") == cursor)
        try await cache.setReadCursor(nil, channelID: "C1")
        #expect(try await cache.readCursor(channelID: "C1") == nil)
        #expect(
            try await cache.schemaVersion()
                == MessageHistoryCache.currentSchemaVersion
        )
        #expect(
            try sqliteTextRows(
                at: cache.databaseURL,
                sql: "PRAGMA journal_mode"
            ) == ["wal"]
        )
        let indexes = Set(
            try sqliteTextRows(
                at: cache.databaseURL,
                sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'index'
                  AND name NOT LIKE 'sqlite_autoindex_%'
                """
            )
        )
        #expect(
            indexes.isSuperset(
                of: [
                    "messages_remote_id_index",
                    "messages_timestamp_index",
                    "page_messages_message_index",
                    "message_reactions_name_index",
                    "message_files_id_index",
                    "message_media_source_index",
                    "message_threads_root_index",
                ]
            )
        )
    }

    @Test
    func importsLegacyJSONPagesOnceWithoutDeletingThem() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let legacyChannelURL = rootURL.appending(
            path: "T1/v2/C1",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: legacyChannelURL,
            withIntermediateDirectories: true
        )
        let original = MessageHistoryPage(
            messages: [message(id: "legacy", timestamp: 100)],
            nextCursor: "older"
        )
        let pageURL = legacyChannelURL.appending(path: "page-0.json")
        try JSONEncoder().encode(original).write(to: pageURL)
        let older = MessageHistoryPage(
            messages: [message(id: "older", timestamp: 50)],
            nextCursor: nil
        )
        try JSONEncoder().encode(older).write(
            to: legacyChannelURL.appending(path: "page-1.json")
        )
        try JSONEncoder().encode(
            MessageHistoryCacheStatus(
                pageCount: 2,
                nextCursor: nil,
                isComplete: true
            )
        ).write(to: legacyChannelURL.appending(path: "manifest.json"))

        let cache = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)
        #expect(try await cache.page(channelID: "C1", index: 0) == original)
        #expect(try await cache.indexSummary(channelID: "C1").messageCount == 1)
        #expect(try await cache.page(channelID: "C1", index: 1) == older)
        #expect(try await cache.indexSummary(channelID: "C1").messageCount == 2)
        #expect(FileManager.default.fileExists(atPath: pageURL.path))

        let changedLegacy = MessageHistoryPage(
            messages: [message(id: "changed", timestamp: 200)],
            nextCursor: nil
        )
        try JSONEncoder().encode(changedLegacy).write(to: pageURL)
        let reopened = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)

        #expect(try await reopened.page(channelID: "C1", index: 0) == original)
        #expect(FileManager.default.fileExists(atPath: pageURL.path))
    }

    @Test
    func corruptLegacyPageIsQuarantinedWithoutBlockingTheCache() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let legacyChannelURL = rootURL.appending(
            path: "T1/v2/C1",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: legacyChannelURL,
            withIntermediateDirectories: true
        )
        let pageURL = legacyChannelURL.appending(path: "page-0.json")
        try Data("not-json".utf8).write(to: pageURL)
        let cache = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)

        #expect(try await cache.page(channelID: "C1", index: 0) == nil)
        #expect(FileManager.default.fileExists(atPath: pageURL.path))
        #expect(try Data(contentsOf: pageURL) == Data("not-json".utf8))

        let recovered = MessageHistoryPage(
            messages: [message(id: "network", timestamp: 200)],
            nextCursor: nil
        )
        try await cache.store(recovered, channelID: "C1", index: 0)
        #expect(try await cache.page(channelID: "C1", index: 0) == recovered)
    }

    @Test
    func fullTextSearchIndexesUpdatesAndUsesPrefixMatching() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let cache = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)
        let original = Message(
            author: "Maya Chen",
            body: "Launch résumé checklist",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100.000"
        )
        try await cache.store(
            MessageHistoryPage(messages: [original], nextCursor: nil),
            channelID: "C1",
            index: 0
        )

        let foldedPrefixHits = try await cache.searchMessages(
            query: "resu check"
        )
        #expect(foldedPrefixHits.count == 1)
        #expect(foldedPrefixHits.first?.localID == original.id)
        #expect(foldedPrefixHits.first?.remoteID == original.remoteID)
        #expect(foldedPrefixHits.first?.author == original.author)

        let updated = Message(
            id: original.id,
            author: original.author,
            body: "Archived deployment notes",
            timestamp: original.timestamp,
            remoteID: original.remoteID
        )
        try await cache.store(
            MessageHistoryPage(messages: [updated], nextCursor: nil),
            channelID: "C1",
            index: 0
        )

        #expect(try await cache.searchMessages(query: "launch").isEmpty)
        #expect(
            try await cache.searchMessages(query: "arch dep").map(\.localID)
                == [updated.id]
        )
    }

    @Test
    func versionOneDatabaseMigratesAndBackfillsFullTextSearch() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let cache = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)
        let cachedMessage = Message(
            author: "Maya",
            body: "Migration search sentinel",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100.000"
        )
        try await cache.store(
            MessageHistoryPage(messages: [cachedMessage], nextCursor: nil),
            channelID: "C1",
            index: 0
        )
        try sqliteExecute(
            at: cache.databaseURL,
            sql: """
            DROP TABLE message_search_keys;
            DROP TABLE message_search;
            PRAGMA user_version = 1;
            """
        )

        let migrated = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)

        #expect(
            try await migrated.schemaVersion()
                == MessageHistoryCache.currentSchemaVersion
        )
        #expect(
            try await migrated.searchIndexStatus()
                == MessageHistorySearchIndexStatus(
                    indexedMessageCount: 0,
                    isBackfillComplete: false
                )
        )
        #expect(
            try await migrated.searchMessages(query: "migration sent").map(
                \.localID
            ) == [cachedMessage.id]
        )
        #expect(
            try await migrated.searchIndexStatus()
                == MessageHistorySearchIndexStatus(
                    indexedMessageCount: 1,
                    isBackfillComplete: true
                )
        )
    }

    @Test
    func migratedSearchBackfillIsIncrementalAndStrictlyBatchBounded() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let cache = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)
        for pageIndex in 0 ..< 3 {
            let range = (pageIndex * 400) ..< ((pageIndex + 1) * 400)
            let messages = range.map { index in
                Message(
                    author: "Maya",
                    body: "Migration message \(index)",
                    timestamp: Date(
                        timeIntervalSince1970: TimeInterval(index)
                    ),
                    remoteID: String(format: "%04d.000", index)
                )
            }
            try await cache.store(
                MessageHistoryPage(
                    messages: messages,
                    nextCursor: pageIndex == 2 ? nil : "cursor-\(pageIndex)"
                ),
                channelID: "C1",
                index: pageIndex
            )
        }
        try sqliteExecute(
            at: cache.databaseURL,
            sql: """
            DROP TABLE message_search_keys;
            DROP TABLE message_search;
            PRAGMA user_version = 1;
            """
        )
        let migrated = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)

        #expect(
            try await migrated.schemaVersion()
                == MessageHistoryCache.currentSchemaVersion
        )
        #expect(try await migrated.searchIndexStatus().indexedMessageCount == 0)

        let isComplete = try await migrated.backfillSearchIndex(
            maximumMessages: 37
        )

        #expect(!isComplete)
        #expect(
            try await migrated.searchIndexStatus()
                == MessageHistorySearchIndexStatus(
                    indexedMessageCount: 37,
                    isBackfillComplete: false
                )
        )
    }

    @Test
    func concurrentActorAccessKeepsEveryPageQueryable() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let cache = MessageHistoryCache(workspaceID: "T1", rootURL: rootURL)
        let pageCount = 16

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< pageCount {
                group.addTask {
                    try await cache.store(
                        MessageHistoryPage(
                            messages: [
                                Message(
                                    author: "Maya",
                                    body: String(index),
                                    timestamp: Date(
                                        timeIntervalSince1970: TimeInterval(index)
                                    ),
                                    remoteID: String(index)
                                )
                            ],
                            nextCursor: index == pageCount - 1
                                ? nil
                                : "cursor-\(index)"
                        ),
                        channelID: "C1",
                        index: index
                    )
                }
            }
            try await group.waitForAll()
        }

        let remoteIDs = try await withThrowingTaskGroup(
            of: String.self,
            returning: [String].self
        ) { group in
            for index in 0 ..< pageCount {
                group.addTask {
                    let page = try await cache.page(
                        channelID: "C1",
                        index: index
                    )
                    return try #require(page?.messages.first?.remoteID)
                }
            }
            var values: [String] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        #expect(Set(remoteIDs) == Set((0 ..< pageCount).map(String.init)))
        #expect(
            try await cache.status(channelID: "C1")
                == MessageHistoryCacheStatus(
                    pageCount: pageCount,
                    nextCursor: nil,
                    isComplete: true
                )
        )
    }

    private func message(id: String, timestamp: TimeInterval) -> Message {
        Message(
            author: "Maya",
            body: id,
            timestamp: Date(timeIntervalSince1970: timestamp),
            remoteID: id
        )
    }

    private func sqliteTextRows(
        at url: URL,
        sql: String
    ) throws -> [String] {
        var databasePointer: OpaquePointer?
        let openResult = url.path.withCString {
            sqlite3_open_v2($0, &databasePointer, SQLITE_OPEN_READONLY, nil)
        }
        try #require(openResult == SQLITE_OK)
        let database = try #require(databasePointer)
        defer { sqlite3_close_v2(database) }

        var statementPointer: OpaquePointer?
        let prepareResult = sql.withCString {
            sqlite3_prepare_v2(database, $0, -1, &statementPointer, nil)
        }
        try #require(prepareResult == SQLITE_OK)
        let statement = try #require(statementPointer)
        defer { sqlite3_finalize(statement) }

        var values: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return values
            }
            try #require(result == SQLITE_ROW)
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
    }

    private func sqliteExecute(at url: URL, sql: String) throws {
        var databasePointer: OpaquePointer?
        let openResult = url.path.withCString {
            sqlite3_open_v2($0, &databasePointer, SQLITE_OPEN_READWRITE, nil)
        }
        try #require(openResult == SQLITE_OK)
        let database = try #require(databasePointer)
        defer { sqlite3_close_v2(database) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sql.withCString {
            sqlite3_exec(database, $0, nil, nil, &errorMessage)
        }
        defer { sqlite3_free(errorMessage) }
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            Issue.record("SQLite setup failed: \(message)")
        }
        try #require(result == SQLITE_OK)
    }
}
