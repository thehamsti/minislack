import Foundation

enum UnreadConversationKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case channels
    case directMessages
    case groupDirectMessages

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            "Everything"
        case .channels:
            "Channels"
        case .directMessages:
            "Direct messages"
        case .groupDirectMessages:
            "Group messages"
        }
    }

    /// Compact label for the unread filter chip.
    var chipTitle: String {
        switch self {
        case .all:
            "Type"
        case .channels:
            "Channels"
        case .directMessages:
            "DMs"
        case .groupDirectMessages:
            "Groups"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            "bubble.left.and.bubble.right"
        case .channels:
            "number"
        case .directMessages:
            "person.crop.circle"
        case .groupDirectMessages:
            "person.2"
        }
    }

    func matches(_ conversation: Conversation) -> Bool {
        switch self {
        case .all:
            true
        case .channels:
            conversation.kind == .channel
        case .directMessages:
            conversation.kind == .directMessage
        case .groupDirectMessages:
            conversation.kind == .groupDirectMessage
        }
    }
}

enum UnreadTimeRange: Equatable, Sendable {
    case anyTime
    case lastHour
    case today
    case yesterday
    case lastWeek
    case custom(start: Date, end: Date)

    static let presets: [UnreadTimeRange] = [.anyTime, .lastHour, .today, .yesterday, .lastWeek]

    var title: String {
        switch self {
        case .anyTime:
            "Any time"
        case .lastHour:
            "Last hour"
        case .today:
            "Today"
        case .yesterday:
            "Yesterday"
        case .lastWeek:
            "Last 7 days"
        case .custom:
            "Custom range"
        }
    }

    /// Compact label for the unread time filter chip.
    var chipTitle: String {
        switch self {
        case .anyTime:
            "When"
        case .lastHour:
            "1h"
        case .today:
            "Today"
        case .yesterday:
            "Yesterday"
        case .lastWeek:
            "7d"
        case .custom:
            "Custom"
        }
    }

    var isActive: Bool {
        self != .anyTime
    }

    func contains(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        switch self {
        case .anyTime:
            return true
        case .lastHour:
            return date >= now.addingTimeInterval(-3_600)
        case .today:
            return date >= calendar.startOfDay(for: now)
        case .yesterday:
            let startOfToday = calendar.startOfDay(for: now)
            let startOfYesterday = calendar.date(
                byAdding: .day,
                value: -1,
                to: startOfToday
            ) ?? startOfToday
            return date >= startOfYesterday && date < startOfToday
        case .lastWeek:
            return date >= now.addingTimeInterval(-7 * 86_400)
        case let .custom(start, end):
            return date >= start && date <= end
        }
    }
}

struct UnreadAuthor: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let avatarURL: URL?
}

enum UnreadSortOrder: String, CaseIterable, Identifiable, Sendable {
    case mentionsFirst
    case newest
    case oldest
    case name

    var id: Self { self }

    var title: String {
        switch self {
        case .mentionsFirst:
            "Mentions first"
        case .newest:
            "Newest first"
        case .oldest:
            "Oldest first"
        case .name:
            "Name A–Z"
        }
    }

    /// Compact label for the unread sort chip.
    var chipTitle: String {
        switch self {
        case .mentionsFirst:
            "Mentions"
        case .newest:
            "Newest"
        case .oldest:
            "Oldest"
        case .name:
            "Name"
        }
    }
}

struct UnreadInboxFilters: Equatable, Sendable {
    var query = ""
    var kind: UnreadConversationKindFilter = .all
    var conversationIDs: Set<String> = []
    var authorIDs: Set<String> = []
    var timeRange: UnreadTimeRange = .anyTime
    var mentionsOnly = false
    var sortOrder: UnreadSortOrder = .mentionsFirst

    var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || kind != .all
            || !conversationIDs.isEmpty
            || !authorIDs.isEmpty
            || timeRange.isActive
            || mentionsOnly
    }

    mutating func clearActiveFilters() {
        let sortOrder = sortOrder
        self = UnreadInboxFilters()
        self.sortOrder = sortOrder
    }

    func apply(
        to conversations: [Conversation],
        unreadMessages: (Conversation) -> [Message],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Conversation] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsMessages = !authorIDs.isEmpty || !trimmedQuery.isEmpty

        let filtered = conversations.filter { conversation in
            guard kind.matches(conversation) else {
                return false
            }
            if !conversationIDs.isEmpty, !conversationIDs.contains(conversation.id) {
                return false
            }
            if mentionsOnly, conversation.mentionCount == 0 {
                return false
            }
            if !timeRange.contains(conversation.latestActivity, now: now, calendar: calendar) {
                return false
            }
            if needsMessages {
                let messages = unreadMessages(conversation)
                if !authorIDs.isEmpty {
                    let messageAuthorIDs = Set(messages.map(\.unreadAuthorFilterKey))
                    if messageAuthorIDs.isDisjoint(with: authorIDs) {
                        return false
                    }
                }
                if !trimmedQuery.isEmpty {
                    let matchesTitle = conversation.title
                        .localizedCaseInsensitiveContains(trimmedQuery)
                    let matchesMessage = messages.contains {
                        $0.copyText.localizedCaseInsensitiveContains(trimmedQuery)
                    }
                    if !matchesTitle, !matchesMessage {
                        return false
                    }
                }
            }
            return true
        }

        return filtered.sortedByUnreadOrder(sortOrder)
    }
}

extension Message {
    /// Stable identity for From-filtering: Slack user ID when present, falling
    /// back to the display name so bots and integrations remain filterable.
    var unreadAuthorFilterKey: String {
        authorUserID ?? "name:\(author)"
    }
}

extension [Conversation] {
    func sortedByUnreadOrder(_ order: UnreadSortOrder) -> [Conversation] {
        switch order {
        case .mentionsFirst:
            sorted {
                if $0.mentionCount != $1.mentionCount {
                    return $0.mentionCount > $1.mentionCount
                }
                return $0.latestActivity > $1.latestActivity
            }
        case .newest:
            sorted { $0.latestActivity > $1.latestActivity }
        case .oldest:
            sorted { $0.latestActivity < $1.latestActivity }
        case .name:
            sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }
}
