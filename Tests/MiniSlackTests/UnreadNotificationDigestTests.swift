import Foundation
import Testing
@testable import MiniSlack

struct UnreadNotificationDigestTests {
    @Test
    func countsAggregateUnreadConversationsMessagesAndMentions() {
        let digest = UnreadNotificationDigest.counts(for: [
            conversation(id: "one", unread: 3, mentions: 1),
            conversation(id: "two", unread: 2, mentions: 0),
            conversation(id: "read", unread: 0, mentions: 0),
        ])

        #expect(digest.conversationCount == 2)
        #expect(digest.messageCount == 5)
        #expect(digest.mentionCount == 1)
        #expect(digest.badgeLabel == "5")
        #expect(digest.summary == "2 conversations · 5 unread · 1 mention")
    }

    @Test
    func badgeLabelStaysCompactForBusyWorkspaces() {
        #expect(UnreadNotificationDigest.counts(for: []).badgeLabel == nil)
        #expect(
            UnreadNotificationDigest
                .counts(for: [conversation(id: "one", unread: 99)])
                .badgeLabel == "99"
        )
        #expect(
            UnreadNotificationDigest
                .counts(for: [conversation(id: "one", unread: 250)])
                .badgeLabel == "99+"
        )
    }

    @Test
    func digestListsMentionsFirstThenNewestMessages() {
        let mention = message(body: "ping <@ME>", at: 100)
        let newest = message(body: "newest", at: 300)
        let older = message(body: "older", at: 200)
        let conversations = [
            conversation(id: "chan", unread: 2, mentions: 1, messages: [mention, older]),
            conversation(id: "dm", kind: .directMessage, unread: 1, messages: [newest]),
        ]

        let digest = UnreadNotificationDigest.make(
            conversations: conversations,
            currentUserID: "ME",
            unreadMessages: { $0.messages },
            resolveUser: { _ in nil }
        )

        #expect(digest.entries.map(\.preview) == ["ping <@ME>", "newest", "older"])
        #expect(digest.entries.first?.isMention == true)
        #expect(digest.entries.first?.conversationID == "chan")
    }

    @Test
    func digestSkipsOwnAndDeletedMessagesAndBoundsEachConversation() {
        let messages = [
            message(body: "mine", at: 100, isCurrentUser: true),
            message(body: "gone", at: 110, isDeleted: true),
        ] + (0..<6).map { message(body: "reply \($0)", at: 200 + Double($0)) }

        let digest = UnreadNotificationDigest.make(
            conversations: [conversation(id: "chan", unread: 8, messages: messages)],
            currentUserID: "ME",
            unreadMessages: { $0.messages },
            resolveUser: { _ in nil }
        )

        #expect(digest.entries.count == UnreadNotificationDigest.maximumEntriesPerConversation)
        #expect(digest.entries.map(\.preview) == ["reply 5", "reply 4", "reply 3", "reply 2"])
        #expect(digest.hiddenMessageCount == 4)
    }

    @Test
    func digestBoundsTheTotalEntryCount() {
        let conversations = (0..<20).map { index in
            conversation(
                id: "chan\(index)",
                unread: 4,
                messages: (0..<4).map { message(body: "m\($0)", at: 100 + Double($0)) }
            )
        }

        let digest = UnreadNotificationDigest.make(
            conversations: conversations,
            currentUserID: nil,
            unreadMessages: { $0.messages },
            resolveUser: { _ in nil }
        )

        #expect(digest.entries.count == UnreadNotificationDigest.maximumEntryCount)
        #expect(digest.messageCount == 80)
        #expect(digest.hiddenMessageCount == 40)
    }

    @Test
    func digestResolvesAuthorIdentityFromWorkspaceUsers() {
        let digest = UnreadNotificationDigest.make(
            conversations: [
                conversation(
                    id: "chan",
                    unread: 1,
                    messages: [message(body: "hello", at: 100, authorUserID: "U1")]
                ),
            ],
            currentUserID: "ME",
            unreadMessages: { $0.messages },
            resolveUser: { id in
                id == "U1"
                    ? WorkspaceUser(id: "U1", displayName: "Maya Chen")
                    : nil
            }
        )

        #expect(digest.entries.first?.authorDisplayName == "Maya Chen")
        #expect(digest.entries.first?.authorInitials == "MC")
    }

    @Test
    func mentionDetectionCoversDirectMentionsAndBroadcasts() {
        #expect(message(body: "hey <@ME> look", at: 100).mentions(userID: "ME"))
        #expect(!message(body: "hey <@OTHER>", at: 100).mentions(userID: "ME"))
        #expect(message(body: "<!here> deploy", at: 100).mentions(userID: "ME"))
        #expect(message(body: "<!channel|@channel> ship", at: 100).mentions(userID: nil))
        #expect(!message(body: "<@ME>", at: 100, isCurrentUser: true).mentions(userID: "ME"))
        #expect(!message(body: "<@ME>", at: 100, isDeleted: true).mentions(userID: "ME"))
    }

    @Test
    func previewCollapsesWhitespaceAndTruncatesLongBodies() {
        let wrapped = message(body: "first line\n\nsecond   line", at: 100)
        #expect(UnreadNotificationDigest.previewText(for: wrapped) == "first line second line")

        let long = message(
            body: String(repeating: "a", count: UnreadNotificationDigest.maximumPreviewLength + 20),
            at: 100
        )
        let preview = UnreadNotificationDigest.previewText(for: long)
        #expect(preview.count == UnreadNotificationDigest.maximumPreviewLength + 1)
        #expect(preview.hasSuffix("…"))
    }

    @Test
    func shortRelativeLabelsStayNarrowInTheNotificationList() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let label = { (offset: TimeInterval) in
            UnreadNotificationDigest.shortRelativeLabel(
                for: now.addingTimeInterval(-offset),
                now: now
            )
        }

        #expect(label(5) == "now")
        #expect(label(59) == "now")
        #expect(label(60) == "1m")
        #expect(label(12 * 60 + 37) == "12m")
        #expect(label(3_600) == "1h")
        #expect(label(86_399) == "23h")
        #expect(label(3 * 86_400) == "3d")
    }

    @Test
    func emptyDigestDescribesTheCaughtUpState() {
        let digest = UnreadNotificationDigest.counts(for: [conversation(id: "read", unread: 0)])

        #expect(digest.isEmpty)
        #expect(digest.summary == "No unread messages")
        #expect(digest.accessibilityLabel == "Unread messages: none")
        #expect(digest.hiddenMessageCount == 0)
    }

    private func conversation(
        id: String,
        kind: ConversationKind = .channel,
        unread: Int = 1,
        mentions: Int = 0,
        messages: [Message] = []
    ) -> Conversation {
        Conversation(
            id: id,
            title: id,
            kind: kind,
            subtitle: nil,
            isFavorite: false,
            unreadCount: unread,
            mentionCount: mentions,
            latestActivity: Date(timeIntervalSince1970: 100),
            messages: messages
        )
    }

    private func message(
        body: String,
        at offset: TimeInterval,
        authorUserID: String? = "U1",
        isCurrentUser: Bool = false,
        isDeleted: Bool = false
    ) -> Message {
        Message(
            author: "Maya Chen",
            authorUserID: authorUserID,
            body: body,
            timestamp: Date(timeIntervalSince1970: offset),
            isCurrentUser: isCurrentUser,
            isDeleted: isDeleted
        )
    }
}

@MainActor
struct UnreadNotificationNavigationTests {
    @Test
    func openingAnUnreadNotificationSelectsAndFocusesTheMessage() throws {
        let unreadMessage = Message(
            author: "Maya Chen",
            authorUserID: "U1",
            body: "ship it",
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let store = AppStore(conversations: [
            Conversation(
                id: "chan",
                title: "chan",
                kind: .channel,
                subtitle: nil,
                isFavorite: false,
                unreadCount: 1,
                mentionCount: 0,
                latestActivity: Date(timeIntervalSince1970: 100),
                messages: [unreadMessage]
            ),
        ])

        let digest = store.makeUnreadNotificationDigest()
        let entry = try #require(digest.entries.first)
        store.openUnreadNotification(entry)

        #expect(store.destination == .conversation("chan"))
        #expect(store.workspaceSearchFocus?.messageID == unreadMessage.id)
        #expect(store.workspaceSearchFocus?.conversationID == "chan")
    }

    @Test
    func markingAnUnreadNotificationReadKeepsNewerMessagesUnread() throws {
        let older = Message(
            author: "Maya Chen",
            authorUserID: "U1",
            body: "older",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100.000000"
        )
        let middle = Message(
            author: "Maya Chen",
            authorUserID: "U1",
            body: "middle",
            timestamp: Date(timeIntervalSince1970: 200),
            remoteID: "200.000000"
        )
        let newest = Message(
            author: "Maya Chen",
            authorUserID: "U1",
            body: "newest",
            timestamp: Date(timeIntervalSince1970: 300),
            remoteID: "300.000000"
        )
        let store = AppStore(conversations: [
            Conversation(
                id: "chan",
                title: "chan",
                kind: .channel,
                subtitle: nil,
                isFavorite: false,
                unreadCount: 3,
                mentionCount: 0,
                latestActivity: Date(timeIntervalSince1970: 300),
                messages: [older, middle, newest]
            ),
        ])

        let digest = store.makeUnreadNotificationDigest()
        let middleEntry = try #require(digest.entries.first { $0.preview == "middle" })
        store.markUnreadNotificationRead(middleEntry)

        let conversation = try #require(store.conversations.first { $0.id == "chan" })
        #expect(conversation.unreadCount == 1)
        #expect(conversation.mentionCount == 0)
        #expect(store.readCursorsByConversationID["chan"]?.remoteID == "200.000000")
        #expect(store.readCursorsByConversationID["chan"]?.timestamp == middle.timestamp)
        #expect(store.unreadMessages(for: conversation).map(\.body) == ["newest"])
        #expect(store.makeUnreadNotificationDigest().entries.map(\.preview) == ["newest"])
        #expect(store.destination == .unreadInbox)
    }

    @Test
    func markingTheLatestUnreadNotificationReadClearsTheConversation() throws {
        let first = Message(
            author: "Maya Chen",
            authorUserID: "U1",
            body: "first",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100.000000"
        )
        let latest = Message(
            author: "Maya Chen",
            authorUserID: "U1",
            body: "latest",
            timestamp: Date(timeIntervalSince1970: 200),
            remoteID: "200.000000"
        )
        let store = AppStore(conversations: [
            Conversation(
                id: "chan",
                title: "chan",
                kind: .channel,
                subtitle: nil,
                isFavorite: false,
                unreadCount: 2,
                mentionCount: 0,
                latestActivity: Date(timeIntervalSince1970: 200),
                messages: [first, latest]
            ),
        ])

        let digest = store.makeUnreadNotificationDigest()
        let latestEntry = try #require(digest.entries.first { $0.preview == "latest" })
        store.markUnreadNotificationRead(latestEntry)

        let conversation = try #require(store.conversations.first { $0.id == "chan" })
        #expect(conversation.unreadCount == 0)
        #expect(conversation.mentionCount == 0)
        #expect(store.unreadConversations.isEmpty)
        #expect(store.makeUnreadNotificationDigest().isEmpty)
    }

    @Test
    func markingAnUnreadNotificationReadIsNoOpWhenAlreadyBehindCursor() throws {
        let older = Message(
            author: "Maya Chen",
            authorUserID: "U1",
            body: "older",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100.000000"
        )
        let mid = Message(
            author: "Maya Chen",
            authorUserID: "U1",
            body: "mid",
            timestamp: Date(timeIntervalSince1970: 200),
            remoteID: "200.000000"
        )
        let newer = Message(
            author: "Maya Chen",
            authorUserID: "U1",
            body: "newer",
            timestamp: Date(timeIntervalSince1970: 300),
            remoteID: "300.000000"
        )
        let store = AppStore(conversations: [
            Conversation(
                id: "chan",
                title: "chan",
                kind: .channel,
                subtitle: nil,
                isFavorite: false,
                unreadCount: 1,
                mentionCount: 0,
                latestActivity: Date(timeIntervalSince1970: 300),
                messages: [older, mid, newer]
            ),
        ])
        store.readCursorsByConversationID["chan"] = MessageHistoryReadCursor(
            remoteID: "200.000000",
            timestamp: mid.timestamp
        )

        let staleEntry = UnreadNotificationEntry(
            messageID: older.id,
            conversationID: "chan",
            conversationTitle: "chan",
            conversationSystemImage: "number",
            isDirectMessage: false,
            authorDisplayName: "Maya Chen",
            authorInitials: "MC",
            authorAvatarURL: nil,
            preview: "older",
            timestamp: older.timestamp,
            isMention: false
        )
        store.markUnreadNotificationRead(staleEntry)

        #expect(store.conversations.first?.unreadCount == 1)
        #expect(store.readCursorsByConversationID["chan"]?.remoteID == "200.000000")
        #expect(
            store.unreadMessages(for: store.conversations[0]).map(\.body) == ["newer"]
        )
    }

    @Test
    func markingAnUnreadNotificationReadRecalculatesMentions() throws {
        let mention = Message(
            author: "Maya Chen",
            authorUserID: "U1",
            body: "ping <@ME>",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100.000000"
        )
        let plain = Message(
            author: "Maya Chen",
            authorUserID: "U1",
            body: "plain",
            timestamp: Date(timeIntervalSince1970: 200),
            remoteID: "200.000000"
        )
        let store = AppStore(
            conversations: [
                Conversation(
                    id: "chan",
                    title: "chan",
                    kind: .channel,
                    subtitle: nil,
                    isFavorite: false,
                    unreadCount: 2,
                    mentionCount: 1,
                    latestActivity: Date(timeIntervalSince1970: 200),
                    messages: [mention, plain]
                ),
            ],
            credentials: SlackCredentials(
                accessToken: "xoxp-test",
                refreshToken: "xoxe-test",
                expiresAt: .distantFuture,
                teamID: "T1",
                teamName: "Team",
                userID: "ME"
            )
        )

        let digest = store.makeUnreadNotificationDigest()
        let mentionEntry = try #require(digest.entries.first { $0.isMention })
        store.markUnreadNotificationRead(mentionEntry)

        let conversation = try #require(store.conversations.first { $0.id == "chan" })
        #expect(conversation.unreadCount == 1)
        #expect(conversation.mentionCount == 0)
        #expect(store.makeUnreadNotificationDigest().entries.map(\.preview) == ["plain"])
    }
}
