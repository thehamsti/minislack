import Foundation

enum IncrementalSyncMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case conservative
    case responsive

    static let defaultsKey = "incrementalSyncMode"

    var id: Self { self }

    var title: String {
        switch self {
        case .off:
            "Off"
        case .conservative:
            "Conservative"
        case .responsive:
            "Responsive"
        }
    }

    var detail: String {
        switch self {
        case .off:
            "Only refresh when you open a conversation."
        case .conservative:
            "Bootstraps unread state once, then polls at most once per minute."
        case .responsive:
            "Bootstraps unread state once, then checks active conversations more often."
        }
    }

    var requestInterval: Duration? {
        switch self {
        case .off:
            nil
        case .conservative:
            .seconds(60)
        case .responsive:
            .seconds(15)
        }
    }

    var selectedInterval: TimeInterval {
        switch self {
        case .off:
            .infinity
        case .conservative:
            60
        case .responsive:
            15
        }
    }

    var unreadInterval: TimeInterval {
        switch self {
        case .off:
            .infinity
        case .conservative:
            180
        case .responsive:
            60
        }
    }

    var backgroundInterval: TimeInterval {
        switch self {
        case .off:
            .infinity
        case .conservative:
            900
        case .responsive:
            300
        }
    }

    static var current: Self {
        let value = UserDefaults.standard.string(forKey: defaultsKey)
        return value.flatMap(Self.init(rawValue:)) ?? .conservative
    }
}

struct IncrementalSyncConversation: Equatable, Sendable {
    let id: String
    let isUnread: Bool
    let latestActivity: Date
    let hasPendingCatchup: Bool

    init(
        id: String,
        isUnread: Bool,
        latestActivity: Date,
        hasPendingCatchup: Bool = false
    ) {
        self.id = id
        self.isUnread = isUnread
        self.latestActivity = latestActivity
        self.hasPendingCatchup = hasPendingCatchup
    }
}

struct UnreadCountReconciliation: Equatable, Sendable {
    let unreadCount: Int
    let mentionCount: Int

    static func reconcile(
        remoteUnreadCount: Int,
        currentUnreadCount: Int,
        currentMentionCount: Int,
        messages: [Message],
        readCursor: MessageHistoryReadCursor?,
        currentUserID: String
    ) -> Self {
        guard let readTimestamp = readCursor?.timestamp else {
            return Self(
                unreadCount: max(remoteUnreadCount, currentUnreadCount),
                mentionCount: remoteUnreadCount == 0 && currentUnreadCount == 0
                    ? 0
                    : currentMentionCount
            )
        }
        let localUnreadMessages = messages.filter {
            !$0.isCurrentUser
                && $0.authorUserID != currentUserID
                && $0.timestamp > readTimestamp
        }
        let localMentionCount = localUnreadMessages.count {
            $0.body.contains("<@\(currentUserID)>")
        }
        let unreadCount = max(remoteUnreadCount, localUnreadMessages.count)
        return Self(
            unreadCount: unreadCount,
            mentionCount: unreadCount == 0
                ? 0
                : max(currentMentionCount, localMentionCount)
        )
    }
}

struct IncrementalSyncDecision: Equatable, Sendable {
    enum Priority: Int, Equatable, Sendable {
        case selected
        case unread
        case background
    }

    let conversationID: String
    let priority: Priority
    let isInitialPoll: Bool
}

struct IncrementalSyncCatchupState: Sendable {
    let oldest: String?
    let latestKnownTimestamp: Date
    let syncStartedAt: Date
    let isInitialPoll: Bool
    let existingRemoteIDs: Set<String>
    let unreadBoundary: MessageHistoryReadCursor?
    let shouldBootstrapUnread: Bool
    let maximumPageCount: Int?
    var nextCursor: String? = nil
    private(set) var pageCount = 0
    private var messagesByID: [String: Message] = [:]

    var messages: [Message] {
        messagesByID.values.sorted { $0.timestamp < $1.timestamp }
    }

    mutating func merge(_ page: SlackMessagePage) {
        for message in page.messages {
            let key = message.remoteID ?? message.id.uuidString
            messagesByID[key] = message
        }
        nextCursor = page.nextCursor
        pageCount += 1
    }

    var reachedPageLimit: Bool {
        maximumPageCount.map { pageCount >= $0 } == true
    }
}

struct IncrementalSyncScheduler: Sendable {
    private let startedAt: Date
    private var lastPolledAt: [String: Date] = [:]
    private var backgroundRotationOffset = 0

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    mutating func nextDecision(
        now: Date,
        mode: IncrementalSyncMode,
        conversations: [IncrementalSyncConversation],
        selectedConversationID: String?
    ) -> IncrementalSyncDecision? {
        guard mode != .off, !conversations.isEmpty else {
            return nil
        }

        let backgroundOrder = conversations
            .filter { $0.id != selectedConversationID && !$0.isUnread }
            .sorted {
                if $0.latestActivity != $1.latestActivity {
                    return $0.latestActivity > $1.latestActivity
                }
                return $0.id < $1.id
            }
        let backgroundRanks = Dictionary(
            uniqueKeysWithValues: backgroundOrder.enumerated().map { index, conversation in
                let rank = (
                    index - backgroundRotationOffset + max(1, backgroundOrder.count)
                ) % max(1, backgroundOrder.count)
                return (conversation.id, rank)
            }
        )

        let candidates = conversations.compactMap { conversation -> Candidate? in
            let priority: IncrementalSyncDecision.Priority
            let interval: TimeInterval
            if conversation.id == selectedConversationID {
                priority = .selected
                interval = mode.selectedInterval
            } else if conversation.isUnread {
                priority = .unread
                interval = mode.unreadInterval
            } else {
                priority = .background
                interval = mode.backgroundInterval
            }

            let previousPoll = lastPolledAt[conversation.id]
            if previousPoll == nil || conversation.hasPendingCatchup {
                return Candidate(
                    conversation: conversation,
                    priority: priority,
                    urgency: .greatestFiniteMagnitude,
                    rotationRank: 0
                )
            }
            let baseline = previousPoll ?? startedAt
            let elapsed = max(0, now.timeIntervalSince(baseline))
            guard elapsed >= interval else {
                return nil
            }
            return Candidate(
                conversation: conversation,
                priority: priority,
                urgency: elapsed / interval,
                rotationRank: backgroundRanks[conversation.id] ?? 0
            )
        }

        guard let candidate = candidates.sorted(by: Candidate.precedes).first else {
            return nil
        }
        let isInitialPoll = lastPolledAt[candidate.conversation.id] == nil
        lastPolledAt[candidate.conversation.id] = now
        if candidate.priority == .background,
           let index = backgroundOrder.firstIndex(where: {
               $0.id == candidate.conversation.id
           })
        {
            backgroundRotationOffset = (index + 1) % max(1, backgroundOrder.count)
        }
        return IncrementalSyncDecision(
            conversationID: candidate.conversation.id,
            priority: candidate.priority,
            isInitialPoll: isInitialPoll
        )
    }

    mutating func recordFailure(for conversationID: String) {
        lastPolledAt[conversationID] = nil
    }

    private struct Candidate {
        let conversation: IncrementalSyncConversation
        let priority: IncrementalSyncDecision.Priority
        let urgency: Double
        let rotationRank: Int

        static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.urgency != rhs.urgency {
                return lhs.urgency > rhs.urgency
            }
            if lhs.priority != rhs.priority {
                return lhs.priority.rawValue < rhs.priority.rawValue
            }
            if lhs.priority == .background, lhs.rotationRank != rhs.rotationRank {
                return lhs.rotationRank < rhs.rotationRank
            }
            if lhs.conversation.latestActivity != rhs.conversation.latestActivity {
                return lhs.conversation.latestActivity > rhs.conversation.latestActivity
            }
            return lhs.conversation.id < rhs.conversation.id
        }
    }
}

struct MessageNotificationContext: Equatable, Sendable {
    let isInitialPoll: Bool
    let isCurrentUserMessage: Bool
    let authorUserID: String?
    let currentUserID: String
    let isConversationFocused: Bool
    let isCurrentUserDoNotDisturb: Bool
    let isConversationMuted: Bool
}

enum MessageNotificationPolicy {
    static func shouldNotify(_ context: MessageNotificationContext) -> Bool {
        !context.isInitialPoll
            && !context.isCurrentUserMessage
            && context.authorUserID != context.currentUserID
            && !context.isConversationFocused
            && !context.isCurrentUserDoNotDisturb
            && !context.isConversationMuted
    }
}

enum IncrementalMessageDetector {
    static func latestRemoteID(in messages: [Message]) -> String? {
        messages.compactMap(\.remoteID).max {
            (Double($0) ?? -Double.infinity)
                < (Double($1) ?? -Double.infinity)
        }
    }

    static func latestRemoteTimestamp(in messages: [Message]) -> Date {
        messages
            .compactMap(\.remoteID)
            .compactMap(Double.init)
            .map(Date.init(timeIntervalSince1970:))
            .max() ?? .distantPast
    }

    static func newMessages(
        in messages: [Message],
        excludingRemoteIDs existingRemoteIDs: Set<String>,
        latestKnownTimestamp: Date,
        syncStartedAt: Date,
        isInitialPoll: Bool
    ) -> [Message] {
        let boundary = isInitialPoll ? syncStartedAt : latestKnownTimestamp
        return messages.filter { message in
            guard message.timestamp > boundary,
                  let remoteID = message.remoteID
            else {
                return false
            }
            return !existingRemoteIDs.contains(remoteID)
        }
    }
}

enum DockBadgeFormatter {
    static func label(unreadCount: Int) -> String? {
        guard unreadCount > 0 else {
            return nil
        }
        return unreadCount > 99 ? "99+" : String(unreadCount)
    }
}
