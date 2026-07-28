import Foundation
import Testing
@testable import MiniSlack

struct ActivityIndexTests {
    @Test
    func indexesMentionsReactionsAndFollowedThreadsNewestFirst() {
        let mention = Message(
            author: "Maya",
            authorUserID: "U1",
            body: "Hi <@ME>",
            timestamp: Date(timeIntervalSince1970: 300),
            remoteID: "300"
        )
        let reacted = Message(
            author: "You",
            authorUserID: "ME",
            body: "Ship it",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100",
            isCurrentUser: true,
            reactions: [
                Reaction(
                    name: "eyes",
                    emoji: "👀",
                    count: 2,
                    userIDs: ["ME", "U1"],
                    isCurrentUserIncluded: true
                )
            ],
            thread: MessageThreadMetadata(
                rootTimestamp: "100",
                replyCount: 2,
                replyUserIDs: ["U1", "U2"],
                latestReplyAt: Date(timeIntervalSince1970: 200),
                isFollowing: true
            )
        )
        let conversation = conversation(messages: [reacted, mention])

        let index = ActivityIndex(
            conversations: [conversation],
            currentUserID: "ME"
        )

        #expect(index.items.map(\.kind) == [.mention, .threadReply, .reaction])
        #expect(index.items.first?.actorUserIDs == ["U1"])
        #expect(index.items.last?.detail.contains("👀 1") == true)
    }

    @Test
    func mergingThreadUsesLatestReplyAndDeduplicatesActors() {
        let root = Message(
            author: "You",
            authorUserID: "ME",
            body: "Root",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100",
            isCurrentUser: true
        )
        var thread = ThreadState(
            id: ThreadIdentifier(conversationID: "C1", rootTimestamp: "100"),
            root: root
        )
        thread.replies = [
            reply(author: "Maya", userID: "U1", timestamp: 200),
            reply(author: "Maya", userID: "U1", timestamp: 300),
        ]
        var index = ActivityIndex(currentUserID: "ME")

        index.merge(
            thread: thread,
            conversation: conversation(messages: [root]),
            currentUserID: "ME"
        )

        let activity = index.items.first
        #expect(activity?.kind == .threadReply)
        #expect(activity?.date == Date(timeIntervalSince1970: 300))
        #expect(activity?.actorUserIDs == ["U1"])
    }

    @Test
    func boundsTheIndexToItsNewestEntries() {
        var index = ActivityIndex(currentUserID: "ME", capacity: 2)
        let messages = (1 ... 4).map { value in
            Message(
                author: "Maya",
                body: "<@ME> \(value)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(value)),
                remoteID: String(value)
            )
        }

        index.merge(
            messages: messages,
            conversation: conversation(messages: messages),
            currentUserID: "ME"
        )

        #expect(index.items.map(\.date) == [
            Date(timeIntervalSince1970: 4),
            Date(timeIntervalSince1970: 3),
        ])
    }

    @Test
    func aNewReactionCountUsesItsObservationTimeWithoutMovingUnchangedCounts() {
        let original = ownMessage(reactionCount: 1)
        let conversation = conversation(messages: [original])
        var index = ActivityIndex(
            conversations: [conversation],
            currentUserID: "ME"
        )
        let observedAt = Date(timeIntervalSince1970: 500)

        index.merge(
            messages: [ownMessage(reactionCount: 2)],
            conversation: conversation,
            currentUserID: "ME",
            observedAt: observedAt
        )
        #expect(index.items.first?.date == observedAt)

        index.merge(
            messages: [ownMessage(reactionCount: 2)],
            conversation: conversation,
            currentUserID: "ME",
            observedAt: Date(timeIntervalSince1970: 600)
        )
        #expect(index.items.first?.date == observedAt)
    }

    @Test
    func aFirstObservedReactionUsesItsObservationTime() {
        let original = ownMessage(reactionCount: 0)
        let conversation = conversation(messages: [original])
        var index = ActivityIndex(
            conversations: [conversation],
            currentUserID: "ME"
        )
        let observedAt = Date(timeIntervalSince1970: 500)

        index.merge(
            messages: [ownMessage(reactionCount: 1)],
            conversation: conversation,
            currentUserID: "ME",
            observedAt: observedAt
        )

        #expect(index.items.first?.date == observedAt)
    }

    @Test @MainActor
    func openingAnActivityItemFocusesItsMessage() {
        let mention = Message(
            author: "Maya",
            authorUserID: "U1",
            body: "Hi <@ME>",
            timestamp: Date(timeIntervalSince1970: 300),
            remoteID: "300"
        )
        let store = AppStore(conversations: [conversation(messages: [mention])])
        store.resetActivity(
            conversations: store.conversations,
            currentUserID: "ME",
            teamID: nil
        )
        let item = ActivityItem(
            id: "C1:300:mention",
            kind: .mention,
            title: "Maya",
            detail: "Hi you",
            date: mention.timestamp,
            conversationID: "C1",
            conversationTitle: "general",
            messageID: mention.id,
            threadIdentifier: nil,
            actorUserIDs: ["U1"]
        )

        store.openActivity(item, windowState: WindowState())

        #expect(store.destination == .conversation("C1"))
        #expect(store.workspaceSearchFocus?.messageID == mention.id)
    }

    private func conversation(messages: [Message]) -> Conversation {
        Conversation(
            id: "C1",
            title: "general",
            kind: .channel,
            subtitle: nil,
            isFavorite: false,
            unreadCount: 0,
            mentionCount: 0,
            latestActivity: messages.last?.timestamp ?? .distantPast,
            messages: messages
        )
    }

    private func reply(
        author: String,
        userID: String,
        timestamp: TimeInterval
    ) -> Message {
        Message(
            author: author,
            authorUserID: userID,
            body: "Reply \(timestamp)",
            timestamp: Date(timeIntervalSince1970: timestamp),
            remoteID: String(timestamp)
        )
    }

    private func ownMessage(reactionCount: Int) -> Message {
        Message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            author: "You",
            authorUserID: "ME",
            body: "Root",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100",
            isCurrentUser: true,
            reactions: [
                Reaction(
                    name: "eyes",
                    emoji: "👀",
                    count: reactionCount,
                    userIDs: ["U1"]
                )
            ]
        )
    }
}
