import Foundation
import SQLite3

struct MessageHistoryPage: Codable, Equatable, Sendable {
    let messages: [Message]
    let nextCursor: String?
}

struct MessageHistoryCacheStatus: Codable, Equatable, Sendable {
    var pageCount: Int
    var nextCursor: String?
    var isComplete: Bool

    static let empty = MessageHistoryCacheStatus(
        pageCount: 0,
        nextCursor: nil,
        isComplete: false
    )
}

struct MessageHistoryReadCursor: Codable, Equatable, Sendable {
    let remoteID: String?
    let timestamp: Date?
}

struct MessageHistoryIndexSummary: Equatable, Sendable {
    let messageCount: Int
    let reactionCount: Int
    let fileCount: Int
    let mediaCount: Int
    let threadCount: Int
}

struct MessageHistorySearchHit: Equatable, Sendable {
    let channelID: String
    let stableID: String
    let localID: UUID
    let remoteID: String?
    let author: String
    let detail: String
    let timestamp: Date
}

struct MessageHistorySearchIndexStatus: Equatable, Sendable {
    let indexedMessageCount: Int
    let isBackfillComplete: Bool
}

enum MessageHistoryCacheError: LocalizedError {
    case database(String)
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case let .database(message):
            "History database error: \(message)"
        case let .unsupportedSchemaVersion(version):
            "History database schema \(version) is newer than this app supports."
        }
    }
}

actor MessageHistoryCache {
    static let currentSchemaVersion = 2
    static let maximumMessagesPerPage = 500
    static let maximumSearchResultCount = 100
    static let maximumSearchBackfillBatchSize = 500
    private static let searchBackfillCompleteKey =
        "message_search_backfill_complete"
    private static let searchBackfillChannelKey =
        "message_search_backfill_channel"
    private static let searchBackfillStableIDKey =
        "message_search_backfill_stable_id"

    nonisolated let databaseURL: URL
    nonisolated let legacyRootURL: URL

    private let workspaceDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let databaseHandle = SQLiteDatabaseHandle()

    init(workspaceID: String, rootURL: URL? = nil) {
        let baseURL = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "MiniSlack/History", directoryHint: .isDirectory)
        workspaceDirectory = baseURL.appending(
            path: workspaceID,
            directoryHint: .isDirectory
        )
        databaseURL = workspaceDirectory.appending(path: "history.sqlite3")
        legacyRootURL = workspaceDirectory.appending(
            path: "v2",
            directoryHint: .isDirectory
        )
    }

    func page(channelID: String, index: Int) throws -> MessageHistoryPage? {
        guard index >= 0 else {
            return nil
        }
        let database = try ensureReady()
        try importLegacyManifestIfNeeded(
            channelID: channelID,
            database: database
        )
        var cursor = try pageCursor(
            database: database,
            channelID: channelID,
            index: index
        )
        if !cursor.exists {
            try importLegacyPageIfNeeded(
                channelID: channelID,
                index: index,
                database: database
            )
            cursor = try pageCursor(
                database: database,
                channelID: channelID,
                index: index
            )
        }
        guard cursor.exists else {
            return nil
        }

        let statement = try prepare(
            """
            SELECT messages.payload
            FROM page_messages
            JOIN messages
              ON messages.channel_id = page_messages.channel_id
             AND messages.stable_id = page_messages.message_stable_id
            WHERE page_messages.channel_id = ?
              AND page_messages.page_index = ?
            ORDER BY page_messages.position ASC
            LIMIT ?
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(channelID, at: 1, in: statement, database: database)
        try bind(Int64(index), at: 2, in: statement, database: database)
        try bind(
            Int64(Self.maximumMessagesPerPage),
            at: 3,
            in: statement,
            database: database
        )

        var messages: [Message] = []
        messages.reserveCapacity(min(cursor.messageCount, Self.maximumMessagesPerPage))
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                messages.append(
                    try decoder.decode(
                        Message.self,
                        from: columnData(statement, at: 0)
                    )
                )
            case SQLITE_DONE:
                return MessageHistoryPage(
                    messages: messages,
                    nextCursor: cursor.nextCursor
                )
            default:
                throw databaseError(database)
            }
        }
    }

    func status(channelID: String) throws -> MessageHistoryCacheStatus {
        let database = try ensureReady()
        try importLegacyManifestIfNeeded(
            channelID: channelID,
            database: database
        )
        let statement = try prepare(
            """
            SELECT page_count, next_cursor, is_complete
            FROM channel_manifests
            WHERE channel_id = ?
            LIMIT 1
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(channelID, at: 1, in: statement, database: database)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return MessageHistoryCacheStatus(
                pageCount: Int(sqlite3_column_int64(statement, 0)),
                nextCursor: columnText(statement, at: 1),
                isComplete: sqlite3_column_int(statement, 2) != 0
            )
        case SQLITE_DONE:
            return .empty
        default:
            throw databaseError(database)
        }
    }

    func store(_ page: MessageHistoryPage, channelID: String, index: Int) throws {
        guard index >= 0 else {
            throw MessageHistoryCacheError.database(
                "Page indexes must be non-negative."
            )
        }
        let database = try ensureReady()
        try importLegacyManifestIfNeeded(
            channelID: channelID,
            database: database
        )
        try storePage(
            bounded(page),
            channelID: channelID,
            index: index,
            database: database
        )
    }

    func mergeLatest(
        _ page: MessageHistoryPage,
        channelID: String,
        maximumMessages: Int = 200
    ) throws {
        let boundedMaximum = min(
            max(maximumMessages, 0),
            Self.maximumMessagesPerPage
        )
        let existing = try self.page(channelID: channelID, index: 0)
        var messagesByID: [String: Message] = [:]
        for message in (existing?.messages ?? []) + page.messages.suffix(
            Self.maximumMessagesPerPage
        ) {
            messagesByID[stableID(for: message)] = message
        }
        let orderedMessages = messagesByID.values.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return stableID(for: $0) < stableID(for: $1)
        }
        let recentMessages = Array(orderedMessages.suffix(boundedMaximum))
        let overflowCount = orderedMessages.count - recentMessages.count
        if overflowCount > 0 {
            try spillOlderMessages(
                Array(orderedMessages.prefix(overflowCount)),
                channelID: channelID,
                startingAt: 1,
                capacity: max(1, boundedMaximum),
                inheritedCursor: existing?.nextCursor ?? page.nextCursor
            )
        }
        let merged = MessageHistoryPage(
            messages: recentMessages,
            nextCursor: existing?.nextCursor ?? page.nextCursor
        )
        if merged != existing {
            try store(merged, channelID: channelID, index: 0)
        }
    }

    private func spillOlderMessages(
        _ messages: [Message],
        channelID: String,
        startingAt pageIndex: Int,
        capacity: Int,
        inheritedCursor: String?
    ) throws {
        var overflow = messages
        var index = pageIndex
        var cursor = inheritedCursor

        while !overflow.isEmpty {
            let existing = try page(channelID: channelID, index: index)
            var messagesByID: [String: Message] = [:]
            for message in (existing?.messages ?? []) + overflow {
                messagesByID[stableID(for: message)] = message
            }
            let ordered = messagesByID.values.sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp < $1.timestamp
                }
                return stableID(for: $0) < stableID(for: $1)
            }
            let retained = Array(ordered.suffix(capacity))
            let nextOverflow = Array(
                ordered.prefix(ordered.count - retained.count)
            )
            let nextCursor = existing?.nextCursor ?? cursor
            let updated = MessageHistoryPage(
                messages: retained,
                nextCursor: nextCursor
            )
            if updated != existing {
                try store(updated, channelID: channelID, index: index)
            }
            overflow = nextOverflow
            cursor = nextCursor
            index += 1
        }
    }

    func message(
        channelID: String,
        remoteID: String
    ) throws -> Message? {
        let database = try ensureReady()
        let statement = try prepare(
            """
            SELECT payload
            FROM messages
            WHERE channel_id = ? AND remote_id = ?
            LIMIT 1
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(channelID, at: 1, in: statement, database: database)
        try bind(remoteID, at: 2, in: statement, database: database)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decoder.decode(
                Message.self,
                from: columnData(statement, at: 0)
            )
        case SQLITE_DONE:
            return nil
        default:
            throw databaseError(database)
        }
    }

    func message(
        channelID: String,
        stableID: String
    ) throws -> Message? {
        let database = try ensureReady()
        let statement = try prepare(
            """
            SELECT payload
            FROM messages
            WHERE channel_id = ? AND stable_id = ?
            LIMIT 1
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(channelID, at: 1, in: statement, database: database)
        try bind(stableID, at: 2, in: statement, database: database)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decoder.decode(
                Message.self,
                from: columnData(statement, at: 0)
            )
        case SQLITE_DONE:
            return nil
        default:
            throw databaseError(database)
        }
    }

    func searchMessages(
        query: String,
        limit: Int = maximumSearchResultCount
    ) throws -> [MessageHistorySearchHit] {
        guard let expression = Self.searchExpression(for: query) else {
            return []
        }
        let boundedLimit = min(max(0, limit), Self.maximumSearchResultCount)
        guard boundedLimit > 0 else {
            return []
        }
        let database = try ensureReady()
        _ = try backfillSearchIndex(
            database: database,
            maximumMessages: 100
        )
        let statement = try prepare(
            """
            SELECT
                message_search.channel_id,
                message_search.stable_id,
                messages.local_id,
                messages.remote_id,
                message_search.author,
                messages.timestamp,
                snippet(message_search, 4, '', '', ' … ', 24)
            FROM message_search
            JOIN messages
              ON messages.channel_id = message_search.channel_id
             AND messages.stable_id = message_search.stable_id
            WHERE message_search MATCH ?
            ORDER BY
                bm25(message_search, 0.0, 0.0, 0.0, 2.0, 1.0),
                messages.timestamp DESC
            LIMIT ?
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(expression, at: 1, in: statement, database: database)
        try bind(Int64(boundedLimit), at: 2, in: statement, database: database)

        var hits: [MessageHistorySearchHit] = []
        hits.reserveCapacity(boundedLimit)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let channelID = columnText(statement, at: 0),
                      let stableID = columnText(statement, at: 1),
                      let localIDText = columnText(statement, at: 2),
                      let localID = UUID(uuidString: localIDText),
                      let author = columnText(statement, at: 4)
                else {
                    continue
                }
                hits.append(
                    MessageHistorySearchHit(
                        channelID: channelID,
                        stableID: stableID,
                        localID: localID,
                        remoteID: columnText(statement, at: 3),
                        author: author,
                        detail: columnText(statement, at: 6) ?? "",
                        timestamp: Date(
                            timeIntervalSince1970: sqlite3_column_double(
                                statement,
                                5
                            )
                        )
                    )
                )
            case SQLITE_DONE:
                return hits
            default:
                throw databaseError(database)
            }
        }
    }

    func backfillSearchIndex(
        maximumMessages: Int = 250
    ) throws -> Bool {
        try backfillSearchIndex(
            database: ensureReady(),
            maximumMessages: maximumMessages
        )
    }

    func searchIndexStatus() throws -> MessageHistorySearchIndexStatus {
        let database = try ensureReady()
        let statement = try prepare(
            "SELECT COUNT(*) FROM message_search_keys",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError(database)
        }
        return MessageHistorySearchIndexStatus(
            indexedMessageCount: Int(sqlite3_column_int64(statement, 0)),
            isBackfillComplete: try metadataValue(
                for: Self.searchBackfillCompleteKey,
                database: database
            ) == "1"
        )
    }

    func setReadCursor(
        _ cursor: MessageHistoryReadCursor?,
        channelID: String
    ) throws {
        let database = try ensureReady()
        if let cursor {
            try ensureChannel(channelID, database: database)
            try execute(
                """
                INSERT INTO read_cursors (
                    channel_id, remote_id, timestamp, updated_at
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(channel_id) DO UPDATE SET
                    remote_id = excluded.remote_id,
                    timestamp = excluded.timestamp,
                    updated_at = excluded.updated_at
                """,
                bindings: [
                    .text(channelID),
                    .optionalText(cursor.remoteID),
                    .optionalDouble(
                        cursor.timestamp?.timeIntervalSince1970
                    ),
                    .double(Date.now.timeIntervalSince1970),
                ],
                database: database
            )
        } else {
            try execute(
                "DELETE FROM read_cursors WHERE channel_id = ?",
                bindings: [.text(channelID)],
                database: database
            )
        }
    }

    func readCursor(channelID: String) throws -> MessageHistoryReadCursor? {
        let database = try ensureReady()
        let statement = try prepare(
            """
            SELECT remote_id, timestamp
            FROM read_cursors
            WHERE channel_id = ?
            LIMIT 1
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(channelID, at: 1, in: statement, database: database)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let timestamp = sqlite3_column_type(statement, 1) == SQLITE_NULL
                ? nil
                : Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, 1)
                )
            return MessageHistoryReadCursor(
                remoteID: columnText(statement, at: 0),
                timestamp: timestamp
            )
        case SQLITE_DONE:
            return nil
        default:
            throw databaseError(database)
        }
    }

    func indexSummary(channelID: String) throws -> MessageHistoryIndexSummary {
        let database = try ensureReady()
        return MessageHistoryIndexSummary(
            messageCount: try rowCount(
                table: "messages",
                channelID: channelID,
                database: database
            ),
            reactionCount: try rowCount(
                table: "message_reactions",
                channelID: channelID,
                database: database
            ),
            fileCount: try rowCount(
                table: "message_files",
                channelID: channelID,
                database: database
            ),
            mediaCount: try rowCount(
                table: "message_media",
                channelID: channelID,
                database: database
            ),
            threadCount: try rowCount(
                table: "message_threads",
                channelID: channelID,
                database: database
            )
        )
    }

    func schemaVersion() throws -> Int {
        let database = try ensureReady()
        return try userVersion(database)
    }

    private func ensureReady() throws -> OpaquePointer {
        if let database = databaseHandle.raw {
            return database
        }
        try FileManager.default.createDirectory(
            at: workspaceDirectory,
            withIntermediateDirectories: true
        )
        var openedDatabase: OpaquePointer?
        let result = databaseURL.path.withCString {
            sqlite3_open_v2(
                $0,
                &openedDatabase,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
        }
        guard result == SQLITE_OK, let openedDatabase else {
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            throw MessageHistoryCacheError.database(
                "Could not open \(databaseURL.lastPathComponent)."
            )
        }
        databaseHandle.raw = openedDatabase
        do {
            sqlite3_extended_result_codes(openedDatabase, 1)
            try executeScript(
                """
                PRAGMA foreign_keys = ON;
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = NORMAL;
                PRAGMA busy_timeout = 5000;
                """,
                database: openedDatabase
            )
            try migrateSchema(openedDatabase)
            return openedDatabase
        } catch {
            sqlite3_close_v2(openedDatabase)
            databaseHandle.raw = nil
            throw error
        }
    }

    private func migrateSchema(_ database: OpaquePointer) throws {
        var version = try userVersion(database)
        guard version <= Self.currentSchemaVersion else {
            throw MessageHistoryCacheError.unsupportedSchemaVersion(version)
        }
        if version == 0 {
            try transaction(database) {
                try executeScript(
                """
                CREATE TABLE cache_metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;

                CREATE TABLE channel_manifests (
                    channel_id TEXT PRIMARY KEY,
                    page_count INTEGER NOT NULL DEFAULT 0,
                    next_cursor TEXT,
                    is_complete INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                ) WITHOUT ROWID;

                CREATE TABLE page_manifests (
                    channel_id TEXT NOT NULL,
                    page_index INTEGER NOT NULL,
                    next_cursor TEXT,
                    message_count INTEGER NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (channel_id, page_index),
                    FOREIGN KEY (channel_id)
                        REFERENCES channel_manifests(channel_id)
                        ON DELETE CASCADE
                ) WITHOUT ROWID;

                CREATE TABLE messages (
                    channel_id TEXT NOT NULL,
                    stable_id TEXT NOT NULL,
                    local_id TEXT NOT NULL,
                    remote_id TEXT,
                    timestamp REAL NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY (channel_id, stable_id),
                    FOREIGN KEY (channel_id)
                        REFERENCES channel_manifests(channel_id)
                        ON DELETE CASCADE
                ) WITHOUT ROWID;

                CREATE UNIQUE INDEX messages_remote_id_index
                    ON messages(channel_id, remote_id)
                    WHERE remote_id IS NOT NULL;
                CREATE INDEX messages_timestamp_index
                    ON messages(channel_id, timestamp DESC);

                CREATE TABLE page_messages (
                    channel_id TEXT NOT NULL,
                    page_index INTEGER NOT NULL,
                    position INTEGER NOT NULL,
                    message_stable_id TEXT NOT NULL,
                    PRIMARY KEY (channel_id, page_index, position),
                    UNIQUE (channel_id, page_index, message_stable_id),
                    FOREIGN KEY (channel_id, page_index)
                        REFERENCES page_manifests(channel_id, page_index)
                        ON DELETE CASCADE,
                    FOREIGN KEY (channel_id, message_stable_id)
                        REFERENCES messages(channel_id, stable_id)
                        ON DELETE CASCADE
                ) WITHOUT ROWID;
                CREATE INDEX page_messages_message_index
                    ON page_messages(channel_id, message_stable_id);

                CREATE TABLE message_reactions (
                    channel_id TEXT NOT NULL,
                    message_stable_id TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    emoji TEXT NOT NULL,
                    count INTEGER NOT NULL,
                    user_ids BLOB NOT NULL,
                    is_current_user_included INTEGER NOT NULL,
                    PRIMARY KEY (
                        channel_id, message_stable_id, position
                    ),
                    FOREIGN KEY (channel_id, message_stable_id)
                        REFERENCES messages(channel_id, stable_id)
                        ON DELETE CASCADE
                ) WITHOUT ROWID;
                CREATE INDEX message_reactions_name_index
                    ON message_reactions(channel_id, name);

                CREATE TABLE message_files (
                    channel_id TEXT NOT NULL,
                    message_stable_id TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    file_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    title TEXT NOT NULL,
                    mime_type TEXT,
                    size INTEGER,
                    content_url TEXT,
                    thumbnail_url TEXT,
                    payload BLOB NOT NULL,
                    PRIMARY KEY (
                        channel_id, message_stable_id, position
                    ),
                    FOREIGN KEY (channel_id, message_stable_id)
                        REFERENCES messages(channel_id, stable_id)
                        ON DELETE CASCADE
                ) WITHOUT ROWID;
                CREATE INDEX message_files_id_index
                    ON message_files(channel_id, file_id);

                CREATE TABLE message_media (
                    channel_id TEXT NOT NULL,
                    message_stable_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    source_url TEXT,
                    thumbnail_url TEXT,
                    slack_file_id TEXT,
                    payload BLOB NOT NULL,
                    PRIMARY KEY (
                        channel_id, message_stable_id, kind, position
                    ),
                    FOREIGN KEY (channel_id, message_stable_id)
                        REFERENCES messages(channel_id, stable_id)
                        ON DELETE CASCADE
                ) WITHOUT ROWID;
                CREATE INDEX message_media_source_index
                    ON message_media(channel_id, source_url);

                CREATE TABLE message_threads (
                    channel_id TEXT NOT NULL,
                    message_stable_id TEXT NOT NULL,
                    root_timestamp TEXT NOT NULL,
                    reply_count INTEGER NOT NULL,
                    reply_user_ids BLOB NOT NULL,
                    latest_reply_at REAL,
                    is_following INTEGER NOT NULL,
                    PRIMARY KEY (channel_id, message_stable_id),
                    FOREIGN KEY (channel_id, message_stable_id)
                        REFERENCES messages(channel_id, stable_id)
                        ON DELETE CASCADE
                ) WITHOUT ROWID;
                CREATE INDEX message_threads_root_index
                    ON message_threads(channel_id, root_timestamp);

                CREATE TABLE read_cursors (
                    channel_id TEXT PRIMARY KEY,
                    remote_id TEXT,
                    timestamp REAL,
                    updated_at REAL NOT NULL,
                    FOREIGN KEY (channel_id)
                        REFERENCES channel_manifests(channel_id)
                        ON DELETE CASCADE
                ) WITHOUT ROWID;

                PRAGMA user_version = 1;
                """,
                database: database
            )
            }
            version = 1
        }
        if version < 2 {
            try migrateMessageSearch(database)
        }
    }

    private func migrateMessageSearch(_ database: OpaquePointer) throws {
        try transaction(database) {
            try executeScript(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
                    channel_id UNINDEXED,
                    stable_id UNINDEXED,
                    local_id UNINDEXED,
                    author,
                    body,
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                CREATE TABLE IF NOT EXISTS message_search_keys (
                    search_rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                    channel_id TEXT NOT NULL,
                    stable_id TEXT NOT NULL,
                    UNIQUE (channel_id, stable_id),
                    FOREIGN KEY (channel_id, stable_id)
                        REFERENCES messages(channel_id, stable_id)
                        ON DELETE CASCADE
                );
                CREATE TRIGGER IF NOT EXISTS message_search_keys_after_delete
                AFTER DELETE ON message_search_keys
                BEGIN
                    DELETE FROM message_search
                    WHERE rowid = old.search_rowid;
                END;
                """,
                database: database
            )
            try setMetadata(
                "0",
                for: Self.searchBackfillCompleteKey,
                database: database
            )
            try execute(
                "PRAGMA user_version = 2",
                database: database
            )
        }
    }

    private func backfillSearchIndex(
        database: OpaquePointer,
        maximumMessages: Int
    ) throws -> Bool {
        if try metadataValue(
            for: Self.searchBackfillCompleteKey,
            database: database
        ) == "1" {
            return true
        }
        let boundedMaximum = min(
            max(0, maximumMessages),
            Self.maximumSearchBackfillBatchSize
        )
        guard boundedMaximum > 0 else {
            return false
        }
        let previousChannel = try metadataValue(
            for: Self.searchBackfillChannelKey,
            database: database
        ) ?? ""
        let previousStableID = try metadataValue(
            for: Self.searchBackfillStableIDKey,
            database: database
        ) ?? ""
        var processedCount = 0
        var lastChannel = previousChannel
        var lastStableID = previousStableID

        try transaction(database) {
            let statement = try prepare(
                """
                SELECT
                    messages.channel_id,
                    messages.stable_id,
                    messages.local_id,
                    messages.payload,
                    message_search_keys.search_rowid
                FROM messages
                LEFT JOIN message_search_keys
                  ON message_search_keys.channel_id = messages.channel_id
                 AND message_search_keys.stable_id = messages.stable_id
                WHERE messages.channel_id > ?
                   OR (
                       messages.channel_id = ?
                       AND messages.stable_id > ?
                   )
                ORDER BY messages.channel_id, messages.stable_id
                LIMIT ?
                """,
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(
                previousChannel,
                at: 1,
                in: statement,
                database: database
            )
            try bind(
                previousChannel,
                at: 2,
                in: statement,
                database: database
            )
            try bind(
                previousStableID,
                at: 3,
                in: statement,
                database: database
            )
            try bind(
                Int64(boundedMaximum),
                at: 4,
                in: statement,
                database: database
            )

            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard let channelID = columnText(statement, at: 0),
                          let stableID = columnText(statement, at: 1),
                          let localID = columnText(statement, at: 2)
                    else {
                        continue
                    }
                    if sqlite3_column_type(statement, 4) == SQLITE_NULL {
                        let message = try decoder.decode(
                            Message.self,
                            from: columnData(statement, at: 3)
                        )
                        try upsertMessageSearch(
                            message,
                            stableID: stableID,
                            localID: localID,
                            channelID: channelID,
                            database: database
                        )
                    }
                    processedCount += 1
                    lastChannel = channelID
                    lastStableID = stableID
                case SQLITE_DONE:
                    if processedCount > 0 {
                        try setMetadata(
                            lastChannel,
                            for: Self.searchBackfillChannelKey,
                            database: database
                        )
                        try setMetadata(
                            lastStableID,
                            for: Self.searchBackfillStableIDKey,
                            database: database
                        )
                    }
                    if processedCount < boundedMaximum {
                        try setMetadata(
                            "1",
                            for: Self.searchBackfillCompleteKey,
                            database: database
                        )
                    }
                    return
                default:
                    throw databaseError(database)
                }
            }
        }
        return processedCount < boundedMaximum
    }

    private func importLegacyManifestIfNeeded(
        channelID: String,
        database: OpaquePointer
    ) throws {
        let key = "legacy_manifest:\(channelID)"
        guard try metadataValue(for: key, database: database) == nil else {
            return
        }
        let manifestURL = legacyRootURL
            .appending(path: channelID, directoryHint: .isDirectory)
            .appending(path: "manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            try setMetadata("complete", for: key, database: database)
            return
        }

        let manifest: MessageHistoryCacheStatus
        do {
            manifest = try decoder.decode(
                MessageHistoryCacheStatus.self,
                from: Data(contentsOf: manifestURL, options: .mappedIfSafe)
            )
        } catch {
            try setMetadata("failed", for: key, database: database)
            return
        }
        try upsertChannelManifest(
            manifest,
            channelID: channelID,
            database: database
        )
        try setMetadata("complete", for: key, database: database)
    }

    private func importLegacyPageIfNeeded(
        channelID: String,
        index: Int,
        database: OpaquePointer
    ) throws {
        let key = "legacy_page:\(channelID):\(index)"
        guard try metadataValue(for: key, database: database) == nil else {
            return
        }
        let pageURL = legacyRootURL
            .appending(path: channelID, directoryHint: .isDirectory)
            .appending(path: "page-\(index).json")
        guard FileManager.default.fileExists(atPath: pageURL.path) else {
            try setMetadata("complete", for: key, database: database)
            return
        }

        let page: MessageHistoryPage
        do {
            page = try decoder.decode(
                MessageHistoryPage.self,
                from: Data(contentsOf: pageURL, options: .mappedIfSafe)
            )
        } catch {
            try setMetadata("failed", for: key, database: database)
            return
        }
        try storePage(
            bounded(page),
            channelID: channelID,
            index: index,
            database: database
        )
        try setMetadata("complete", for: key, database: database)
    }

    private func storePage(
        _ page: MessageHistoryPage,
        channelID: String,
        index: Int,
        database: OpaquePointer
    ) throws {
        try transaction(database) {
            try ensureChannel(channelID, database: database)
            try execute(
                """
                INSERT INTO page_manifests (
                    channel_id, page_index, next_cursor,
                    message_count, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(channel_id, page_index) DO UPDATE SET
                    next_cursor = excluded.next_cursor,
                    message_count = excluded.message_count,
                    updated_at = excluded.updated_at
                """,
                bindings: [
                    .text(channelID),
                    .integer(Int64(index)),
                    .optionalText(page.nextCursor),
                    .integer(Int64(page.messages.count)),
                    .double(Date.now.timeIntervalSince1970),
                ],
                database: database
            )
            try execute(
                """
                DELETE FROM page_messages
                WHERE channel_id = ? AND page_index = ?
                """,
                bindings: [.text(channelID), .integer(Int64(index))],
                database: database
            )

            for (position, message) in page.messages.enumerated() {
                let stableID = stableID(for: message)
                try upsertMessage(
                    message,
                    stableID: stableID,
                    channelID: channelID,
                    database: database
                )
                try execute(
                    """
                    INSERT INTO page_messages (
                        channel_id, page_index, position, message_stable_id
                    ) VALUES (?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(channelID),
                        .integer(Int64(index)),
                        .integer(Int64(position)),
                        .text(stableID),
                    ],
                    database: database
                )
            }

            let currentStatus = try status(
                channelID: channelID,
                database: database
            )
            let lastKnownPage = max(0, currentStatus.pageCount - 1)
            if index >= lastKnownPage {
                try upsertChannelManifest(
                    MessageHistoryCacheStatus(
                        pageCount: max(currentStatus.pageCount, index + 1),
                        nextCursor: page.nextCursor,
                        isComplete: page.nextCursor == nil
                    ),
                    channelID: channelID,
                    database: database
                )
            }
        }
    }

    private func upsertMessage(
        _ message: Message,
        stableID: String,
        channelID: String,
        database: OpaquePointer
    ) throws {
        try execute(
            """
            INSERT INTO messages (
                channel_id, stable_id, local_id, remote_id,
                timestamp, payload
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(channel_id, stable_id) DO UPDATE SET
                local_id = excluded.local_id,
                remote_id = excluded.remote_id,
                timestamp = excluded.timestamp,
                payload = excluded.payload
            """,
            bindings: [
                .text(channelID),
                .text(stableID),
                .text(message.id.uuidString),
                .optionalText(message.remoteID),
                .double(message.timestamp.timeIntervalSince1970),
                .blob(try encoder.encode(message)),
            ],
            database: database
        )
        try upsertMessageSearch(
            message,
            stableID: stableID,
            localID: message.id.uuidString,
            channelID: channelID,
            database: database
        )
        for table in [
            "message_reactions",
            "message_files",
            "message_media",
            "message_threads",
        ] {
            try execute(
                """
                DELETE FROM \(table)
                WHERE channel_id = ? AND message_stable_id = ?
                """,
                bindings: [.text(channelID), .text(stableID)],
                database: database
            )
        }
        try indexReactions(
            message.reactions,
            channelID: channelID,
            stableID: stableID,
            database: database
        )
        try indexFiles(
            message.files,
            channelID: channelID,
            stableID: stableID,
            database: database
        )
        try indexMedia(
            message,
            channelID: channelID,
            stableID: stableID,
            database: database
        )
        if let thread = message.thread {
            try execute(
                """
                INSERT INTO message_threads (
                    channel_id, message_stable_id, root_timestamp,
                    reply_count, reply_user_ids, latest_reply_at,
                    is_following
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(channelID),
                    .text(stableID),
                    .text(thread.rootTimestamp),
                    .integer(Int64(thread.replyCount)),
                    .blob(try encoder.encode(thread.replyUserIDs)),
                    .optionalDouble(
                        thread.latestReplyAt?.timeIntervalSince1970
                    ),
                    .integer(thread.isFollowing ? 1 : 0),
                ],
                database: database
            )
        }
    }

    private func upsertMessageSearch(
        _ message: Message,
        stableID: String,
        localID: String,
        channelID: String,
        database: OpaquePointer
    ) throws {
        try execute(
            """
            INSERT INTO message_search_keys (channel_id, stable_id)
            VALUES (?, ?)
            ON CONFLICT(channel_id, stable_id) DO NOTHING
            """,
            bindings: [.text(channelID), .text(stableID)],
            database: database
        )
        let rowIDStatement = try prepare(
            """
            SELECT search_rowid
            FROM message_search_keys
            WHERE channel_id = ? AND stable_id = ?
            LIMIT 1
            """,
            database: database
        )
        defer { sqlite3_finalize(rowIDStatement) }
        try bind(channelID, at: 1, in: rowIDStatement, database: database)
        try bind(stableID, at: 2, in: rowIDStatement, database: database)
        guard sqlite3_step(rowIDStatement) == SQLITE_ROW else {
            throw databaseError(database)
        }
        let searchRowID = sqlite3_column_int64(rowIDStatement, 0)
        try execute(
            "DELETE FROM message_search WHERE rowid = ?",
            bindings: [.integer(searchRowID)],
            database: database
        )
        try execute(
            """
            INSERT INTO message_search (
                rowid, channel_id, stable_id, local_id, author, body
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .integer(searchRowID),
                .text(channelID),
                .text(stableID),
                .text(localID),
                .text(message.author),
                .text(message.copyText),
            ],
            database: database
        )
    }

    private func indexReactions(
        _ reactions: [Reaction],
        channelID: String,
        stableID: String,
        database: OpaquePointer
    ) throws {
        for (position, reaction) in reactions.enumerated() {
            try execute(
                """
                INSERT INTO message_reactions (
                    channel_id, message_stable_id, position,
                    name, emoji, count, user_ids,
                    is_current_user_included
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(channelID),
                    .text(stableID),
                    .integer(Int64(position)),
                    .text(reaction.name),
                    .text(reaction.emoji),
                    .integer(Int64(reaction.count)),
                    .blob(try encoder.encode(reaction.userIDs)),
                    .integer(reaction.isCurrentUserIncluded ? 1 : 0),
                ],
                database: database
            )
        }
    }

    private func indexFiles(
        _ files: [MessageFile],
        channelID: String,
        stableID: String,
        database: OpaquePointer
    ) throws {
        for (position, file) in files.enumerated() {
            try execute(
                """
                INSERT INTO message_files (
                    channel_id, message_stable_id, position,
                    file_id, name, title, mime_type, size,
                    content_url, thumbnail_url, payload
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(channelID),
                    .text(stableID),
                    .integer(Int64(position)),
                    .text(file.id),
                    .text(file.name),
                    .text(file.title),
                    .optionalText(file.mimeType),
                    .optionalInteger(file.size.map(Int64.init)),
                    .optionalText(file.contentSource?.url.absoluteString),
                    .optionalText(file.thumbnailSource?.url.absoluteString),
                    .blob(try encoder.encode(file)),
                ],
                database: database
            )
        }
    }

    private func indexMedia(
        _ message: Message,
        channelID: String,
        stableID: String,
        database: OpaquePointer
    ) throws {
        for (position, image) in message.images.enumerated() {
            try execute(
                """
                INSERT INTO message_media (
                    channel_id, message_stable_id, kind, position,
                    source_url, thumbnail_url, slack_file_id, payload
                ) VALUES (?, ?, 'image', ?, ?, NULL, ?, ?)
                """,
                bindings: [
                    .text(channelID),
                    .text(stableID),
                    .integer(Int64(position)),
                    .optionalText(image.source?.url.absoluteString),
                    .optionalText(image.slackFileID),
                    .blob(try encoder.encode(image)),
                ],
                database: database
            )
        }
        for (position, attachment) in message.attachments.enumerated() {
            try execute(
                """
                INSERT INTO message_media (
                    channel_id, message_stable_id, kind, position,
                    source_url, thumbnail_url, slack_file_id, payload
                ) VALUES (?, ?, 'attachment', ?, ?, ?, NULL, ?)
                """,
                bindings: [
                    .text(channelID),
                    .text(stableID),
                    .integer(Int64(position)),
                    .optionalText(
                        attachment.imageSource?.url.absoluteString
                    ),
                    .optionalText(
                        attachment.thumbnailSource?.url.absoluteString
                    ),
                    .blob(try encoder.encode(attachment)),
                ],
                database: database
            )
        }
    }

    private func ensureChannel(
        _ channelID: String,
        database: OpaquePointer
    ) throws {
        try execute(
            """
            INSERT INTO channel_manifests (
                channel_id, page_count, next_cursor,
                is_complete, updated_at
            ) VALUES (?, 0, NULL, 0, ?)
            ON CONFLICT(channel_id) DO NOTHING
            """,
            bindings: [
                .text(channelID),
                .double(Date.now.timeIntervalSince1970),
            ],
            database: database
        )
    }

    private func upsertChannelManifest(
        _ status: MessageHistoryCacheStatus,
        channelID: String,
        database: OpaquePointer
    ) throws {
        try execute(
            """
            INSERT INTO channel_manifests (
                channel_id, page_count, next_cursor,
                is_complete, updated_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(channel_id) DO UPDATE SET
                page_count = excluded.page_count,
                next_cursor = excluded.next_cursor,
                is_complete = excluded.is_complete,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(channelID),
                .integer(Int64(status.pageCount)),
                .optionalText(status.nextCursor),
                .integer(status.isComplete ? 1 : 0),
                .double(Date.now.timeIntervalSince1970),
            ],
            database: database
        )
    }

    private func status(
        channelID: String,
        database: OpaquePointer
    ) throws -> MessageHistoryCacheStatus {
        let statement = try prepare(
            """
            SELECT page_count, next_cursor, is_complete
            FROM channel_manifests
            WHERE channel_id = ?
            LIMIT 1
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(channelID, at: 1, in: statement, database: database)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return MessageHistoryCacheStatus(
                pageCount: Int(sqlite3_column_int64(statement, 0)),
                nextCursor: columnText(statement, at: 1),
                isComplete: sqlite3_column_int(statement, 2) != 0
            )
        case SQLITE_DONE:
            return .empty
        default:
            throw databaseError(database)
        }
    }

    private func pageCursor(
        database: OpaquePointer,
        channelID: String,
        index: Int
    ) throws -> (
        exists: Bool,
        nextCursor: String?,
        messageCount: Int
    ) {
        let statement = try prepare(
            """
            SELECT next_cursor, message_count
            FROM page_manifests
            WHERE channel_id = ? AND page_index = ?
            LIMIT 1
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(channelID, at: 1, in: statement, database: database)
        try bind(Int64(index), at: 2, in: statement, database: database)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return (
                true,
                columnText(statement, at: 0),
                Int(sqlite3_column_int64(statement, 1))
            )
        case SQLITE_DONE:
            return (false, nil, 0)
        default:
            throw databaseError(database)
        }
    }

    private func rowCount(
        table: String,
        channelID: String,
        database: OpaquePointer
    ) throws -> Int {
        let statement = try prepare(
            "SELECT COUNT(*) FROM \(table) WHERE channel_id = ?",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(channelID, at: 1, in: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError(database)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func metadataValue(
        for key: String,
        database: OpaquePointer
    ) throws -> String? {
        let statement = try prepare(
            "SELECT value FROM cache_metadata WHERE key = ? LIMIT 1",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, in: statement, database: database)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return columnText(statement, at: 0)
        case SQLITE_DONE:
            return nil
        default:
            throw databaseError(database)
        }
    }

    private func setMetadata(
        _ value: String,
        for key: String,
        database: OpaquePointer
    ) throws {
        try execute(
            """
            INSERT INTO cache_metadata (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            bindings: [.text(key), .text(value)],
            database: database
        )
    }

    private func userVersion(_ database: OpaquePointer) throws -> Int {
        let statement = try prepare(
            "PRAGMA user_version",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError(database)
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func bounded(_ page: MessageHistoryPage) -> MessageHistoryPage {
        guard page.messages.count > Self.maximumMessagesPerPage else {
            return page
        }
        return MessageHistoryPage(
            messages: Array(
                page.messages.suffix(Self.maximumMessagesPerPage)
            ),
            nextCursor: page.nextCursor
        )
    }

    private func stableID(for message: Message) -> String {
        message.remoteID.map { "remote:\($0)" }
            ?? "local:\(message.id.uuidString)"
    }

    private static func searchExpression(for query: String) -> String? {
        let tokens = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(8)
            .map { token in
                let bounded = String(token.prefix(64))
                    .replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(bounded)\"*"
            }
        guard !tokens.isEmpty else {
            return nil
        }
        return tokens.joined(separator: " AND ")
    }

    private func transaction(
        _ database: OpaquePointer,
        operation: () throws -> Void
    ) throws {
        try execute("BEGIN IMMEDIATE", database: database)
        do {
            try operation()
            try execute("COMMIT", database: database)
        } catch {
            try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    private func execute(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        database: OpaquePointer
    ) throws {
        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            try bind(
                binding,
                at: Int32(offset + 1),
                in: statement,
                database: database
            )
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(database)
        }
    }

    private func executeScript(
        _ sql: String,
        database: OpaquePointer
    ) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sql.withCString {
            sqlite3_exec(database, $0, nil, nil, &errorMessage)
        }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw MessageHistoryCacheError.database(message)
        }
    }

    private func prepare(
        _ sql: String,
        database: OpaquePointer
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sql.withCString {
            sqlite3_prepare_v2(database, $0, -1, &statement, nil)
        }
        guard result == SQLITE_OK, let statement else {
            throw databaseError(database)
        }
        return statement
    }

    private func bind(
        _ binding: SQLiteBinding,
        at index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let result: Int32 = switch binding {
        case let .text(value):
            value.withCString {
                sqlite3_bind_text(
                    statement,
                    index,
                    $0,
                    -1,
                    sqliteTransient
                )
            }
        case let .optionalText(value):
            if let value {
                value.withCString {
                    sqlite3_bind_text(
                        statement,
                        index,
                        $0,
                        -1,
                        sqliteTransient
                    )
                }
            } else {
                sqlite3_bind_null(statement, index)
            }
        case let .integer(value):
            sqlite3_bind_int64(statement, index, value)
        case let .optionalInteger(value):
            if let value {
                sqlite3_bind_int64(statement, index, value)
            } else {
                sqlite3_bind_null(statement, index)
            }
        case let .double(value):
            sqlite3_bind_double(statement, index, value)
        case let .optionalDouble(value):
            if let value {
                sqlite3_bind_double(statement, index, value)
            } else {
                sqlite3_bind_null(statement, index)
            }
        case let .blob(value):
            value.withUnsafeBytes {
                sqlite3_bind_blob(
                    statement,
                    index,
                    $0.baseAddress,
                    Int32(value.count),
                    sqliteTransient
                )
            }
        }
        guard result == SQLITE_OK else {
            throw databaseError(database)
        }
    }

    private func bind(
        _ value: String,
        at index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        try bind(
            .text(value),
            at: index,
            in: statement,
            database: database
        )
    }

    private func bind(
        _ value: Int64,
        at index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        try bind(
            .integer(value),
            at: index,
            in: statement,
            database: database
        )
    }

    private func columnText(
        _ statement: OpaquePointer,
        at index: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index)
        else {
            return nil
        }
        return String(cString: text)
    }

    private func columnData(
        _ statement: OpaquePointer,
        at index: Int32
    ) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
    }

    private func databaseError(
        _ database: OpaquePointer
    ) -> MessageHistoryCacheError {
        MessageHistoryCacheError.database(
            String(cString: sqlite3_errmsg(database))
        )
    }
}

private enum SQLiteBinding {
    case text(String)
    case optionalText(String?)
    case integer(Int64)
    case optionalInteger(Int64?)
    case double(Double)
    case optionalDouble(Double?)
    case blob(Data)
}

private final class SQLiteDatabaseHandle: @unchecked Sendable {
    var raw: OpaquePointer?

    deinit {
        if let raw {
            sqlite3_close_v2(raw)
        }
    }
}

private let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
