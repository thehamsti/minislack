import Foundation

struct MessageMutationTarget: Codable, Hashable, Sendable {
    let conversationID: String
    let remoteTimestamp: String
}

struct MessageMutationVersion: Codable, Equatable, Sendable {
    let body: String
    let editedAt: Date?
    let isDeleted: Bool

    init(message: Message) {
        body = message.body
        editedAt = message.editedAt
        isDeleted = message.isDeleted
    }
}

enum MessageMutationOperation: Codable, Equatable, Sendable {
    case edit(text: String)
    case delete

    var actionName: String {
        switch self {
        case .edit:
            "Edit"
        case .delete:
            "Delete"
        }
    }
}

enum MessageMutationQueueState: String, Codable, Equatable, Sendable {
    case queued
    case waitingToRetry
    case permanentlyFailed
    case conflict
}

struct MessageMutation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let messageID: UUID
    let target: MessageMutationTarget
    var baseVersion: MessageMutationVersion
    let operation: MessageMutationOperation
    let createdAt: Date
    var state: MessageMutationQueueState
    var retryCount: Int
    var nextRetryAt: Date?
    var lastError: String?

    init(
        id: UUID = UUID(),
        messageID: UUID,
        target: MessageMutationTarget,
        baseVersion: MessageMutationVersion,
        operation: MessageMutationOperation,
        createdAt: Date = .now,
        state: MessageMutationQueueState = .queued,
        retryCount: Int = 0,
        nextRetryAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.target = target
        self.baseVersion = baseVersion
        self.operation = operation
        self.createdAt = createdAt
        self.state = state
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
    }
}

enum MessageMutationDisplayState: Equatable, Sendable {
    case pending(action: String)
    case failed(action: String, message: String)
    case conflict(action: String, message: String)

    var label: String {
        switch self {
        case let .pending(action):
            "\(action) pending"
        case let .failed(action, _):
            "\(action) failed"
        case let .conflict(action, _):
            "\(action) conflict"
        }
    }

    var detail: String {
        switch self {
        case let .pending(action):
            "\(action) is queued and will retry when Slack is available."
        case let .failed(_, message), let .conflict(_, message):
            message
        }
    }
}
