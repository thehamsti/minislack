import Foundation

enum ActivityKind: String, CaseIterable, Identifiable, Sendable {
    case mention
    case reaction
    case threadReply

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .mention:
            "Mentions"
        case .reaction:
            "Reactions"
        case .threadReply:
            "Threads"
        }
    }

    var systemImage: String {
        switch self {
        case .mention:
            "at"
        case .reaction:
            "face.smiling"
        case .threadReply:
            "bubble.left.and.bubble.right"
        }
    }
}

struct ActivityItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: ActivityKind
    let title: String
    let detail: String
    let date: Date
    let conversationID: String
    let conversationTitle: String
    let messageID: UUID
    let threadIdentifier: ThreadIdentifier?
    let actorUserIDs: [String]
}

struct ActivityIndex: Sendable {
    private var itemsByID: [String: ActivityItem] = [:]
    private var receivedReactionCountsByMessageID: [String: Int] = [:]
    private let capacity: Int

    init(
        conversations: [Conversation] = [],
        currentUserID: String? = nil,
        capacity: Int = 500
    ) {
        self.capacity = max(1, capacity)
        for conversation in conversations {
            merge(
                messages: conversation.messages,
                conversation: conversation,
                currentUserID: currentUserID
            )
        }
    }

    var items: [ActivityItem] {
        itemsByID.values.sorted {
            if $0.date != $1.date {
                return $0.date > $1.date
            }
            return $0.id < $1.id
        }
    }

    mutating func reset(
        conversations: [Conversation],
        currentUserID: String?
    ) {
        itemsByID = [:]
        receivedReactionCountsByMessageID = [:]
        for conversation in conversations {
            merge(
                messages: conversation.messages,
                conversation: conversation,
                currentUserID: currentUserID
            )
        }
    }

    mutating func merge(
        messages: [Message],
        conversation: Conversation,
        currentUserID: String?,
        observedAt: Date? = nil
    ) {
        for message in messages {
            merge(
                message: message,
                conversation: conversation,
                currentUserID: currentUserID,
                observedAt: observedAt
            )
        }
        trimIfNeeded()
    }

    mutating func merge(
        thread: ThreadState,
        conversation: Conversation,
        currentUserID: String?
    ) {
        let otherReplies = thread.replies.filter { !$0.isCurrentUser && !$0.isDeleted }
        let identifier = thread.id
        let activityID = threadID(identifier)
        if (thread.root.isCurrentUser || thread.isFollowing),
           let latest = otherReplies.last
        {
            itemsByID[activityID] = ActivityItem(
                id: activityID,
                kind: .threadReply,
                title: "\(otherReplies.count) \(otherReplies.count == 1 ? "reply" : "replies") in #\(conversation.title)",
                detail: latest.compactPreviewText,
                date: latest.timestamp,
                conversationID: conversation.id,
                conversationTitle: conversation.title,
                messageID: thread.root.id,
                threadIdentifier: identifier,
                actorUserIDs: unique(otherReplies.compactMap(\.authorUserID))
            )
        } else {
            itemsByID[activityID] = nil
        }
        merge(
            messages: thread.replies,
            conversation: conversation,
            currentUserID: currentUserID,
            observedAt: nil
        )
        trimIfNeeded()
    }

    private mutating func merge(
        message: Message,
        conversation: Conversation,
        currentUserID: String?,
        observedAt: Date?
    ) {
        let messageKey = message.remoteID ?? message.id.uuidString

        if !message.isCurrentUser,
           !message.isDeleted,
           let currentUserID,
           message.body.contains("<@\(currentUserID)>")
        {
            let id = "mention:\(conversation.id):\(messageKey)"
            itemsByID[id] = ActivityItem(
                id: id,
                kind: .mention,
                title: "\(message.author) mentioned you",
                detail: message.compactPreviewText,
                date: message.timestamp,
                conversationID: conversation.id,
                conversationTitle: conversation.title,
                messageID: message.id,
                threadIdentifier: message.thread.map {
                    ThreadIdentifier(
                        conversationID: conversation.id,
                        rootTimestamp: $0.rootTimestamp
                    )
                },
                actorUserIDs: message.authorUserID.map { [$0] } ?? []
            )
        }

        let receivedReactions = message.reactions.filter {
            $0.count - ($0.isCurrentUserIncluded ? 1 : 0) > 0
        }
        let reactionID = "reaction:\(conversation.id):\(messageKey)"
        let receivedReactionCount = receivedReactions.reduce(0) {
            $0 + $1.count - ($1.isCurrentUserIncluded ? 1 : 0)
        }
        if message.isCurrentUser, !message.isDeleted, !receivedReactions.isEmpty {
            let previousReactionCount =
                receivedReactionCountsByMessageID[reactionID]
            receivedReactionCountsByMessageID[reactionID] = receivedReactionCount
            let summary = receivedReactions
                .prefix(6)
                .map {
                    let otherCount = $0.count - ($0.isCurrentUserIncluded ? 1 : 0)
                    return "\($0.emoji) \(otherCount)"
                }
                .joined(separator: "  ")
            let date =
                if let observedAt,
                   receivedReactionCount > (previousReactionCount ?? 0)
                {
                    observedAt
                } else {
                    itemsByID[reactionID]?.date ?? message.timestamp
                }
            itemsByID[reactionID] = ActivityItem(
                id: reactionID,
                kind: .reaction,
                title: "New reactions in #\(conversation.title)",
                detail: "\(summary) · \(message.compactPreviewText)",
                date: date,
                conversationID: conversation.id,
                conversationTitle: conversation.title,
                messageID: message.id,
                threadIdentifier: message.thread.map {
                    ThreadIdentifier(
                        conversationID: conversation.id,
                        rootTimestamp: $0.rootTimestamp
                    )
                },
                actorUserIDs: unique(receivedReactions.flatMap(\.userIDs))
            )
        } else {
            itemsByID[reactionID] = nil
            receivedReactionCountsByMessageID[reactionID] = nil
        }

        if let thread = message.thread,
           thread.replyCount > 0,
           message.isCurrentUser || thread.isFollowing
        {
            let identifier = ThreadIdentifier(
                conversationID: conversation.id,
                rootTimestamp: thread.rootTimestamp
            )
            let id = threadID(identifier)
            itemsByID[id] = ActivityItem(
                id: id,
                kind: .threadReply,
                title: "\(thread.replyCount) \(thread.replyCount == 1 ? "reply" : "replies") in #\(conversation.title)",
                detail: message.compactPreviewText,
                date: thread.latestReplyAt ?? message.timestamp,
                conversationID: conversation.id,
                conversationTitle: conversation.title,
                messageID: message.id,
                threadIdentifier: identifier,
                actorUserIDs: unique(thread.replyUserIDs)
            )
        }
    }

    private mutating func trimIfNeeded() {
        guard itemsByID.count > capacity else {
            return
        }
        let retainedIDs = Set(items.prefix(capacity).map(\.id))
        itemsByID = itemsByID.filter { retainedIDs.contains($0.key) }
        receivedReactionCountsByMessageID = receivedReactionCountsByMessageID.filter {
            retainedIDs.contains($0.key)
        }
    }

    private func threadID(_ identifier: ThreadIdentifier) -> String {
        "thread:\(identifier.conversationID):\(identifier.rootTimestamp)"
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
