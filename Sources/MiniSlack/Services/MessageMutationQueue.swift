import Foundation

enum MessageMutationQueueError: LocalizedError, Equatable {
    case pendingMutation

    var errorDescription: String? {
        "This message already has a pending change."
    }
}

actor MessageMutationQueue {
    nonisolated let workspaceID: String

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var mutationsByID: [UUID: MessageMutation]?
    private var claimedIDs: Set<UUID> = []

    init(workspaceID: String, rootURL: URL? = nil) {
        self.workspaceID = workspaceID
        let baseURL = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "MiniSlack/MutationQueue", directoryHint: .isDirectory)
        fileURL = baseURL
            .appending(path: workspaceID, directoryHint: .isDirectory)
            .appending(path: "v1", directoryHint: .isDirectory)
            .appending(path: "mutations.json")
    }

    func load() throws -> [MessageMutation] {
        try ensureLoaded()
        return sortedMutations
    }

    func enqueue(_ mutation: MessageMutation) throws {
        try ensureLoaded()
        guard mutationsByID?.values.contains(where: {
            $0.target == mutation.target
        }) != true else {
            throw MessageMutationQueueError.pendingMutation
        }
        mutationsByID?[mutation.id] = mutation
        try persist()
    }

    func claim(
        id: UUID,
        now: Date = .now,
        force: Bool = false
    ) throws -> MessageMutation? {
        try ensureLoaded()
        guard !claimedIDs.contains(id),
              var mutation = mutationsByID?[id]
        else {
            return nil
        }
        if force {
            mutation.state = .queued
            mutation.nextRetryAt = nil
            mutation.lastError = nil
            mutationsByID?[id] = mutation
            try persist()
        } else {
            guard mutation.state != .permanentlyFailed,
                  mutation.state != .conflict,
                  mutation.nextRetryAt.map({ $0 <= now }) != false
            else {
                return nil
            }
        }
        claimedIDs.insert(id)
        return mutation
    }

    func claimNextReady(
        now: Date = .now,
        availableTargets: Set<MessageMutationTarget>
    ) throws -> MessageMutation? {
        try ensureLoaded()
        guard let mutation = sortedMutations.first(where: {
            availableTargets.contains($0.target)
                && !claimedIDs.contains($0.id)
                && $0.state != .permanentlyFailed
                && $0.state != .conflict
                && $0.nextRetryAt.map { $0 <= now } != false
        }) else {
            return nil
        }
        claimedIDs.insert(mutation.id)
        return mutation
    }

    func recordFailure(
        id: UUID,
        errorMessage: String,
        disposition: OutgoingMessageFailureDisposition,
        now: Date = .now
    ) throws {
        try ensureLoaded()
        claimedIDs.remove(id)
        guard var mutation = mutationsByID?[id] else {
            return
        }
        mutation.retryCount += 1
        mutation.lastError = errorMessage
        switch disposition {
        case let .retry(delay):
            mutation.state = .waitingToRetry
            mutation.nextRetryAt = now.addingTimeInterval(max(1, delay))
        case .permanent:
            mutation.state = .permanentlyFailed
            mutation.nextRetryAt = nil
        }
        mutationsByID?[id] = mutation
        try persist()
    }

    func recordConflict(id: UUID, message: String) throws {
        try ensureLoaded()
        claimedIDs.remove(id)
        guard var mutation = mutationsByID?[id] else {
            return
        }
        mutation.state = .conflict
        mutation.nextRetryAt = nil
        mutation.lastError = message
        mutationsByID?[id] = mutation
        try persist()
    }

    func rebaseAndClaim(
        id: UUID,
        baseVersion: MessageMutationVersion
    ) throws -> MessageMutation? {
        try ensureLoaded()
        guard !claimedIDs.contains(id),
              var mutation = mutationsByID?[id]
        else {
            return nil
        }
        mutation.baseVersion = baseVersion
        mutation.state = .queued
        mutation.nextRetryAt = nil
        mutation.lastError = nil
        mutationsByID?[id] = mutation
        try persist()
        claimedIDs.insert(id)
        return mutation
    }

    func releaseClaim(id: UUID) {
        claimedIDs.remove(id)
    }

    func complete(id: UUID) throws {
        try ensureLoaded()
        guard mutationsByID?[id] != nil else {
            return
        }
        mutationsByID?[id] = nil
        claimedIDs.remove(id)
        try persist()
    }

    func nextEligibleDate(
        availableTargets: Set<MessageMutationTarget>
    ) throws -> Date? {
        try ensureLoaded()
        return sortedMutations.lazy.compactMap { mutation -> Date? in
            guard availableTargets.contains(mutation.target),
                  !self.claimedIDs.contains(mutation.id),
                  mutation.state != .permanentlyFailed,
                  mutation.state != .conflict
            else {
                return nil
            }
            return mutation.nextRetryAt ?? .distantPast
        }
        .min()
    }

    private var sortedMutations: [MessageMutation] {
        (mutationsByID.map { Array($0.values) } ?? []).sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func ensureLoaded() throws {
        guard mutationsByID == nil else {
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            mutationsByID = [:]
            return
        }
        let mutations = try decoder.decode(
            [MessageMutation].self,
            from: Data(contentsOf: fileURL)
        )
        mutationsByID = Dictionary(
            uniqueKeysWithValues: mutations.map { ($0.id, $0) }
        )
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(sortedMutations).write(to: fileURL, options: .atomic)
    }
}
