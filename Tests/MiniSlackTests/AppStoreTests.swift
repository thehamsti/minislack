import Foundation
import Testing
@testable import MiniSlack

@MainActor
struct AppStoreTests {
    @Test
    func unreadInboxPrioritizesMentionsThenRecentActivity() {
        let conversations = [
            conversation(id: "recent", unread: 1, mentions: 0, activity: 300),
            conversation(id: "mention", unread: 1, mentions: 1, activity: 100),
            conversation(id: "older", unread: 1, mentions: 0, activity: 200),
            conversation(id: "read", unread: 0, mentions: 0, activity: 400),
        ]
        let store = AppStore(conversations: conversations)

        #expect(store.unreadConversations.map(\.id) == ["mention", "recent", "older"])
    }

    @Test
    func unreadNavigationWrapsInBothDirections() {
        let store = AppStore(conversations: [
            conversation(id: "one", unread: 1, activity: 300),
            conversation(id: "two", unread: 1, activity: 200),
        ])

        store.moveToUnread(offset: 1)
        #expect(store.destination == .conversation("one"))

        store.moveToUnread(offset: -1)
        #expect(store.destination == .conversation("two"))
    }

    @Test
    func vimNavigationHighlightsWithoutOpeningFromUnreadInbox() {
        let store = AppStore(conversations: [
            conversation(id: "one", unread: 1, activity: 300),
            conversation(id: "two", unread: 1, activity: 200),
        ])

        #expect(store.keyboardConversationID == "one")

        store.handleKeyboardNavigation(.next)

        #expect(store.keyboardConversationID == "two")
        #expect(store.destination == .unreadInbox)

        store.handleKeyboardNavigation(.open)

        #expect(store.destination == .conversation("two"))
    }

    @Test
    func arrowNavigationMovesBetweenConversationsAndBackToInbox() {
        let store = AppStore(conversations: [
            conversation(id: "one", unread: 1, activity: 300),
            conversation(id: "two", unread: 1, activity: 200),
            conversation(id: "read", unread: 0, activity: 100),
        ])
        store.select("one")

        store.handleKeyboardNavigation(.next)
        #expect(store.destination == .conversation("two"))

        store.handleKeyboardNavigation(.next)
        #expect(store.destination == .conversation("read"))

        store.handleKeyboardNavigation(.back)
        #expect(store.destination == .unreadInbox)
        #expect(store.keyboardConversationID == "one")
    }

    @Test
    func sendingDraftAppendsMessageAndClearsComposer() {
        let store = AppStore(conversations: [
            conversation(id: "channel", unread: 0, activity: 100)
        ])
        store.select("channel")
        store.draft = "  Shipping this today.  "

        store.sendDraft()

        #expect(store.selectedConversation?.messages.last?.body == "Shipping this today.")
        #expect(store.selectedConversation?.messages.last?.isCurrentUser == true)
        #expect(store.draft.isEmpty)
    }

    @Test
    func draftsStayWithTheirConversation() {
        let store = AppStore(conversations: [
            conversation(id: "one", unread: 0, activity: 200),
            conversation(id: "two", unread: 0, activity: 100),
        ])

        store.select("one")
        store.draft = "First draft"
        store.select("two")
        store.draft = "Second draft"

        store.select("one")
        #expect(store.draft == "First draft")
        store.select("two")
        #expect(store.draft == "Second draft")
    }

    @Test
    func markingReadRemovesConversationFromUnreadInbox() {
        let store = AppStore(conversations: [
            conversation(id: "channel", unread: 4, mentions: 2, activity: 100)
        ])
        store.select("channel")

        store.markSelectedConversationRead()

        #expect(store.unreadConversations.isEmpty)
        #expect(store.selectedConversation?.mentionCount == 0)
    }

    @Test
    func markingReadFromInboxAdvancesKeyboardSelectionToNextCard() {
        let store = AppStore(conversations: [
            conversation(id: "one", unread: 1, activity: 300),
            conversation(id: "two", unread: 1, activity: 200),
            conversation(id: "three", unread: 1, activity: 100),
        ])
        store.keyboardConversationID = "two"

        store.markConversationRead("two")

        #expect(store.unreadConversations.map(\.id) == ["one", "three"])
        #expect(store.keyboardConversationID == "three")
        #expect(store.destination == .unreadInbox)
    }

    @Test
    func markingLastInboxCardMovesSelectionToNewLastCard() {
        let store = AppStore(conversations: [
            conversation(id: "one", unread: 1, activity: 300),
            conversation(id: "two", unread: 1, activity: 200),
        ])
        store.keyboardConversationID = "two"

        store.markConversationRead("two")

        #expect(store.keyboardConversationID == "one")
    }

    @Test
    func markingReadFromInboxIsNoOpForReadConversations() {
        let store = AppStore(conversations: [
            conversation(id: "read", unread: 0, activity: 100)
        ])

        store.markConversationRead("read")

        #expect(store.unreadConversations.isEmpty)
        #expect(store.conversations.first?.unreadCount == 0)
    }

    @Test
    func markingVisibleUnreadsReadClearsTheFilteredInbox() {
        let store = AppStore(conversations: [
            conversation(id: "mention", unread: 1, mentions: 1, activity: 300),
            conversation(id: "plain", unread: 2, activity: 200),
        ])
        store.unreadFilters.mentionsOnly = true

        store.markVisibleUnreadsRead()

        #expect(store.conversations.first { $0.id == "mention" }?.unreadCount == 0)
        #expect(store.conversations.first { $0.id == "plain" }?.unreadCount == 2)
    }

    @Test
    func markingAllUnreadsReadEmptiesTheInbox() {
        let store = AppStore(conversations: [
            conversation(id: "one", unread: 1, activity: 300),
            conversation(id: "two", unread: 3, activity: 200),
        ])

        store.markVisibleUnreadsRead()

        #expect(store.unreadConversations.isEmpty)
        #expect(store.keyboardConversationID == nil)
    }

    @Test
    func keyboardNavigationStaysWithinFilteredUnreads() {
        let store = AppStore(conversations: [
            conversation(id: "chan-one", unread: 1, activity: 300),
            conversation(id: "dm-one", kind: .directMessage, unread: 1, activity: 250),
            conversation(id: "dm-two", kind: .directMessage, unread: 1, activity: 200),
        ])
        store.unreadFilters.kind = .directMessages

        #expect(store.keyboardConversationID == "dm-one")

        store.handleKeyboardNavigation(.next)
        #expect(store.keyboardConversationID == "dm-two")

        store.handleKeyboardNavigation(.next)
        #expect(store.keyboardConversationID == "dm-one")
    }

    @Test
    func markReadKeyboardActionMarksHighlightedInboxCard() {
        let store = AppStore(conversations: [
            conversation(id: "one", unread: 1, activity: 300),
            conversation(id: "two", unread: 1, activity: 200),
        ])

        store.handleKeyboardNavigation(.markRead)

        #expect(store.unreadConversations.map(\.id) == ["two"])
        #expect(store.keyboardConversationID == "two")
    }

    @Test
    func markReadKeyboardActionIsInertInsideAConversation() {
        let store = AppStore(conversations: [
            conversation(id: "one", unread: 1, activity: 300)
        ])
        store.select("one")

        store.handleKeyboardNavigation(.markRead)

        #expect(store.conversations.first?.unreadCount == 1)
    }

    @Test
    func quickSwitcherCombinesDirectMessagesGroupsAndChannelsByLatestActivity() {
        let alex = WorkspaceUser(id: "alex", displayName: "Alex Morgan", status: "Active", isActive: true)
        let maya = WorkspaceUser(id: "maya", displayName: "Maya Chen", status: "Product", isActive: true)
        let store = AppStore(
            conversations: [
                conversation(id: "older-channel", unread: 0, activity: 100),
                conversation(id: "newer-channel", unread: 0, activity: 500),
                conversation(
                    id: "dm-alex",
                    kind: .directMessage,
                    unread: 0,
                    activity: 400,
                    participantUserID: "alex"
                ),
                conversation(id: "group-chat", kind: .groupDirectMessage, unread: 0, activity: 300),
            ],
            users: [maya, alex]
        )

        #expect(store.quickSwitcherEntries.map(\.id) == [
            "conversation-newer-channel",
            "user-alex",
            "conversation-group-chat",
            "conversation-older-channel",
            "user-maya",
        ])
    }

    @Test
    func quickSwitcherMergedListFiltersAcrossEveryKind() {
        let maya = WorkspaceUser(id: "maya", displayName: "Maya Chen", status: "Product", isActive: true)
        let store = AppStore(
            conversations: [
                conversation(id: "general", unread: 0, activity: 100),
                conversation(id: "maya-and-alex", kind: .groupDirectMessage, unread: 0, activity: 300),
            ],
            users: [maya]
        )
        store.quickSwitcherQuery = "maya"

        #expect(store.quickSwitcherEntries.map(\.id) == [
            "conversation-maya-and-alex",
            "user-maya",
        ])
    }

    @Test
    func quickSwitcherCanOpenUnreadInbox() {
        let store = AppStore(conversations: [
            conversation(id: "channel", unread: 1, activity: 100)
        ])
        store.select("channel")
        store.quickSwitcherQuery = "unread"

        #expect(store.quickSwitcherShowsUnreads)

        store.openUnreadFromQuickSwitcher()

        #expect(store.destination == .unreadInbox)
        #expect(store.quickSwitcherQuery.isEmpty)
    }

    @Test
    func quickSwitcherPresentationIsWindowScoped() {
        let focusedWindow = WindowState()
        let backgroundWindow = WindowState()

        focusedWindow.presentQuickSwitcher()

        #expect(focusedWindow.isQuickSwitcherPresented)
        #expect(!backgroundWindow.isQuickSwitcherPresented)
    }

    @Test
    func quickSwitcherReopensExistingDirectMessageWithoutDuplication() {
        let user = WorkspaceUser(id: "alex", displayName: "Alex", status: "Active", isActive: true)
        let existingDM = Conversation(
            id: user.id,
            title: user.displayName,
            kind: .directMessage,
            subtitle: user.status,
            isFavorite: false,
            unreadCount: 0,
            mentionCount: 0,
            latestActivity: Date(timeIntervalSince1970: 100),
            messages: []
        )
        let store = AppStore(conversations: [existingDM], users: [user])

        store.startDirectMessage(with: user.id)

        #expect(store.destination == .conversation(user.id))
        #expect(store.conversations.count == 1)
    }

    @Test
    func quickSwitcherCreatesDirectMessageForWorkspaceUser() {
        let user = WorkspaceUser(id: "maya", displayName: "Maya Chen", status: "Product", isActive: true)
        let store = AppStore(conversations: [], users: [user])
        store.quickSwitcherQuery = "maya"

        #expect(store.quickSwitcherEntries.map(\.id) == ["user-maya"])

        store.openFirstQuickSwitcherResult()

        #expect(store.destination == .conversation(user.id))
        #expect(store.selectedConversation?.kind == .directMessage)
        #expect(store.selectedConversation?.title == user.displayName)
    }

    @Test
    func quickSwitcherArrowSelectionMovesAcrossSectionsAndWraps() {
        let user = WorkspaceUser(id: "maya", displayName: "Maya Chen", status: "Product", isActive: true)
        let channel = conversation(id: "general", unread: 0, activity: 100)
        let store = AppStore(conversations: [channel], users: [user])

        store.ensureQuickSwitcherSelection()
        #expect(store.quickSwitcherSelection == .unreads)

        store.moveQuickSwitcherSelection(offset: 1)
        #expect(store.quickSwitcherSelection == .activity)

        store.moveQuickSwitcherSelection(offset: 1)
        #expect(store.quickSwitcherSelection == .saved)

        store.moveQuickSwitcherSelection(offset: 1)
        #expect(store.quickSwitcherSelection == .channel(channel.id))

        store.moveQuickSwitcherSelection(offset: 1)
        #expect(store.quickSwitcherSelection == .user(user.id))

        store.moveQuickSwitcherSelection(offset: 1)
        #expect(store.quickSwitcherSelection == .unreads)

        store.moveQuickSwitcherSelection(offset: -1)
        #expect(store.quickSwitcherSelection == .user(user.id))
    }

    @Test
    func quickSwitcherQueryResetsSelectionToVisibleResult() {
        let users = [
            WorkspaceUser(id: "alex", displayName: "Alex Morgan", status: "Active", isActive: true),
            WorkspaceUser(id: "maya", displayName: "Maya Chen", status: "Product", isActive: true),
        ]
        let store = AppStore(conversations: [], users: users)
        store.quickSwitcherSelection = .user("alex")
        store.quickSwitcherQuery = "maya"

        store.ensureQuickSwitcherSelection()

        #expect(store.quickSwitcherSelection == .user("maya"))
    }

    @Test
    func availabilityUpdatesFlowThroughTheAuthoritativeUserResolver() {
        let user = WorkspaceUser(
            id: "maya",
            displayName: "Maya Chen",
            profileTitle: "Product",
            availability: UserAvailability(
                presence: .unknown,
                customStatus: UserCustomStatus(
                    text: "Heads down",
                    emoji: ":headphones:",
                    expiresAt: nil
                )
            )
        )
        let store = AppStore(conversations: [], users: [user])
        let updated = UserAvailability(
            presence: .away,
            customStatus: user.availability.customStatus,
            doNotDisturb: UserDoNotDisturb(isEnabled: true, endsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 500)
        )

        store.updateAvailability(updated, for: user.id)

        #expect(store.user(withID: user.id)?.availability == updated)
        #expect(store.quickSwitcherEntries.first?.user?.availability == updated)
    }

    @Test
    func conversationSectionsSplitDirectMessagesAndSortByLatestActivity() {
        let store = AppStore(conversations: [
            conversation(id: "older-channel", unread: 0, activity: 100),
            conversation(id: "newer-channel", unread: 0, activity: 400),
            conversation(id: "older-dm", kind: .directMessage, unread: 0, activity: 200),
            conversation(id: "newer-dm", kind: .directMessage, unread: 0, activity: 500),
            conversation(id: "older-group", kind: .groupDirectMessage, unread: 0, activity: 300),
            conversation(id: "newer-group", kind: .groupDirectMessage, unread: 0, activity: 600),
            conversation(id: "older-favorite", favorite: true, unread: 0, activity: 150),
            conversation(id: "newer-favorite", favorite: true, unread: 0, activity: 550),
        ])

        #expect(store.channelConversations.map(\.id) == ["newer-channel", "older-channel"])
        #expect(store.directConversations.map(\.id) == ["newer-dm", "older-dm"])
        #expect(store.groupDirectConversations.map(\.id) == ["newer-group", "older-group"])
        #expect(store.favoriteConversations.map(\.id) == ["newer-favorite", "older-favorite"])
    }

    @Test
    func eachConversationSectionSupportsIndependentSortOptions() {
        let store = AppStore(conversations: [
            conversation(id: "Zulu", creation: 100, unread: 0, activity: 300),
            conversation(id: "Alpha", creation: 300, unread: 0, activity: 100),
            conversation(id: "Mike", creation: 200, unread: 0, activity: 200),
        ])

        #expect(store.sortedChannelConversations(by: .name).map(\.id) == ["Alpha", "Mike", "Zulu"])
        #expect(store.sortedChannelConversations(by: .activity).map(\.id) == ["Zulu", "Mike", "Alpha"])
        #expect(store.sortedChannelConversations(by: .creation).map(\.id) == ["Alpha", "Mike", "Zulu"])
    }

    private func conversation(
        id: String,
        kind: ConversationKind = .channel,
        favorite: Bool = false,
        creation: TimeInterval = 0,
        unread: Int,
        mentions: Int = 0,
        activity: TimeInterval,
        participantUserID: String? = nil
    ) -> Conversation {
        Conversation(
            id: id,
            title: id,
            kind: kind,
            subtitle: nil,
            isFavorite: favorite,
            createdAt: Date(timeIntervalSince1970: creation),
            participantUserID: participantUserID,
            unreadCount: unread,
            mentionCount: mentions,
            latestActivity: Date(timeIntervalSince1970: activity),
            messages: []
        )
    }
}
