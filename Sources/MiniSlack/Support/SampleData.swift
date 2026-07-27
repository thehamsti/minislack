import Foundation

enum SampleData {
    static let users = [
        WorkspaceUser(id: "alex-morgan", displayName: "Alex Morgan", status: "Active now", isActive: true),
        WorkspaceUser(id: "iris-bell", displayName: "Iris Bell", status: "Product design", isActive: true),
        WorkspaceUser(id: "jamie-park", displayName: "Jamie Park", status: "Away", isActive: false),
        WorkspaceUser(id: "jordan-lee", displayName: "Jordan Lee", status: "Operations", isActive: true),
        WorkspaceUser(id: "maya-chen", displayName: "Maya Chen", status: "Product", isActive: true),
        WorkspaceUser(id: "noah-kim", displayName: "Noah Kim", status: "Engineering", isActive: false),
        WorkspaceUser(id: "priya-shah", displayName: "Priya Shah", status: "Engineering", isActive: true),
        WorkspaceUser(id: "sam-rivera", displayName: "Sam Rivera", status: "Design systems", isActive: false),
        WorkspaceUser(id: "taylor-reed", displayName: "Taylor Reed", status: "Marketing", isActive: true),
    ]

    static func conversations(now: Date = .now) -> [Conversation] {
        [
            Conversation(
                id: "project-orbit",
                title: "project-orbit",
                kind: .channel,
                subtitle: "Launch planning",
                isFavorite: true,
                unreadCount: 6,
                mentionCount: 1,
                latestActivity: now.addingTimeInterval(-180),
                messages: [
                    message("Maya Chen", "The release candidate is looking good. I moved the final QA pass to this afternoon.", -7_200),
                    message("Noah Kim", "I can cover the account migration checks. The new import summary is much easier to scan.", -3_900, reactions: [Reaction(emoji: "🙌", count: 3)]),
                    message("Maya Chen", "Could you review the launch checklist before our 3:00 sync?", -180),
                ]
            ),
            Conversation(
                id: "design",
                title: "design",
                kind: .channel,
                subtitle: "Product design",
                isFavorite: true,
                unreadCount: 3,
                mentionCount: 0,
                latestActivity: now.addingTimeInterval(-720),
                messages: [
                    message("Iris Bell", "I posted the compact navigation exploration. The single-column state feels surprisingly capable.", -4_800),
                    message("Sam Rivera", "The unread queue is the right anchor. It keeps the small window focused without hiding the rest of the workspace.", -720, reactions: [Reaction(emoji: "💡", count: 5)]),
                ]
            ),
            Conversation(
                id: "alex-morgan",
                title: "Alex Morgan",
                kind: .directMessage,
                subtitle: "Active now",
                isFavorite: false,
                unreadCount: 2,
                mentionCount: 0,
                latestActivity: now.addingTimeInterval(-1_200),
                messages: [
                    message("Alex Morgan", "Want me to take notes in the customer call?", -2_400),
                    message("Alex Morgan", "I also found the source of that notification delay.", -1_200),
                ]
            ),
            Conversation(
                id: "engineering",
                title: "engineering",
                kind: .channel,
                subtitle: "Builds and architecture",
                isFavorite: false,
                unreadCount: 1,
                mentionCount: 0,
                latestActivity: now.addingTimeInterval(-3_000),
                messages: [
                    message("Priya Shah", "The macOS build is green again. Keyboard command tests are in the same target.", -3_000, reactions: [Reaction(emoji: "✅", count: 4)]),
                ]
            ),
            Conversation(
                id: "general",
                title: "general",
                kind: .channel,
                subtitle: "Company-wide",
                isFavorite: false,
                unreadCount: 0,
                mentionCount: 0,
                latestActivity: now.addingTimeInterval(-8_400),
                messages: [
                    message("Jordan Lee", "Reminder: the studio is closed Friday afternoon for the team event.", -8_400),
                ]
            ),
            Conversation(
                id: "random",
                title: "random",
                kind: .channel,
                subtitle: "The good stuff",
                isFavorite: false,
                unreadCount: 0,
                mentionCount: 0,
                latestActivity: now.addingTimeInterval(-14_000),
                messages: [
                    message("Taylor Reed", "Lunch poll: noodles or tacos?", -14_000, reactions: [
                        Reaction(emoji: "🍜", count: 8),
                        Reaction(emoji: "🌮", count: 6),
                    ]),
                ]
            ),
            Conversation(
                id: "jamie-park",
                title: "Jamie Park",
                kind: .directMessage,
                subtitle: "Away",
                isFavorite: false,
                unreadCount: 0,
                mentionCount: 0,
                latestActivity: now.addingTimeInterval(-19_000),
                messages: [
                    message("Jamie Park", "The research clips are in the shared folder when you have a minute.", -19_000),
                ]
            ),
        ]
    }

    private static func message(
        _ author: String,
        _ body: String,
        _ offset: TimeInterval,
        reactions: [Reaction] = []
    ) -> Message {
        Message(
            author: author,
            body: body,
            timestamp: Date.now.addingTimeInterval(offset),
            reactions: reactions
        )
    }
}
