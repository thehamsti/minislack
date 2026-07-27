import Foundation

enum ConversationKind: String, Sendable {
    case channel
    case directMessage
    case groupDirectMessage
}

struct Conversation: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    let kind: ConversationKind
    var isPrivate: Bool = false
    var subtitle: String?
    let isFavorite: Bool
    var createdAt: Date = .distantPast
    var topic: String? = nil
    var purpose: String? = nil
    var isArchived = false
    var participantUserID: String? = nil
    var avatarURL: URL? = nil
    var participants: [WorkspaceUser] = []
    var unreadCount: Int
    var mentionCount: Int
    var latestActivity: Date
    var messages: [Message]

    var isUnread: Bool {
        unreadCount > 0
    }

    var systemImage: String {
        switch kind {
        case .channel:
            isPrivate ? "lock.fill" : "number"
        case .directMessage:
            "person.crop.circle.fill"
        case .groupDirectMessage:
            "person.2.fill"
        }
    }

    var isDirectMessage: Bool {
        kind != .channel
    }

    var latestMessage: Message? {
        messages.last
    }

    var initials: String {
        title
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}
