import Foundation

struct ThreadIdentifier: Hashable, Sendable {
    let conversationID: String
    let rootTimestamp: String
}

struct ThreadState: Equatable, Sendable {
    let id: ThreadIdentifier
    var root: Message
    var replies: [Message] = []
    var draft = ComposerDraft()
    var nextCursor: String?
    var isLoading = false
    var isSending = false
    var isFollowing = false
    var errorMessage: String?

    var participants: [String] {
        var seen = Set<String>()
        return ([root] + replies).compactMap(\.authorUserID).filter {
            seen.insert($0).inserted
        }
    }

    var replyParticipants: [String] {
        var seen = Set<String>()
        return replies.compactMap(\.authorUserID).filter {
            seen.insert($0).inserted
        }
    }

    mutating func merge(_ messages: [Message], nextCursor: String?) {
        var byRemoteID = Dictionary(
            uniqueKeysWithValues: replies.compactMap { message in
                message.remoteID.map { ($0, message) }
            }
        )
        var localOnly = replies.filter { $0.remoteID == nil }
        for message in messages {
            if message.remoteID == root.remoteID {
                root = message
            } else if let remoteID = message.remoteID {
                byRemoteID[remoteID] = message
            } else if !localOnly.contains(where: { $0.id == message.id }) {
                localOnly.append(message)
            }
        }
        replies = (Array(byRemoteID.values) + localOnly)
            .sorted { $0.timestamp < $1.timestamp }
        self.nextCursor = nextCursor
    }

    mutating func appendOptimistic(_ message: Message) {
        replies.append(message)
        replies.sort { $0.timestamp < $1.timestamp }
    }

    mutating func confirm(localID: UUID, remoteTimestamp: String) {
        guard let index = replies.firstIndex(where: { $0.id == localID }) else {
            return
        }
        replies[index].remoteID = remoteTimestamp
    }
}
