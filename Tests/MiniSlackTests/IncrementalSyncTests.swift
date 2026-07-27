import Foundation
import Testing
@testable import MiniSlack

struct IncrementalSyncTests {
    @Test
    func staleRemoteZeroCannotClearMessagesNewerThanReadCursor() {
        let message = Message(
            author: "Maya",
            authorUserID: "U2",
            body: "Please check this <@U1>",
            timestamp: Date(timeIntervalSince1970: 101),
            remoteID: "101.000000"
        )

        let result = UnreadCountReconciliation.reconcile(
            remoteUnreadCount: 0,
            currentUnreadCount: 1,
            currentMentionCount: 1,
            messages: [message],
            readCursor: MessageHistoryReadCursor(
                remoteID: "100.000000",
                timestamp: Date(timeIntervalSince1970: 100)
            ),
            currentUserID: "U1"
        )

        #expect(result.unreadCount == 1)
        #expect(result.mentionCount == 1)
    }

    @Test
    func advancedReadCursorClearsLocallyObservedUnread() {
        let message = Message(
            author: "Maya",
            authorUserID: "U2",
            body: "Already read",
            timestamp: Date(timeIntervalSince1970: 101),
            remoteID: "101.000000"
        )

        let result = UnreadCountReconciliation.reconcile(
            remoteUnreadCount: 0,
            currentUnreadCount: 1,
            currentMentionCount: 0,
            messages: [message],
            readCursor: MessageHistoryReadCursor(
                remoteID: "101.000000",
                timestamp: Date(timeIntervalSince1970: 101)
            ),
            currentUserID: "U1"
        )

        #expect(result.unreadCount == 0)
        #expect(result.mentionCount == 0)
    }

    private let startedAt = Date(timeIntervalSince1970: 1_000)

    @Test
    func offModeDoesNotScheduleRequests() {
        var scheduler = IncrementalSyncScheduler(startedAt: startedAt)

        let decision = scheduler.nextDecision(
            now: startedAt.addingTimeInterval(10_000),
            mode: .off,
            conversations: [conversation("C1")],
            selectedConversationID: "C1"
        )

        #expect(decision == nil)
    }

    @Test
    func seededLastPolledAtSkipsInitialPollUrgency() {
        var recentlyPolled = IncrementalSyncScheduler(
            startedAt: startedAt,
            lastPolledAt: ["C1": startedAt]
        )

        #expect(
            recentlyPolled.nextDecision(
                now: startedAt.addingTimeInterval(60),
                mode: .conservative,
                conversations: [conversation("C1")],
                selectedConversationID: nil
            ) == nil
        )

        var stalePoll = IncrementalSyncScheduler(
            startedAt: startedAt,
            lastPolledAt: ["C1": startedAt]
        )
        let dueDecision = stalePoll.nextDecision(
            now: startedAt.addingTimeInterval(1_000),
            mode: .conservative,
            conversations: [conversation("C1")],
            selectedConversationID: nil
        )
        #expect(dueDecision?.conversationID == "C1")
        #expect(dueDecision?.isInitialPoll == false)

        var unseeded = IncrementalSyncScheduler(startedAt: startedAt)
        #expect(
            unseeded.nextDecision(
                now: startedAt.addingTimeInterval(60),
                mode: .conservative,
                conversations: [conversation("C1")],
                selectedConversationID: nil
            )?.isInitialPoll == true
        )
    }

    @Test
    func initialPollingPrioritizesSelectedThenUnreadConversations() {
        var scheduler = IncrementalSyncScheduler(startedAt: startedAt)
        let conversations = [
            conversation("C1"),
            conversation("C2", isUnread: true),
            conversation("C3"),
        ]

        let selected = scheduler.nextDecision(
            now: startedAt,
            mode: .responsive,
            conversations: conversations,
            selectedConversationID: "C1"
        )
        let unread = scheduler.nextDecision(
            now: startedAt,
            mode: .responsive,
            conversations: conversations,
            selectedConversationID: "C1"
        )
        let background = scheduler.nextDecision(
            now: startedAt,
            mode: .responsive,
            conversations: conversations,
            selectedConversationID: "C1"
        )

        #expect(
            selected
                == IncrementalSyncDecision(
                    conversationID: "C1",
                    priority: .selected,
                    isInitialPoll: true
                )
        )
        #expect(
            unread
                == IncrementalSyncDecision(
                    conversationID: "C2",
                    priority: .unread,
                    isInitialPoll: true
                )
        )
        #expect(
            background
                == IncrementalSyncDecision(
                    conversationID: "C3",
                    priority: .background,
                    isInitialPoll: true
                )
        )
    }

    @Test
    func backgroundPollingWaitsForItsBudgetAndRotatesConversations() {
        var scheduler = IncrementalSyncScheduler(startedAt: startedAt)
        let conversations = [
            conversation("C1", latestActivityOffset: 30),
            conversation("C2", latestActivityOffset: 20),
            conversation("C3", latestActivityOffset: 10),
        ]

        let initialFirst = scheduler.nextDecision(
            now: startedAt,
            mode: .responsive,
            conversations: conversations,
            selectedConversationID: nil
        )
        let initialSecond = scheduler.nextDecision(
            now: startedAt,
            mode: .responsive,
            conversations: conversations,
            selectedConversationID: nil
        )
        let initialThird = scheduler.nextDecision(
            now: startedAt,
            mode: .responsive,
            conversations: conversations,
            selectedConversationID: nil
        )
        let tooSoon = scheduler.nextDecision(
            now: startedAt.addingTimeInterval(299),
            mode: .responsive,
            conversations: conversations,
            selectedConversationID: nil
        )
        let firstRefresh = scheduler.nextDecision(
            now: startedAt.addingTimeInterval(300),
            mode: .responsive,
            conversations: conversations,
            selectedConversationID: nil
        )

        #expect(initialFirst?.conversationID == "C1")
        #expect(initialSecond?.conversationID == "C2")
        #expect(initialThird?.conversationID == "C3")
        #expect(initialFirst?.priority == .background)
        #expect(initialFirst?.isInitialPoll == true)
        #expect(tooSoon == nil)
        #expect(firstRefresh?.conversationID == "C1")
        #expect(firstRefresh?.priority == .background)
        #expect(firstRefresh?.isInitialPoll == false)
    }

    @Test(
        arguments: [
            MessageNotificationContext(
                isInitialPoll: true,
                isCurrentUserMessage: false,
                authorUserID: "U2",
                currentUserID: "U1",
                isConversationFocused: false,
                isCurrentUserDoNotDisturb: false,
                isConversationMuted: false
            ),
            MessageNotificationContext(
                isInitialPoll: false,
                isCurrentUserMessage: false,
                authorUserID: "U1",
                currentUserID: "U1",
                isConversationFocused: false,
                isCurrentUserDoNotDisturb: false,
                isConversationMuted: false
            ),
            MessageNotificationContext(
                isInitialPoll: false,
                isCurrentUserMessage: true,
                authorUserID: nil,
                currentUserID: "U1",
                isConversationFocused: false,
                isCurrentUserDoNotDisturb: false,
                isConversationMuted: false
            ),
            MessageNotificationContext(
                isInitialPoll: false,
                isCurrentUserMessage: false,
                authorUserID: "U2",
                currentUserID: "U1",
                isConversationFocused: true,
                isCurrentUserDoNotDisturb: false,
                isConversationMuted: false
            ),
            MessageNotificationContext(
                isInitialPoll: false,
                isCurrentUserMessage: false,
                authorUserID: "U2",
                currentUserID: "U1",
                isConversationFocused: false,
                isCurrentUserDoNotDisturb: true,
                isConversationMuted: false
            ),
            MessageNotificationContext(
                isInitialPoll: false,
                isCurrentUserMessage: false,
                authorUserID: "U2",
                currentUserID: "U1",
                isConversationFocused: false,
                isCurrentUserDoNotDisturb: false,
                isConversationMuted: true
            ),
        ]
    )
    func notificationPolicySuppressesIneligibleMessages(context: MessageNotificationContext) {
        #expect(!MessageNotificationPolicy.shouldNotify(context))
    }

    @Test
    func notificationPolicyAllowsNewBackgroundMessages() {
        let context = MessageNotificationContext(
            isInitialPoll: false,
            isCurrentUserMessage: false,
            authorUserID: "U2",
            currentUserID: "U1",
            isConversationFocused: false,
            isCurrentUserDoNotDisturb: false,
            isConversationMuted: false
        )

        #expect(MessageNotificationPolicy.shouldNotify(context))
    }

    @Test
    func initialPollOnlyTreatsMessagesAfterSyncStartAsNew() {
        let messages = [
            message(remoteID: "999.0"),
            message(remoteID: "1001.0"),
        ]

        let detected = IncrementalMessageDetector.newMessages(
            in: messages,
            excludingRemoteIDs: [],
            latestKnownTimestamp: .distantPast,
            syncStartedAt: Date(timeIntervalSince1970: 1_000),
            isInitialPoll: true
        )

        #expect(detected.compactMap(\.remoteID) == ["1001.0"])
    }

    @Test
    func remoteHighWatermarkIgnoresUnsyncedLocalTimestamps() {
        let existing = [
            message(remoteID: "1000.0"),
            Message(
                author: "You",
                body: "Optimistic",
                timestamp: Date(timeIntervalSince1970: 5_000),
                isCurrentUser: true
            ),
        ]
        let latestRemoteTimestamp = IncrementalMessageDetector.latestRemoteTimestamp(
            in: existing
        )

        let detected = IncrementalMessageDetector.newMessages(
            in: [message(remoteID: "1001.0")],
            excludingRemoteIDs: Set(existing.compactMap(\.remoteID)),
            latestKnownTimestamp: latestRemoteTimestamp,
            syncStartedAt: startedAt,
            isInitialPoll: false
        )

        #expect(latestRemoteTimestamp == Date(timeIntervalSince1970: 1_000))
        #expect(detected.compactMap(\.remoteID) == ["1001.0"])
    }

    @Test
    func dockBadgeUsesCompactLabels() {
        #expect(DockBadgeFormatter.label(unreadCount: 0) == nil)
        #expect(DockBadgeFormatter.label(unreadCount: 8) == "8")
        #expect(DockBadgeFormatter.label(unreadCount: 99) == "99")
        #expect(DockBadgeFormatter.label(unreadCount: 100) == "99+")
    }

    private func conversation(
        _ id: String,
        isUnread: Bool = false,
        latestActivityOffset: TimeInterval = 0
    ) -> IncrementalSyncConversation {
        IncrementalSyncConversation(
            id: id,
            isUnread: isUnread,
            latestActivity: startedAt.addingTimeInterval(latestActivityOffset)
        )
    }

    private func message(remoteID: String) -> Message {
        Message(
            author: "Maya",
            body: remoteID,
            timestamp: Date(timeIntervalSince1970: Double(remoteID) ?? 0),
            remoteID: remoteID
        )
    }
}
