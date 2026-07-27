import Foundation
import Testing
@testable import MiniSlack

struct SlackCapabilityAPITests {
    @Test
    func messageActionsUseTheExpectedSlackMethodsAndArguments() async throws {
        let token = "actions-\(UUID().uuidString)"
        let requests = CapabilityRequestRecorder()
        let client = capabilityClient(token: token) { request in
            requests.append(try requestWithMaterializedBody(request))
            let path = try #require(request.url?.path)
            let json = path == "/api/chat.getPermalink"
                ? #"{"ok":true,"permalink":"https://acme.slack.com/archives/C1/p123"}"#
                : #"{"ok":true}"#
            return try capabilityResponse(for: request, json: json)
        }
        defer { CapabilityURLProtocol.unregister(token: token) }

        try await client.updateMessage(
            channelID: "C1",
            timestamp: "123.456",
            text: "Updated",
            accessToken: token
        )
        try await client.setReaction(
            name: "eyes",
            channelID: "C1",
            timestamp: "123.456",
            isRemoving: false,
            accessToken: token
        )
        try await client.setPinned(
            true,
            channelID: "C1",
            timestamp: "123.456",
            accessToken: token
        )
        let permalink = try await client.permalink(
            channelID: "C1",
            timestamp: "123.456",
            accessToken: token
        )
        try await client.deleteMessage(
            channelID: "C1",
            timestamp: "123.456",
            accessToken: token
        )

        let recorded = requests.values
        #expect(recorded.map(\.url?.path) == [
            "/api/chat.update",
            "/api/reactions.add",
            "/api/pins.add",
            "/api/chat.getPermalink",
            "/api/chat.delete",
        ])
        let updateBody = try #require(recorded[0].httpBody)
        let update = try #require(
            JSONSerialization.jsonObject(with: updateBody) as? [String: String]
        )
        #expect(update == [
            "channel": "C1",
            "text": "Updated",
            "ts": "123.456",
        ])
        #expect(permalink.absoluteString == "https://acme.slack.com/archives/C1/p123")
    }

    @Test
    func threadRepliesAreBoundedPaginatedAndMappedForDisplay() async throws {
        let token = "thread-\(UUID().uuidString)"
        let client = capabilityClient(token: token) { request in
            let components = try #require(
                request.url.flatMap {
                    URLComponents(url: $0, resolvingAgainstBaseURL: false)
                }
            )
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }
            )
            #expect(components.path == "/api/conversations.replies")
            #expect(query["channel"] == "C1")
            #expect(query["ts"] == "100.000")
            #expect(query["limit"] == "25")
            #expect(query["cursor"] == "next")
            return try capabilityResponse(
                for: request,
                json: """
                {
                  "ok": true,
                  "messages": [{
                    "ts": "101.000",
                    "user": "U1",
                    "text": "Hello <@U2>"
                  }],
                  "response_metadata": {"next_cursor": "older"}
                }
                """
            )
        }
        defer { CapabilityURLProtocol.unregister(token: token) }

        let users = [
            WorkspaceUser(id: "U1", displayName: "Maya", status: "", isActive: true),
            WorkspaceUser(id: "U2", displayName: "Alex", status: "", isActive: true),
        ]
        let page = try await client.fetchThreadPage(
            channelID: "C1",
            threadTimestamp: "100.000",
            cursor: "next",
            limit: 25,
            accessToken: token,
            users: users,
            currentUserID: "U2"
        )

        #expect(page.nextCursor == "older")
        #expect(page.messages.count == 1)
        #expect(page.messages[0].author == "Maya")
        #expect(page.messages[0].displayBody == "Hello @Alex")
    }

    @Test
    func schedulingAndRemoteSearchDecodeCompactResults() async throws {
        let token = "search-\(UUID().uuidString)"
        let client = capabilityClient(token: token) { request in
            switch request.url?.path {
            case "/api/chat.scheduleMessage":
                return try capabilityResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "scheduled_message_id": "Q1",
                      "channel": "C1",
                      "post_at": 1900000000,
                      "message": {"text": "Later"}
                    }
                    """
                )
            case "/api/chat.scheduledMessages.list":
                #expect(request.httpMethod == "POST")
                return try capabilityResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "scheduled_messages": [{
                        "id": 1298393284,
                        "channel_id": "C1",
                        "post_at": 1900000000,
                        "text": "Later"
                      }],
                      "response_metadata": {"next_cursor": ""}
                    }
                    """
                )
            case "/api/search.messages":
                return try capabilityResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "messages": {
                        "matches": [{
                          "channel": {"id": "C1", "name": "general"},
                          "ts": "123.000",
                          "user_name": "Maya",
                          "text": "Launch notes",
                          "permalink": "https://acme.slack.com/archives/C1/p123"
                        }]
                      }
                    }
                    """
                )
            case "/api/search.files":
                return try capabilityResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "files": {
                        "matches": [{
                          "id": "F1",
                          "name": "launch.pdf",
                          "title": "Launch brief",
                          "mimetype": "application/pdf",
                          "permalink": "https://acme.slack.com/files/F1",
                          "channels": ["C1"]
                        }]
                      }
                    }
                    """
                )
            default:
                throw CapabilityStubError.unexpectedRequest
            }
        }
        defer { CapabilityURLProtocol.unregister(token: token) }

        let scheduled = try await client.scheduleMessage(
            channelID: "C1",
            text: "Later",
            postAt: Date(timeIntervalSince1970: 1_900_000_000),
            accessToken: token
        )
        let messages = try await client.searchMessages(
            query: "launch",
            accessToken: token
        )
        let (scheduledMessages, nextCursor) = try await client.fetchScheduledMessages(
            accessToken: token
        )
        let files = try await client.searchFiles(
            query: "launch",
            accessToken: token
        )

        #expect(scheduled.id == "Q1")
        #expect(scheduled.postAt == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(scheduledMessages.first?.id == "1298393284")
        #expect(nextCursor == nil)
        #expect(messages.first?.title == "Maya in #general")
        #expect(messages.first?.conversationID == "C1")
        #expect(files.first?.title == "Launch brief")
        #expect(files.first?.kind == .file)
    }

    @Test
    func groupDMAndChannelCreationReturnConversationIdentifiers() async throws {
        let token = "conversations-\(UUID().uuidString)"
        let client = capabilityClient(token: token) { request in
            switch request.url?.path {
            case "/api/conversations.open":
                return try capabilityResponse(
                    for: request,
                    json: #"{"ok":true,"channel":{"id":"G1"}}"#
                )
            case "/api/conversations.create":
                return try capabilityResponse(
                    for: request,
                    json: #"{"ok":true,"channel":{"id":"C2","name":"launch"}}"#
                )
            default:
                throw CapabilityStubError.unexpectedRequest
            }
        }
        defer { CapabilityURLProtocol.unregister(token: token) }

        let groupID = try await client.openGroupDirectMessage(
            userIDs: ["U1", "U2"],
            accessToken: token
        )
        let channel = try await client.createConversation(
            name: "launch",
            isPrivate: false,
            accessToken: token
        )

        #expect(groupID == "G1")
        #expect(channel.id == "C2")
        #expect(channel.name == "launch")
    }

    @Test
    func channelManagementUsesExpectedMethodsAndPaginatesMembers() async throws {
        let token = "manage-\(UUID().uuidString)"
        let requests = CapabilityRequestRecorder()
        let client = capabilityClient(token: token) { request in
            requests.append(try requestWithMaterializedBody(request))
            let path = try #require(request.url?.path)
            if path == "/api/conversations.rename" {
                return try capabilityResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "channel": {"id": "C1", "name": "launch-room"}
                    }
                    """
                )
            }
            if path == "/api/conversations.members" {
                let cursor = URLComponents(
                    url: try #require(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems?.first { $0.name == "cursor" }?.value
                return try capabilityResponse(
                    for: request,
                    json: cursor == "next"
                        ? """
                          {
                            "ok": true,
                            "members": ["U2"],
                            "response_metadata": {"next_cursor": ""}
                          }
                          """
                        : """
                          {
                            "ok": true,
                            "members": ["U1"],
                            "response_metadata": {"next_cursor": "next"}
                          }
                          """
                )
            }
            return try capabilityResponse(
                for: request,
                json: #"{"ok":true}"#
            )
        }
        defer { CapabilityURLProtocol.unregister(token: token) }

        let renamed = try await client.renameConversation(
            channelID: "C1",
            name: "launch-room",
            accessToken: token
        )
        try await client.setConversationTopic(
            channelID: "C1",
            topic: "Shipping",
            accessToken: token
        )
        try await client.setConversationPurpose(
            channelID: "C1",
            purpose: "Coordinate launch",
            accessToken: token
        )
        try await client.inviteUsers(["U2", "U3"], to: "C1", accessToken: token)
        try await client.removeUser("U1", from: "C1", accessToken: token)
        try await client.setConversationArchived(
            channelID: "C1",
            isArchived: true,
            accessToken: token
        )
        try await client.setConversationArchived(
            channelID: "C1",
            isArchived: false,
            accessToken: token
        )
        let members = try await client.fetchConversationMemberIDs(
            channelID: "C1",
            accessToken: token
        )

        #expect(renamed.name == "launch-room")
        #expect(members == ["U1", "U2"])
        #expect(requests.values.map(\.url?.path) == [
            "/api/conversations.rename",
            "/api/conversations.setTopic",
            "/api/conversations.setPurpose",
            "/api/conversations.invite",
            "/api/conversations.kick",
            "/api/conversations.archive",
            "/api/conversations.unarchive",
            "/api/conversations.members",
            "/api/conversations.members",
        ])
        let inviteBody = try #require(requests.values[3].httpBody)
        let invite = try #require(
            JSONSerialization.jsonObject(with: inviteBody) as? [String: String]
        )
        #expect(invite == ["channel": "C1", "users": "U2,U3"])
        let removeBody = try #require(requests.values[4].httpBody)
        let remove = try #require(
            JSONSerialization.jsonObject(with: removeBody) as? [String: String]
        )
        #expect(remove == ["channel": "C1", "user": "U1"])
    }

    @Test
    func rateLimitsAreRetriedWithoutBlockingTheMainActor() async throws {
        let token = "rate-limit-\(UUID().uuidString)"
        let attempts = CapabilityCounter()
        let client = capabilityClient(token: token) { request in
            let attempt = attempts.increment()
            if attempt == 1 {
                return try capabilityResponse(
                    for: request,
                    statusCode: 429,
                    headers: ["Retry-After": "0"],
                    json: #"{"ok":false,"error":"ratelimited"}"#
                )
            }
            return try capabilityResponse(for: request, json: #"{"ok":true}"#)
        }
        defer { CapabilityURLProtocol.unregister(token: token) }

        try await client.deleteMessage(
            channelID: "C1",
            timestamp: "123.456",
            accessToken: token
        )

        #expect(attempts.value == 2)
    }

    @Test
    func serverErrorsAreRetried() async throws {
        let token = "server-error-\(UUID().uuidString)"
        let attempts = CapabilityCounter()
        let client = capabilityClient(token: token) { request in
            if attempts.increment() == 1 {
                return try capabilityResponse(
                    for: request,
                    statusCode: 503,
                    json: #"{"ok":false,"error":"unavailable"}"#
                )
            }
            return try capabilityResponse(
                for: request,
                json: #"{"ok":true,"emoji":{}}"#
            )
        }
        defer { CapabilityURLProtocol.unregister(token: token) }

        _ = try await client.fetchCustomEmojiURLs(accessToken: token)

        #expect(attempts.value == 2)
    }

    @Test
    func workspaceSnapshotDoesNotBlockOnGroupMemberHydration() async throws {
        let token = "startup-\(UUID().uuidString)"
        let requests = CapabilityRequestRecorder()
        let client = capabilityClient(token: token) { request in
            requests.append(request)
            switch request.url?.path {
            case "/api/users.list":
                return try capabilityResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "members": [
                        {
                          "id": "U0",
                          "name": "current.user",
                          "profile": {"display_name": "Current User"}
                        },
                        {
                          "id": "U1",
                          "name": "maya",
                          "profile": {"display_name": "Maya"}
                        }
                      ],
                      "response_metadata": {"next_cursor": ""}
                    }
                    """
                )
            case "/api/conversations.list":
                return try capabilityResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "channels": [{
                        "id": "G1",
                        "name": "mpdm-current.user--maya-1",
                        "is_mpim": true,
                        "latest": {"ts": "1700000000.000000", "user": "U1", "text": "Hi"}
                      }],
                      "response_metadata": {"next_cursor": ""}
                    }
                    """
                )
            case "/api/emoji.list":
                return try capabilityResponse(
                    for: request,
                    json: #"{"ok":true,"emoji":{}}"#
                )
            default:
                throw CapabilityStubError.unexpectedRequest
            }
        }
        defer { CapabilityURLProtocol.unregister(token: token) }

        let snapshot = try await client.fetchWorkspace(
            accessToken: token,
            currentUserID: "U0"
        )

        #expect(snapshot.conversations.first?.title == "Maya")
        #expect(snapshot.conversations.first?.participants.map(\.id) == ["U1"])
        #expect(
            !requests.values.contains {
                $0.url?.path == "/api/conversations.members"
            }
        )
        #expect(
            !requests.values.contains {
                $0.url?.path == "/api/emoji.list"
            }
        )
    }

    @Test
    func transientTransportErrorsAreRetried() async throws {
        let token = "transport-\(UUID().uuidString)"
        let attempts = CapabilityCounter()
        let client = capabilityClient(token: token) { request in
            if attempts.increment() == 1 {
                throw URLError(.networkConnectionLost)
            }
            return try capabilityResponse(
                for: request,
                json: #"{"ok":true,"emoji":{}}"#
            )
        }
        defer { CapabilityURLProtocol.unregister(token: token) }

        _ = try await client.fetchCustomEmojiURLs(accessToken: token)

        #expect(attempts.value == 2)
    }

    @Test
    func ambiguousMutationTransportFailuresAreNotRetried() async throws {
        let token = "mutation-transport-\(UUID().uuidString)"
        let attempts = CapabilityCounter()
        let client = capabilityClient(token: token) { _ in
            _ = attempts.increment()
            throw URLError(.networkConnectionLost)
        }
        defer { CapabilityURLProtocol.unregister(token: token) }

        await #expect(throws: URLError.self) {
            try await client.deleteMessage(
                channelID: "C1",
                timestamp: "123.456",
                accessToken: token
            )
        }

        #expect(attempts.value == 1)
    }

    @Test
    func ambiguousMutationServerFailuresAreNotRetried() async throws {
        let token = "mutation-server-\(UUID().uuidString)"
        let attempts = CapabilityCounter()
        let client = capabilityClient(token: token) { request in
            _ = attempts.increment()
            return try capabilityResponse(
                for: request,
                statusCode: 503,
                json: #"{"ok":false,"error":"unavailable"}"#
            )
        }
        defer { CapabilityURLProtocol.unregister(token: token) }

        await #expect(throws: SlackAPIClient.APIError.http(503)) {
            try await client.deleteMessage(
                channelID: "C1",
                timestamp: "123.456",
                accessToken: token
            )
        }

        #expect(attempts.value == 1)
    }

    @Test
    func repeatedPaginationCursorFailsInsteadOfLoopingForever() async throws {
        let token = "cursor-\(UUID().uuidString)"
        let client = capabilityClient(token: token) { request in
            try capabilityResponse(
                for: request,
                json: """
                {
                  "ok": true,
                  "members": ["U1"],
                  "response_metadata": {"next_cursor": "same"}
                }
                """
            )
        }
        defer { CapabilityURLProtocol.unregister(token: token) }

        await #expect(throws: SlackAPIClient.APIError.invalidResponse) {
            try await client.fetchConversationMemberIDs(
                channelID: "G1",
                accessToken: token
            )
        }
    }
}

private typealias CapabilityHandler =
    @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

private enum CapabilityStubError: Error {
    case missingHandler
    case unexpectedRequest
}

private final class CapabilityRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: CapabilityHandler] = [:]

    func register(token: String, handler: @escaping CapabilityHandler) {
        lock.lock()
        handlers[token] = handler
        lock.unlock()
    }

    func unregister(token: String) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    func handler(for request: URLRequest) -> CapabilityHandler? {
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

private final class CapabilityURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = CapabilityRegistry()

    static func register(token: String, handler: @escaping CapabilityHandler) {
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
            client?.urlProtocol(self, didFailWithError: CapabilityStubError.missingHandler)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class CapabilityRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var values: [URLRequest] {
        lock.lock()
        let values = requests
        lock.unlock()
        return values
    }

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}

private final class CapabilityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        let value = count
        lock.unlock()
        return value
    }

    func increment() -> Int {
        lock.lock()
        count += 1
        let value = count
        lock.unlock()
        return value
    }
}

private func capabilityClient(
    token: String,
    handler: @escaping CapabilityHandler
) -> SlackAPIClient {
    CapabilityURLProtocol.register(token: token, handler: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CapabilityURLProtocol.self]
    return SlackAPIClient(urlSession: URLSession(configuration: configuration))
}

private func capabilityResponse(
    for request: URLRequest,
    statusCode: Int = 200,
    headers: [String: String] = [:],
    json: String
) throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    let response = try #require(
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"].merging(
                headers,
                uniquingKeysWith: { _, incoming in incoming }
            )
        )
    )
    return (response, Data(json.utf8))
}

private func requestWithMaterializedBody(_ request: URLRequest) throws -> URLRequest {
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
            throw CapabilityStubError.unexpectedRequest
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
