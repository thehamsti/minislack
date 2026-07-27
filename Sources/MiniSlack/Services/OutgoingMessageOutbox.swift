import Foundation

actor OutgoingMessageOutbox {
    nonisolated let workspaceID: String

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var messagesByID: [UUID: OutgoingMessage]?
    private var claimedIDs: Set<UUID> = []

    init(workspaceID: String, rootURL: URL? = nil) {
        self.workspaceID = workspaceID
        let baseURL = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "MiniSlack/Outbox", directoryHint: .isDirectory)
        fileURL = baseURL
            .appending(path: workspaceID, directoryHint: .isDirectory)
            .appending(path: "v1", directoryHint: .isDirectory)
            .appending(path: "messages.json")
    }

    func load() throws -> [OutgoingMessage] {
        try ensureLoaded()
        return sortedMessages
    }

    func enqueue(_ message: OutgoingMessage) throws {
        try ensureLoaded()
        if var existing = messagesByID?[message.id] {
            existing = OutgoingMessage(
                id: existing.id,
                conversationID: message.conversationID,
                semanticText: message.semanticText,
                displayText: message.displayText,
                createdAt: existing.createdAt,
                state: existing.state,
                retryCount: existing.retryCount,
                nextRetryAt: existing.nextRetryAt,
                lastError: existing.lastError
            )
            messagesByID?[message.id] = existing
        } else {
            messagesByID?[message.id] = message
        }
        try persist()
    }

    func claim(
        id: UUID,
        now: Date = .now,
        force: Bool = false
    ) throws -> OutgoingMessage? {
        try ensureLoaded()
        guard !claimedIDs.contains(id),
              var message = messagesByID?[id]
        else {
            return nil
        }
        if force {
            message.state = .queued
            message.nextRetryAt = nil
            message.lastError = nil
            messagesByID?[id] = message
            try persist()
        } else {
            guard message.state != .permanentlyFailed,
                  message.nextRetryAt.map({ $0 <= now }) != false
            else {
                return nil
            }
        }
        claimedIDs.insert(id)
        return message
    }

    func claimNextReady(
        now: Date = .now,
        allowedConversationIDs: Set<String>
    ) throws -> OutgoingMessage? {
        try ensureLoaded()
        guard let message = sortedMessages.first(where: {
            allowedConversationIDs.contains($0.conversationID)
                && !claimedIDs.contains($0.id)
                && $0.state != .permanentlyFailed
                && $0.nextRetryAt.map { $0 <= now } != false
        }) else {
            return nil
        }
        claimedIDs.insert(message.id)
        return message
    }

    func recordFailure(
        id: UUID,
        errorMessage: String,
        disposition: OutgoingMessageFailureDisposition,
        now: Date = .now
    ) throws {
        try ensureLoaded()
        claimedIDs.remove(id)
        guard var message = messagesByID?[id] else {
            return
        }
        message.retryCount += 1
        message.lastError = errorMessage
        switch disposition {
        case let .retry(delay):
            message.state = .waitingToRetry
            message.nextRetryAt = now.addingTimeInterval(max(1, delay))
        case .permanent:
            message.state = .permanentlyFailed
            message.nextRetryAt = nil
        }
        messagesByID?[id] = message
        try persist()
    }

    func releaseClaim(id: UUID) {
        claimedIDs.remove(id)
    }

    func complete(id: UUID) throws {
        try complete(ids: [id])
    }

    func complete(ids: Set<UUID>) throws {
        try ensureLoaded()
        let existingIDs = ids.filter { messagesByID?[$0] != nil }
        guard !existingIDs.isEmpty else {
            return
        }
        for id in existingIDs {
            messagesByID?[id] = nil
            claimedIDs.remove(id)
        }
        try persist()
    }

    func nextEligibleDate(
        allowedConversationIDs: Set<String>
    ) throws -> Date? {
        try ensureLoaded()
        return sortedMessages.lazy.compactMap { message -> Date? in
            guard allowedConversationIDs.contains(message.conversationID),
                  !self.claimedIDs.contains(message.id),
                  message.state != .permanentlyFailed
            else {
                return nil
            }
            return message.nextRetryAt ?? .distantPast
        }
        .min()
    }

    private var sortedMessages: [OutgoingMessage] {
        (messagesByID.map { Array($0.values) } ?? []).sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func ensureLoaded() throws {
        guard messagesByID == nil else {
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            messagesByID = [:]
            return
        }
        let messages = try decoder.decode(
            [OutgoingMessage].self,
            from: Data(contentsOf: fileURL)
        )
        messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(sortedMessages).write(to: fileURL, options: .atomic)
    }
}
