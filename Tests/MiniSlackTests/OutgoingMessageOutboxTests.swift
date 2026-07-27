import Foundation
import Testing
@testable import MiniSlack

@MainActor
struct OutgoingMessageOutboxTests {
    @Test
    func outboxPersistsRetryStatePerWorkspaceAndClaimsOnce() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "MiniSlackOutbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let message = outgoingMessage(createdAt: now)
        let outbox = OutgoingMessageOutbox(workspaceID: "T1", rootURL: rootURL)

        try await outbox.enqueue(message)
        #expect(try await outbox.claim(id: message.id, now: now) == message)
        #expect(try await outbox.claim(id: message.id, now: now) == nil)
        try await outbox.recordFailure(
            id: message.id,
            errorMessage: "The network connection was lost.",
            disposition: .retry(after: 8),
            now: now
        )

        let restored = OutgoingMessageOutbox(workspaceID: "T1", rootURL: rootURL)
        let restoredMessage = try #require(try await restored.load().first)
        #expect(restoredMessage.id == message.id)
        #expect(restoredMessage.semanticText == "Hello <@U1>")
        #expect(restoredMessage.displayText == "Hello @Alex")
        #expect(restoredMessage.state == .waitingToRetry)
        #expect(restoredMessage.retryCount == 1)
        #expect(restoredMessage.nextRetryAt == now.addingTimeInterval(8))
        #expect(
            try await restored.claim(
                id: message.id,
                now: now.addingTimeInterval(7)
            ) == nil
        )
        #expect(
            try await restored.claim(
                id: message.id,
                now: now.addingTimeInterval(8)
            )?.id == message.id
        )

        let otherWorkspace = OutgoingMessageOutbox(
            workspaceID: "T2",
            rootURL: rootURL
        )
        #expect(try await otherWorkspace.load().isEmpty)
    }

    @Test
    func retryPolicySeparatesTransientAndPermanentFailures() {
        #expect(
            OutgoingMessageRetryPolicy.disposition(
                for: URLError(.notConnectedToInternet),
                retryCount: 0
            ) == .retry(after: 2)
        )
        #expect(
            OutgoingMessageRetryPolicy.disposition(
                for: SlackAPIClient.APIError.rateLimited(17),
                retryCount: 3
            ) == .retry(after: 17)
        )
        #expect(
            OutgoingMessageRetryPolicy.disposition(
                for: SlackAPIClient.APIError.http(503),
                retryCount: 2
            ) == .retry(after: 8)
        )
        #expect(
            OutgoingMessageRetryPolicy.disposition(
                for: SlackAPIClient.APIError.slack("channel_not_found"),
                retryCount: 0
            ) == .permanent
        )
        #expect(
            OutgoingMessageRetryPolicy.disposition(
                for: SlackAPIClient.APIError.invalidResponse,
                retryCount: 3
            ) == .permanent
        )
    }

    @Test
    func restoreRecreatesFailedOptimisticMessageWithoutChangingIdentity() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "MiniSlackRestore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let outbox = OutgoingMessageOutbox(workspaceID: "T1", rootURL: rootURL)
        let outgoing = outgoingMessage()
        try await outbox.enqueue(outgoing)
        let store = makeStore(outbox: outbox)

        await store.restoreOutgoingMessages(for: "T1")
        await store.restoreOutgoingMessages(for: "T1")

        let messages = try #require(store.selectedConversation?.messages)
        #expect(messages.count == 1)
        #expect(messages[0].id == outgoing.id)
        #expect(messages[0].body == outgoing.semanticText)
        #expect(messages[0].displayBody == outgoing.displayText)
        if case let .failed(reason) = messages[0].deliveryState {
            #expect(reason.contains("Queued"))
        } else {
            Issue.record("Restored outgoing message should remain visibly failed")
        }
    }

    @Test
    func transientFailureQueuesAndManualRetryUsesStableClientID() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "MiniSlackRetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let token = "outbox-\(UUID().uuidString)"
        let recorder = OutboxRequestRecorder()
        let client = outboxClient(token: token) { request in
            let request = try materializedOutboxRequest(request)
            let requestNumber = recorder.append(request)
            if requestNumber <= 3 {
                throw URLError(.networkConnectionLost)
            }
            let clientID = try #require(
                try request.jsonBody()["client_msg_id"] as? String
            )
            return try outboxResponse(
                request,
                json: """
                {
                  "ok": true,
                  "message": {
                    "ts": "123.456",
                    "client_msg_id": "\(clientID)",
                    "user": "U0",
                    "text": "Hello <@U1>"
                  }
                }
                """
            )
        }
        defer { OutboxURLProtocol.unregister(token: token) }
        let outbox = OutgoingMessageOutbox(workspaceID: "T1", rootURL: rootURL)
        let outgoing = outgoingMessage()
        let store = makeStore(client: client, token: token, outbox: outbox)
        store.conversations[0].messages = [optimisticMessage(from: outgoing)]

        await store.sendOutgoingMessage(
            conversationID: outgoing.conversationID,
            semanticText: outgoing.semanticText,
            localMessageID: outgoing.id
        )

        let queued = try #require(try await outbox.load().first)
        #expect(queued.id == outgoing.id)
        #expect(queued.state == .waitingToRetry)
        #expect(queued.retryCount == 1)
        if case .failed = store.conversations[0].messages[0].deliveryState {
        } else {
            Issue.record("Transient failure should be visibly queued")
        }

        try await store.retryMessage(
            conversationID: outgoing.conversationID,
            messageID: outgoing.id
        )
        store.cancelOutgoingMessageReplay()

        #expect(store.conversations[0].messages[0].id == outgoing.id)
        #expect(store.conversations[0].messages[0].remoteID == "123.456")
        #expect(store.conversations[0].messages[0].deliveryState == .sent)
        #expect(try await outbox.load().isEmpty)
        let clientIDs = try recorder.values.map {
            try #require(try $0.jsonBody()["client_msg_id"] as? String)
        }
        #expect(
            clientIDs == Array(
                repeating: outgoing.id.uuidString.lowercased(),
                count: 4
            )
        )
    }

    @Test
    func remoteClientIDReplacesLocalCopyAndCompletesOutbox() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "MiniSlackReconcile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let outbox = OutgoingMessageOutbox(workspaceID: "T1", rootURL: rootURL)
        let outgoing = outgoingMessage()
        try await outbox.enqueue(outgoing)
        let store = makeStore(outbox: outbox)
        store.conversations[0].messages = [optimisticMessage(from: outgoing)]

        let data = Data(
            """
            {
              "ts": "222.333",
              "client_msg_id": "\(outgoing.id.uuidString.lowercased())",
              "user": "U0",
              "text": "Hello <@U1>"
            }
            """.utf8
        )
        let dto = try JSONDecoder().decode(SlackMessageDTO.self, from: data)
        let remote = dto.message(
            users: Dictionary(uniqueKeysWithValues: store.users.map { ($0.id, $0) }),
            currentUserID: "U0",
            formattingContext: SlackMessageFormatting.Context(
                userNames: ["U0": "You", "U1": "Alex"],
                channelNames: ["C1": "general"]
            )
        )

        store.apply([remote], to: "C1")

        let messages = store.conversations[0].messages
        #expect(messages.count == 1)
        #expect(messages[0].id == outgoing.id)
        #expect(messages[0].remoteID == "222.333")
        for _ in 0 ..< 20 where !(try await outbox.load().isEmpty) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await outbox.load().isEmpty)
    }

    private func outgoingMessage(
        createdAt: Date = Date(timeIntervalSince1970: 1_900_000_000)
    ) -> OutgoingMessage {
        OutgoingMessage(
            id: UUID(),
            conversationID: "C1",
            semanticText: "Hello <@U1>",
            displayText: "Hello @Alex",
            createdAt: createdAt
        )
    }

    private func optimisticMessage(from outgoing: OutgoingMessage) -> Message {
        Message(
            id: outgoing.id,
            author: "You",
            authorUserID: "U0",
            body: outgoing.semanticText,
            timestamp: outgoing.createdAt,
            isCurrentUser: true,
            displayBody: outgoing.displayText,
            deliveryState: .sending
        )
    }

    private func makeStore(
        client: SlackAPIClient? = nil,
        token: String = "token",
        outbox: OutgoingMessageOutbox
    ) -> AppStore {
        let store = AppStore(
            conversations: [
                Conversation(
                    id: "C1",
                    title: "general",
                    kind: .channel,
                    subtitle: nil,
                    isFavorite: false,
                    unreadCount: 0,
                    mentionCount: 0,
                    latestActivity: .distantPast,
                    messages: []
                )
            ],
            users: [
                WorkspaceUser(
                    id: "U0",
                    displayName: "You",
                    status: "",
                    isActive: true
                ),
                WorkspaceUser(
                    id: "U1",
                    displayName: "Alex",
                    status: "",
                    isActive: true
                ),
            ],
            connectionState: .connected("Acme"),
            slackAPI: client,
            credentials: SlackCredentials(
                accessToken: token,
                refreshToken: "refresh",
                expiresAt: .distantFuture,
                teamID: "T1",
                teamName: "Acme",
                userID: "U0"
            ),
            outgoingMessageOutbox: outbox
        )
        store.select("C1")
        return store
    }
}

private typealias OutboxHandler =
    @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

private enum OutboxStubError: Error {
    case missingHandler
    case unexpectedRequest
}

private final class OutboxRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: OutboxHandler] = [:]

    func register(token: String, handler: @escaping OutboxHandler) {
        lock.lock()
        handlers[token] = handler
        lock.unlock()
    }

    func unregister(token: String) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    func handler(for request: URLRequest) -> OutboxHandler? {
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

private final class OutboxURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = OutboxRegistry()

    static func register(token: String, handler: @escaping OutboxHandler) {
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
            client?.urlProtocol(self, didFailWithError: OutboxStubError.missingHandler)
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

private final class OutboxRequestRecorder: @unchecked Sendable {
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

private func outboxClient(
    token: String,
    handler: @escaping OutboxHandler
) -> SlackAPIClient {
    OutboxURLProtocol.register(token: token, handler: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OutboxURLProtocol.self]
    return SlackAPIClient(urlSession: URLSession(configuration: configuration))
}

private func outboxResponse(
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

private func materializedOutboxRequest(_ request: URLRequest) throws -> URLRequest {
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
            throw OutboxStubError.unexpectedRequest
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
