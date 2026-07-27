import Foundation
import Testing
@testable import MiniSlack

struct UnreadInboxFilterTests {
    @Test
    func kindFilterSplitsChannelsAndDirectMessages() {
        let conversations = [
            conversation(id: "chan", kind: .channel),
            conversation(id: "dm", kind: .directMessage),
            conversation(id: "group", kind: .groupDirectMessage),
        ]
        var filters = UnreadInboxFilters()

        filters.kind = .channels
        #expect(filters.apply(to: conversations, unreadMessages: { _ in [] }).map(\.id) == ["chan"])

        filters.kind = .directMessages
        #expect(filters.apply(to: conversations, unreadMessages: { _ in [] }).map(\.id) == ["dm"])

        filters.kind = .groupDirectMessages
        #expect(filters.apply(to: conversations, unreadMessages: { _ in [] }).map(\.id) == ["group"])
    }

    @Test
    func conversationFilterKeepsOnlySelectedConversations() {
        let conversations = [
            conversation(id: "one"),
            conversation(id: "two"),
            conversation(id: "three"),
        ]
        var filters = UnreadInboxFilters()
        filters.conversationIDs = ["one", "three"]

        #expect(
            filters.apply(to: conversations, unreadMessages: { _ in [] }).map(\.id)
                == ["one", "three"]
        )
    }

    @Test
    func mentionsOnlyFilterRequiresMentionCount() {
        let conversations = [
            conversation(id: "mention", mentions: 2),
            conversation(id: "plain"),
        ]
        var filters = UnreadInboxFilters()
        filters.mentionsOnly = true

        #expect(filters.apply(to: conversations, unreadMessages: { _ in [] }).map(\.id) == ["mention"])
    }

    @Test
    func authorFilterMatchesUserIDsAndDisplayNameFallbacks() {
        let maya = message(author: "Maya Chen", authorUserID: "U1", body: "from maya")
        let bot = message(author: "Deploy Bot", authorUserID: nil, body: "deployed")
        let conversations = [
            conversation(id: "user", messages: [maya]),
            conversation(id: "bot", messages: [bot]),
        ]
        var filters = UnreadInboxFilters()
        filters.authorIDs = ["name:Deploy Bot"]

        let result = filters.apply(to: conversations) { $0.messages }
        #expect(result.map(\.id) == ["bot"])

        filters.authorIDs = ["U1"]
        #expect(filters.apply(to: conversations) { $0.messages }.map(\.id) == ["user"])
    }

    @Test
    func queryMatchesTitlesAndUnreadMessageText() {
        let conversations = [
            conversation(id: "design", messages: [message(body: "unrelated")]),
            conversation(id: "engineering", messages: [message(body: "the launch checklist")]),
        ]
        var filters = UnreadInboxFilters()

        filters.query = "des"
        #expect(filters.apply(to: conversations) { $0.messages }.map(\.id) == ["design"])

        filters.query = "checklist"
        #expect(filters.apply(to: conversations) { $0.messages }.map(\.id) == ["engineering"])

        filters.query = "nothing matches"
        #expect(filters.apply(to: conversations) { $0.messages }.isEmpty)
    }

    @Test
    func timeRangePresetsBoundLatestActivity() {
        let now = Date(timeIntervalSince1970: 100_000)
        let conversations = [
            conversation(id: "minutes-ago", activity: now.addingTimeInterval(-300).timeIntervalSince1970),
            conversation(id: "hours-ago", activity: now.addingTimeInterval(-7_200).timeIntervalSince1970),
            conversation(id: "days-ago", activity: now.addingTimeInterval(-200_000).timeIntervalSince1970),
        ]
        var filters = UnreadInboxFilters()

        filters.timeRange = .lastHour
        #expect(
            filters.apply(to: conversations, unreadMessages: { _ in [] }, now: now).map(\.id)
                == ["minutes-ago"]
        )

        filters.timeRange = .lastWeek
        #expect(
            filters.apply(to: conversations, unreadMessages: { _ in [] }, now: now).map(\.id)
                == ["minutes-ago", "hours-ago", "days-ago"]
        )
    }

    @Test
    func yesterdayRangeCoversOnlyThePreviousCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2025, month: 6, day: 10, hour: 9))!
        let conversations = [
            conversation(id: "today", activity: calendar.date(from: DateComponents(year: 2025, month: 6, day: 10, hour: 1))!.timeIntervalSince1970),
            conversation(id: "yesterday", activity: calendar.date(from: DateComponents(year: 2025, month: 6, day: 9, hour: 23))!.timeIntervalSince1970),
            conversation(id: "before", activity: calendar.date(from: DateComponents(year: 2025, month: 6, day: 8, hour: 23))!.timeIntervalSince1970),
        ]
        var filters = UnreadInboxFilters()
        filters.timeRange = .yesterday

        #expect(
            filters.apply(
                to: conversations,
                unreadMessages: { _ in [] },
                now: now,
                calendar: calendar
            ).map(\.id) == ["yesterday"]
        )
    }

    @Test
    func customRangeIsInclusiveOfBothEnds() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        let conversations = [
            conversation(id: "at-start", activity: start.timeIntervalSince1970),
            conversation(id: "at-end", activity: end.timeIntervalSince1970),
            conversation(id: "outside", activity: end.addingTimeInterval(1).timeIntervalSince1970),
        ]
        var filters = UnreadInboxFilters()
        filters.timeRange = .custom(start: start, end: end)

        #expect(
            filters.apply(to: conversations, unreadMessages: { _ in [] }).map(\.id)
                == ["at-end", "at-start"]
        )
    }

    @Test
    func sortOrdersRearrangeResults() {
        let conversations = [
            conversation(id: "Zulu", unread: 1, activity: 100),
            conversation(id: "Alpha", unread: 1, mentions: 1, activity: 50),
            conversation(id: "Mike", unread: 1, activity: 300),
        ]
        var filters = UnreadInboxFilters()

        filters.sortOrder = .mentionsFirst
        #expect(
            filters.apply(to: conversations, unreadMessages: { _ in [] }).map(\.id)
                == ["Alpha", "Mike", "Zulu"]
        )

        filters.sortOrder = .newest
        #expect(
            filters.apply(to: conversations, unreadMessages: { _ in [] }).map(\.id)
                == ["Mike", "Zulu", "Alpha"]
        )

        filters.sortOrder = .oldest
        #expect(
            filters.apply(to: conversations, unreadMessages: { _ in [] }).map(\.id)
                == ["Alpha", "Zulu", "Mike"]
        )

        filters.sortOrder = .name
        #expect(
            filters.apply(to: conversations, unreadMessages: { _ in [] }).map(\.id)
                == ["Alpha", "Mike", "Zulu"]
        )
    }

    @Test
    func clearingFiltersPreservesTheChosenSortOrder() {
        var filters = UnreadInboxFilters()
        filters.query = "launch"
        filters.mentionsOnly = true
        filters.sortOrder = .oldest

        #expect(filters.isFiltering)

        filters.clearActiveFilters()

        #expect(!filters.isFiltering)
        #expect(filters.sortOrder == .oldest)
    }

    private func conversation(
        id: String,
        kind: ConversationKind = .channel,
        unread: Int = 1,
        mentions: Int = 0,
        activity: TimeInterval = 100,
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
            latestActivity: Date(timeIntervalSince1970: activity),
            messages: messages
        )
    }

    private func message(
        author: String = "Maya Chen",
        authorUserID: String? = "U1",
        body: String
    ) -> Message {
        Message(
            author: author,
            authorUserID: authorUserID,
            body: body,
            timestamp: Date(timeIntervalSince1970: 100)
        )
    }
}
