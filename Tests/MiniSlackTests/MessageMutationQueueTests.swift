import Foundation
import Testing
@testable import MiniSlack

@MainActor
struct MessageMutationQueueTests {
    @Test
    func queuePersistsFailureStateAndSeparatesWorkspaces() async throws {
        let rootURL = temporaryRoot("persistence")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let message = ownedMessage()
        let mutation = editMutation(
            message: message,
            text: "Queued edit",
            createdAt: now
        )
        let queue = MessageMutationQueue(workspaceID: "T1", rootURL: rootURL)

        try await queue.enqueue(mutation)
        #expect(try await queue.claim(id: mutation.id, now: now) == mutation)
        #expect(try await queue.claim(id: mutation.id, now: now) == nil)
        try await queue.recordFailure(
            id: mutation.id,
            errorMessage: "Offline",
            disposition: .retry(after: 8),
            now: now
        )

        let restored = MessageMutationQueue(workspaceID: "T1", rootURL: rootURL)
        let restoredMutation = try #require(try await restored.load().first)
        #expect(restoredMutation.operation == .edit(text: "Queued edit"))
        #expect(restoredMutation.state == .waitingToRetry)
        #expect(restoredMutation.retryCount == 1)
        #expect(restoredMutation.nextRetryAt == now.addingTimeInterval(8))
        #expect(
            try await restored.claim(
                id: mutation.id,
                now: now.addingTimeInterval(7)
            ) == nil
        )

        let otherWorkspace = MessageMutationQueue(
            workspaceID: "T2",
            rootURL: rootURL
        )
        #expect(try await otherWorkspace.load().isEmpty)
    }

    @Test
    func transientEditFailureCanBeRetriedManually() async throws {
        let rootURL = temporaryRoot("manual-retry")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let token = "mutation-retry-\(UUID().uuidString)"
        let recorder = MutationRequestRecorder()
        let client = mutationClient(token: token) { request in
            let request = try materializedMutationRequest(request)
            let count = recorder.append(request)
            if request.url?.path.hasSuffix("/conversations.history") == true {
                return try mutationHistoryResponse(request, text: "Original")
            }
            if count == 1 {
                throw URLError(.networkConnectionLost)
            }
            return try mutationResponse(request, json: #"{"ok":true}"#)
        }
        defer { MutationURLProtocol.unregister(token: token) }
        let queue = MessageMutationQueue(workspaceID: "T1", rootURL: rootURL)
        let message = ownedMessage()
        let store = makeStore(
            message: message,
            client: client,
            token: token,
            queue: queue
        )

        await #expect(throws: (any Error).self) {
            try await store.editMessage(
                conversationID: "C1",
                messageID: message.id,
                text: "Retried edit"
            )
        }

        let failed = try #require(try await queue.load().first)
        #expect(failed.state == .waitingToRetry)
        #expect(failed.retryCount == 1)
        #expect(store.selectedConversation?.messages.first?.body == "Original")
        #expect(
            store.messageMutationDisplayState(
                conversationID: "C1",
                message: message,
                threadIdentifier: nil
            ) == .pending(action: "Edit")
        )

        try await store.retryMessageMutation(
            conversationID: "C1",
            messageID: message.id
        )
        store.cancelMessageMutationReplay()

        #expect(store.selectedConversation?.messages.first?.body == "Retried edit")
        #expect(try await queue.load().isEmpty)
        #expect(recorder.values.count == 3)
        let body = try recorder.values[2].jsonBody()
        #expect(body["channel"] as? String == "C1")
        #expect(body["ts"] as? String == "100.000")
        #expect(body["text"] as? String == "Retried edit")
    }

    @Test
    func permanentEditFailureStaysVisibleUntilManualRetry() async throws {
        let rootURL = temporaryRoot("permanent-retry")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let token = "mutation-permanent-\(UUID().uuidString)"
        let recorder = MutationRequestRecorder()
        let client = mutationClient(token: token) { request in
            let request = try materializedMutationRequest(request)
            let count = recorder.append(request)
            if request.url?.path.hasSuffix("/conversations.history") == true {
                return try mutationHistoryResponse(request, text: "Original")
            }
            if count == 1 {
                return try mutationResponse(
                    request,
                    json: #"{"ok":false,"error":"cant_update_message"}"#
                )
            }
            return try mutationResponse(request, json: #"{"ok":true}"#)
        }
        defer { MutationURLProtocol.unregister(token: token) }
        let queue = MessageMutationQueue(workspaceID: "T1", rootURL: rootURL)
        let message = ownedMessage()
        let store = makeStore(
            message: message,
            client: client,
            token: token,
            queue: queue
        )

        await #expect(throws: SlackAPIClient.APIError.slack("cant_update_message")) {
            try await store.editMessage(
                conversationID: "C1",
                messageID: message.id,
                text: "Retry explicitly"
            )
        }
        let failed = try #require(try await queue.load().first)
        #expect(failed.state == .permanentlyFailed)
        #expect(
            store.messageMutationDisplayState(
                conversationID: "C1",
                message: message,
                threadIdentifier: nil
            ) == .failed(
                action: "Edit",
                message: "Slack API error: cant_update_message."
            )
        )

        try await store.retryMessageMutation(
            conversationID: "C1",
            messageID: message.id
        )
        store.cancelMessageMutationReplay()
        #expect(store.selectedConversation?.messages.first?.body == "Retry explicitly")
        #expect(try await queue.load().isEmpty)
    }

    @Test
    func restoredQueuedEditReplaysAfterRestart() async throws {
        let rootURL = temporaryRoot("restart")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let token = "mutation-restart-\(UUID().uuidString)"
        let recorder = MutationRequestRecorder()
        let client = mutationClient(token: token) { request in
            let request = try materializedMutationRequest(request)
            recorder.append(request)
            if request.url?.path.hasSuffix("/conversations.history") == true {
                return try mutationHistoryResponse(request, text: "Original")
            }
            return try mutationResponse(request, json: #"{"ok":true}"#)
        }
        defer { MutationURLProtocol.unregister(token: token) }
        let queue = MessageMutationQueue(workspaceID: "T1", rootURL: rootURL)
        let message = ownedMessage()
        try await queue.enqueue(editMutation(message: message, text: "After restart"))
        let store = makeStore(
            message: message,
            client: client,
            token: token,
            queue: queue
        )
        store.conversations[0].messages = []

        await store.restoreMessageMutations(for: "T1")
        store.scheduleMessageMutationReplay()
        try await Task.sleep(for: .milliseconds(25))
        #expect(recorder.values.isEmpty)
        store.apply([message], to: "C1")
        try await waitUntil {
            try await queue.load().isEmpty
        }
        store.cancelMessageMutationReplay()

        #expect(store.selectedConversation?.messages.first?.body == "After restart")
        #expect(recorder.values.count == 2)
    }

    @Test
    func restoredEditConflictsInsteadOfOverwritingChangedMessage() async throws {
        let rootURL = temporaryRoot("conflict")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let token = "mutation-conflict-\(UUID().uuidString)"
        let recorder = MutationRequestRecorder()
        let client = mutationClient(token: token) { request in
            let request = try materializedMutationRequest(request)
            recorder.append(request)
            if request.url?.path.hasSuffix("/conversations.history") == true {
                return try mutationHistoryResponse(
                    request,
                    text: "Changed in Slack",
                    editedTimestamp: "200.000"
                )
            }
            return try mutationResponse(request, json: #"{"ok":true}"#)
        }
        defer { MutationURLProtocol.unregister(token: token) }
        let original = ownedMessage()
        var changed = original
        changed.body = "Changed in Slack"
        changed.displayBody = "Changed in Slack"
        changed.editedAt = Date(timeIntervalSince1970: 200)
        let queue = MessageMutationQueue(workspaceID: "T1", rootURL: rootURL)
        try await queue.enqueue(editMutation(message: original, text: "Queued edit"))
        let store = makeStore(
            message: original,
            client: client,
            token: token,
            queue: queue
        )

        await store.restoreMessageMutations(for: "T1")
        store.scheduleMessageMutationReplay()
        try await waitUntil {
            try await queue.load().first?.state == .conflict
        }
        store.cancelMessageMutationReplay()

        let conflict = try #require(try await queue.load().first)
        #expect(conflict.state == .conflict)
        #expect(store.selectedConversation?.messages.first?.body == "Changed in Slack")
        #expect(recorder.values.count == 1)
        #expect(
            store.messageMutationDisplayState(
                conversationID: "C1",
                message: changed,
                threadIdentifier: nil
            ) == .conflict(
                action: "Edit",
                message: "The message changed in Slack. Review it before retrying."
            )
        )

        let conflictedMessage = try #require(
            store.selectedConversation?.messages.first
        )
        try await store.retryMessageMutation(
            conversationID: "C1",
            messageID: conflictedMessage.id
        )
        store.cancelMessageMutationReplay()
        #expect(store.selectedConversation?.messages.first?.body == "Queued edit")
        #expect(try await queue.load().isEmpty)
        #expect(recorder.values.count == 3)
    }

    @Test
    func restoredDeleteRecognizesAnAlreadyDeletedMessage() async throws {
        let rootURL = temporaryRoot("delete-restored")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let token = "mutation-delete-restored-\(UUID().uuidString)"
        let recorder = MutationRequestRecorder()
        let client = mutationClient(token: token) { request in
            recorder.append(try materializedMutationRequest(request))
            return try mutationResponse(request, json: #"{"ok":true}"#)
        }
        defer { MutationURLProtocol.unregister(token: token) }
        let original = ownedMessage()
        let queue = MessageMutationQueue(workspaceID: "T1", rootURL: rootURL)
        try await queue.enqueue(deleteMutation(message: original))
        var deleted = original
        deleted.body = ""
        deleted.displayBody = "This message was deleted."
        deleted.isDeleted = true
        deleted.editedAt = nil
        let store = makeStore(
            message: deleted,
            client: client,
            token: token,
            queue: queue
        )

        await store.restoreMessageMutations(for: "T1")

        #expect(try await queue.load().isEmpty)
        #expect(recorder.values.isEmpty)
        #expect(store.messageMutationsByTarget.isEmpty)
    }

    @Test
    func deleteTreatsMessageNotFoundAsIdempotentSuccess() async throws {
        let rootURL = temporaryRoot("delete-idempotent")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let token = "mutation-delete-idempotent-\(UUID().uuidString)"
        let client = mutationClient(token: token) { request in
            try mutationResponse(
                try materializedMutationRequest(request),
                json: #"{"ok":false,"error":"message_not_found"}"#
            )
        }
        defer { MutationURLProtocol.unregister(token: token) }
        let queue = MessageMutationQueue(workspaceID: "T1", rootURL: rootURL)
        let message = ownedMessage()
        let store = makeStore(
            message: message,
            client: client,
            token: token,
            queue: queue
        )

        try await store.deleteMessage(
            conversationID: "C1",
            messageID: message.id
        )
        store.cancelMessageMutationReplay()

        #expect(store.selectedConversation?.messages.first?.isDeleted == true)
        #expect(try await queue.load().isEmpty)
    }

    @Test
    func completedEditCannotMutateMatchingMessageAfterWorkspaceSwitch() async throws {
        let rootURL = temporaryRoot("session")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let token = "mutation-session-\(UUID().uuidString)"
        let gate = MutationRequestGate()
        let client = mutationClient(token: token) { request in
            gate.markRequested()
            gate.waitForRelease()
            return try mutationResponse(
                try materializedMutationRequest(request),
                json: #"{"ok":true}"#
            )
        }
        defer {
            gate.release()
            MutationURLProtocol.unregister(token: token)
        }
        let queue = MessageMutationQueue(workspaceID: "T1", rootURL: rootURL)
        let message = ownedMessage()
        let store = makeStore(
            message: message,
            client: client,
            token: token,
            queue: queue
        )

        let edit = Task {
            try await store.editMessage(
                conversationID: "C1",
                messageID: message.id,
                text: "Old workspace edit"
            )
        }
        for _ in 0 ..< 100 where !gate.hasRequested {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.hasRequested)

        store.clearWorkspaceSession()
        let betaMessage = Message(
            id: message.id,
            author: "Beta user",
            body: "Beta workspace",
            timestamp: message.timestamp,
            remoteID: message.remoteID
        )
        store.credentials = credentials(
            token: "beta",
            teamID: "T2",
            teamName: "Beta"
        )
        store.connectionState = .connected("Beta")
        store.conversations = [conversation(message: betaMessage)]
        gate.release()

        await #expect(throws: AppStore.WorkspaceSessionError.changed) {
            try await edit.value
        }
        #expect(store.conversations.first?.messages == [betaMessage])
        #expect(try await queue.load().count == 1)
        store.clearWorkspaceSession()
    }

    private func editMutation(
        message: Message,
        text: String,
        createdAt: Date = .now
    ) -> MessageMutation {
        MessageMutation(
            messageID: message.id,
            target: MessageMutationTarget(
                conversationID: "C1",
                remoteTimestamp: message.remoteID ?? ""
            ),
            baseVersion: MessageMutationVersion(message: message),
            operation: .edit(text: text),
            createdAt: createdAt
        )
    }

    private func deleteMutation(message: Message) -> MessageMutation {
        MessageMutation(
            messageID: message.id,
            target: MessageMutationTarget(
                conversationID: "C1",
                remoteTimestamp: message.remoteID ?? ""
            ),
            baseVersion: MessageMutationVersion(message: message),
            operation: .delete
        )
    }

    private func ownedMessage() -> Message {
        Message(
            author: "You",
            authorUserID: "U0",
            body: "Original",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100.000",
            isCurrentUser: true,
            deliveryState: .sent
        )
    }

    private func makeStore(
        message: Message,
        client: SlackAPIClient,
        token: String,
        queue: MessageMutationQueue
    ) -> AppStore {
        let store = AppStore(
            conversations: [conversation(message: message)],
            users: [
                WorkspaceUser(
                    id: "U0",
                    displayName: "You",
                    status: "",
                    isActive: true
                )
            ],
            connectionState: .connected("Acme"),
            slackAPI: client,
            credentials: credentials(
                token: token,
                teamID: "T1",
                teamName: "Acme"
            ),
            messageMutationQueue: queue
        )
        store.select("C1")
        return store
    }

    private func credentials(
        token: String,
        teamID: String,
        teamName: String
    ) -> SlackCredentials {
        SlackCredentials(
            accessToken: token,
            refreshToken: "refresh-\(token)",
            expiresAt: .distantFuture,
            teamID: teamID,
            teamName: teamName,
            userID: "U0"
        )
    }

    private func conversation(message: Message) -> Conversation {
        Conversation(
            id: "C1",
            title: "general",
            kind: .channel,
            subtitle: nil,
            isFavorite: false,
            unreadCount: 0,
            mentionCount: 0,
            latestActivity: message.timestamp,
            messages: [message]
        )
    }

    private func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "MiniSlackMutation-\(suffix)-\(UUID().uuidString)")
    }

    private func waitUntil(
        _ predicate: @escaping () async throws -> Bool
    ) async throws {
        for _ in 0 ..< 100 {
            if try await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for queued mutation replay")
    }
}

private typealias MutationHandler =
    @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

private enum MutationStubError: Error {
    case missingHandler
    case invalidRequest
}

private final class MutationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: MutationHandler] = [:]

    func register(token: String, handler: @escaping MutationHandler) {
        lock.lock()
        handlers[token] = handler
        lock.unlock()
    }

    func unregister(token: String) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    func handler(for request: URLRequest) -> MutationHandler? {
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let token = authorization.hasPrefix("Bearer ")
            ? String(authorization.dropFirst(7))
            : ""
        lock.lock()
        let handler = handlers[token]
        lock.unlock()
        return handler
    }
}

private final class MutationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = MutationRegistry()

    static func register(token: String, handler: @escaping MutationHandler) {
        registry.register(token: token, handler: handler)
    }

    static func unregister(token: String) {
        registry.unregister(token: token)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "slack.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.registry.handler(for: request) else {
            client?.urlProtocol(self, didFailWithError: MutationStubError.missingHandler)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MutationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var values: [URLRequest] {
        lock.lock()
        let values = requests
        lock.unlock()
        return values
    }

    @discardableResult
    func append(_ request: URLRequest) -> Int {
        lock.lock()
        requests.append(request)
        let count = requests.count
        lock.unlock()
        return count
    }
}

private final class MutationRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private let released = DispatchSemaphore(value: 0)

    var hasRequested: Bool {
        lock.lock()
        let value = requested
        lock.unlock()
        return value
    }

    func markRequested() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    func waitForRelease() {
        _ = released.wait(timeout: .now() + 5)
    }

    func release() {
        released.signal()
    }
}

private func mutationClient(
    token: String,
    handler: @escaping MutationHandler
) -> SlackAPIClient {
    MutationURLProtocol.register(token: token, handler: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MutationURLProtocol.self]
    return SlackAPIClient(urlSession: URLSession(configuration: configuration))
}

private func mutationResponse(
    _ request: URLRequest,
    json: String
) throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    let response = try #require(
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
    )
    return (response, Data(json.utf8))
}

private func mutationHistoryResponse(
    _ request: URLRequest,
    text: String,
    editedTimestamp: String? = nil
) throws -> (HTTPURLResponse, Data) {
    var message: [String: Any] = [
        "ts": "100.000",
        "user": "U0",
        "text": text,
    ]
    if let editedTimestamp {
        message["edited"] = ["user": "U0", "ts": editedTimestamp]
    }
    let data = try JSONSerialization.data(
        withJSONObject: [
            "ok": true,
            "messages": [message],
            "response_metadata": ["next_cursor": ""],
        ]
    )
    let url = try #require(request.url)
    let response = try #require(
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
    )
    return (response, data)
}

private func materializedMutationRequest(
    _ request: URLRequest
) throws -> URLRequest {
    guard request.httpBody == nil, let stream = request.httpBodyStream else {
        return request
    }
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else {
            throw MutationStubError.invalidRequest
        }
        guard count > 0 else {
            break
        }
        body.append(buffer, count: count)
    }
    var materialized = request
    materialized.httpBodyStream = nil
    materialized.httpBody = body
    return materialized
}

private extension URLRequest {
    func jsonBody() throws -> [String: Any] {
        let body = try #require(httpBody)
        return try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
    }
}
