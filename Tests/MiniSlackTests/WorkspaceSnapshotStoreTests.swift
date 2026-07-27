import Foundation
import Testing
@testable import MiniSlack

struct WorkspaceSnapshotStoreTests {
    @Test
    func snapshotRoundTripsThroughTheStore() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let store = WorkspaceSnapshotStore(workspaceID: "T1", rootURL: rootURL)
        let state = sampleState()

        try await store.save(state)

        let loaded = try #require(await store.load())
        #expect(loaded.savedAt == state.savedAt)
        #expect(loaded.snapshot.users == state.snapshot.users)
        #expect(loaded.snapshot.messageUsers == state.snapshot.messageUsers)
        #expect(loaded.snapshot.conversations == state.snapshot.conversations)
        #expect(loaded.snapshot.customEmojiURLs == state.snapshot.customEmojiURLs)
        #expect(
            loaded.snapshot.readCursorsByConversationID
                == state.snapshot.readCursorsByConversationID
        )
        #expect(
            loaded.snapshot.conversationsWithAuthoritativeUnreadCounts
                == state.snapshot.conversationsWithAuthoritativeUnreadCounts
        )
        #expect(
            loaded.lastPolledAtByConversationID
                == state.lastPolledAtByConversationID
        )
    }

    @Test
    func missingSnapshotLoadsNil() async {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let store = WorkspaceSnapshotStore(workspaceID: "T1", rootURL: rootURL)

        #expect(await store.load() == nil)
    }

    @Test
    func snapshotsAreIsolatedPerWorkspace() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try await WorkspaceSnapshotStore(workspaceID: "T1", rootURL: rootURL)
            .save(sampleState())

        #expect(
            await WorkspaceSnapshotStore(workspaceID: "T2", rootURL: rootURL)
                .load() == nil
        )
        #expect(
            await WorkspaceSnapshotStore(workspaceID: "T1", rootURL: rootURL)
                .load() != nil
        )
    }

    @Test
    func corruptSnapshotLoadsNil() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let directory = rootURL
            .appending(path: "T1", directoryHint: .isDirectory)
            .appending(path: "v1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(
            to: directory.appending(path: "snapshot.json")
        )

        let store = WorkspaceSnapshotStore(workspaceID: "T1", rootURL: rootURL)
        #expect(await store.load() == nil)
    }

    @Test
    func refreshMergeKeepsLocalReadStateWhenLocalCursorIsNewer() {
        let localMessage = sampleMessage(body: "Loaded", timestamp: 950)
        let local = sampleConversation(
            id: "C1",
            title: "general",
            unreadCount: 0,
            mentionCount: 0,
            latestActivity: 950,
            messages: [localMessage]
        )
        let fresh = sampleConversation(
            id: "C1",
            title: "general-renamed",
            unreadCount: 5,
            mentionCount: 2,
            latestActivity: 900
        )

        let merged = AppStore.mergedConversations(
            local: [local],
            fresh: [fresh],
            localCursors: [
                "C1": MessageHistoryReadCursor(
                    remoteID: "950.000000",
                    timestamp: Date(timeIntervalSince1970: 950)
                ),
            ],
            freshCursors: [
                "C1": MessageHistoryReadCursor(
                    remoteID: "900.000000",
                    timestamp: Date(timeIntervalSince1970: 900)
                ),
            ]
        )

        #expect(merged.count == 1)
        #expect(merged[0].title == "general-renamed")
        #expect(merged[0].unreadCount == 0)
        #expect(merged[0].mentionCount == 0)
        #expect(merged[0].messages == [localMessage])
        #expect(merged[0].latestActivity == Date(timeIntervalSince1970: 950))
    }

    @Test
    func refreshMergeAppliesRemoteReadStateWhenRemoteCursorIsNewer() {
        let local = sampleConversation(
            id: "C1",
            title: "general",
            unreadCount: 0,
            mentionCount: 0,
            latestActivity: 900
        )
        let fresh = sampleConversation(
            id: "C1",
            title: "general",
            unreadCount: 5,
            mentionCount: 2,
            latestActivity: 1_000
        )

        let merged = AppStore.mergedConversations(
            local: [local],
            fresh: [fresh],
            localCursors: [
                "C1": MessageHistoryReadCursor(
                    remoteID: "900.000000",
                    timestamp: Date(timeIntervalSince1970: 900)
                ),
            ],
            freshCursors: [
                "C1": MessageHistoryReadCursor(
                    remoteID: "1000.000000",
                    timestamp: Date(timeIntervalSince1970: 1_000)
                ),
            ]
        )

        #expect(merged.count == 1)
        #expect(merged[0].unreadCount == 5)
        #expect(merged[0].mentionCount == 2)
    }

    @Test
    func refreshMergeFollowsFreshMembership() {
        let kept = sampleConversation(id: "C1", title: "general", unreadCount: 1)
        let removed = sampleConversation(id: "C3", title: "gone", unreadCount: 4)
        let added = sampleConversation(id: "C2", title: "new", unreadCount: 7)

        let merged = AppStore.mergedConversations(
            local: [kept, removed],
            fresh: [kept, added],
            localCursors: [:],
            freshCursors: [:]
        )

        #expect(merged.map(\.id) == ["C1", "C2"])
        #expect(merged[1].unreadCount == 7)
    }

    @Test
    func presenceStaleFilterKeepsOnlyMissingOrExpiredAvailability() {
        let now = Date.now
        let fresh = WorkspaceUser(
            id: "U1",
            displayName: "Fresh",
            availability: UserAvailability(
                presence: .active,
                fetchedAt: now.addingTimeInterval(-60)
            )
        )
        let stale = WorkspaceUser(
            id: "U2",
            displayName: "Stale",
            availability: UserAvailability(
                presence: .away,
                fetchedAt: now.addingTimeInterval(-600)
            )
        )
        let missingFetchedAt = WorkspaceUser(id: "U3", displayName: "Unknown")

        let result = AppStore.userIDsWithStalePresence(
            ["U1", "U2", "U3", "U4"],
            usersByID: ["U1": fresh, "U2": stale, "U3": missingFetchedAt],
            now: now,
            freshnessThreshold: 300
        )

        #expect(result == ["U2", "U3", "U4"])
    }

    private func sampleState() -> CachedWorkspaceState {
        let availability = UserAvailability(
            presence: .active,
            customStatus: UserCustomStatus(
                text: "Focus",
                emoji: ":dart:",
                expiresAt: Date(timeIntervalSince1970: 2_000)
            ),
            doNotDisturb: UserDoNotDisturb(
                isEnabled: true,
                endsAt: Date(timeIntervalSince1970: 3_000)
            ),
            fetchedAt: Date(timeIntervalSince1970: 900)
        )
        let user = WorkspaceUser(
            id: "U1",
            displayName: "Maya",
            profileTitle: "Engineer",
            availability: availability,
            avatarURL: URL(string: "https://example.com/avatar.png")
        )
        let conversation = Conversation(
            id: "C1",
            title: "general",
            kind: .channel,
            isPrivate: true,
            subtitle: "3 people",
            isFavorite: true,
            createdAt: Date(timeIntervalSince1970: 100),
            topic: "Topic",
            purpose: "Purpose",
            isArchived: false,
            participantUserID: "U1",
            avatarURL: nil,
            participants: [user],
            unreadCount: 2,
            mentionCount: 1,
            latestActivity: Date(timeIntervalSince1970: 500),
            messages: [sampleMessage(body: "Hello", timestamp: 500)]
        )
        return CachedWorkspaceState(
            savedAt: Date(timeIntervalSince1970: 1_000),
            snapshot: SlackWorkspaceSnapshot(
                users: [user],
                messageUsers: [user],
                conversations: [conversation],
                customEmojiURLs: [
                    "party": URL(string: "https://example.com/emoji.png")!,
                ],
                readCursorsByConversationID: [
                    "C1": MessageHistoryReadCursor(
                        remoteID: "500.000000",
                        timestamp: Date(timeIntervalSince1970: 500)
                    ),
                ],
                conversationsWithAuthoritativeUnreadCounts: ["C1"]
            ),
            lastPolledAtByConversationID: [
                "C1": Date(timeIntervalSince1970: 950),
            ]
        )
    }

    private func sampleConversation(
        id: String,
        title: String,
        unreadCount: Int,
        mentionCount: Int = 0,
        latestActivity: TimeInterval = 900,
        messages: [Message] = []
    ) -> Conversation {
        Conversation(
            id: id,
            title: title,
            kind: .channel,
            isFavorite: false,
            unreadCount: unreadCount,
            mentionCount: mentionCount,
            latestActivity: Date(timeIntervalSince1970: latestActivity),
            messages: messages
        )
    }

    private func sampleMessage(body: String, timestamp: TimeInterval) -> Message {
        Message(
            author: "Maya",
            authorUserID: "U1",
            body: body,
            timestamp: Date(timeIntervalSince1970: timestamp),
            remoteID: "\(timestamp).000000"
        )
    }
}
