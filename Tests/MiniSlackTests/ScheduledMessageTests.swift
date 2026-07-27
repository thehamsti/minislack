import Foundation
import Testing
@testable import MiniSlack

@MainActor
struct ScheduledMessageTests {
    @Test
    func previewSchedulingPreservesSemanticTagsAndClearsDraft() async throws {
        let store = previewStore()
        store.composerDraft = ComposerDraft(
            text: "Hi @Alex in #general :tada:",
            tags: [
                ComposerTag(
                    kind: .user,
                    entityID: "U1",
                    displayText: "@Alex",
                    range: NSRange(location: 3, length: 5)
                ),
                ComposerTag(
                    kind: .channel,
                    entityID: "C1",
                    displayText: "#general",
                    range: NSRange(location: 12, length: 8)
                ),
            ]
        )
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let postAt = now.addingTimeInterval(3_600)

        try await store.scheduleDraft(at: postAt, now: now)

        let scheduled = try #require(store.scheduledMessages(for: "C1").first)
        #expect(scheduled.id.hasPrefix("preview-"))
        #expect(scheduled.text == "Hi <@U1> in <#C1> :tada:")
        #expect(scheduled.postAt == postAt)
        #expect(store.composerDraft.isEmpty)
        #expect(store.scheduledMessagesState.hasLoaded)
        #expect(
            store.scheduledMessageDisplayText(scheduled)
                == "Hi @Alex in #general 🎉"
        )
    }

    @Test
    func previewSchedulingValidatesDateAndSupportsDeletion() async throws {
        let store = previewStore()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        store.draft = "Later"

        await #expect(throws: ScheduledMessageError.invalidDate) {
            try await store.scheduleDraft(
                at: now.addingTimeInterval(59),
                now: now
            )
        }
        #expect(store.draft == "Later")

        try await store.scheduleDraft(
            at: now.addingTimeInterval(3_600),
            now: now
        )
        let scheduled = try #require(store.scheduledMessages(for: "C1").first)
        try await store.deleteScheduledMessage(scheduled)

        #expect(store.scheduledMessages(for: "C1").isEmpty)
    }

    @Test
    func liveSchedulingRefreshAndDeleteUseSlack() async throws {
        let token = "scheduled-\(UUID().uuidString)"
        let requests = ScheduledRequestRecorder()
        let client = scheduledClient(token: token) { request in
            let request = try materializedScheduledRequest(request)
            requests.append(request)
            switch request.url?.path {
            case "/api/chat.scheduleMessage":
                return try scheduledResponse(
                    request,
                    json: """
                    {
                      "ok": true,
                      "scheduled_message_id": "Q1",
                      "channel": "C1",
                      "post_at": 1900003600,
                      "message": {"text": "Hello <@U1>"}
                    }
                    """
                )
            case "/api/chat.scheduledMessages.list":
                return try scheduledResponse(
                    request,
                    json: """
                    {
                      "ok": true,
                      "scheduled_messages": [{
                        "id": "Q1",
                        "channel_id": "C1",
                        "post_at": 1900003600,
                        "text": "Hello <@U1>"
                      }],
                      "response_metadata": {"next_cursor": ""}
                    }
                    """
                )
            case "/api/chat.deleteScheduledMessage":
                return try scheduledResponse(request, json: #"{"ok":true}"#)
            default:
                throw ScheduledStubError.unexpectedRequest
            }
        }
        defer { ScheduledURLProtocol.unregister(token: token) }

        let store = liveStore(client: client, token: token)
        store.composerDraft = ComposerDraft(
            text: "Hello @Alex",
            tags: [
                ComposerTag(
                    kind: .user,
                    entityID: "U1",
                    displayText: "@Alex",
                    range: NSRange(location: 6, length: 5)
                )
            ]
        )
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        try await store.scheduleDraft(
            at: now.addingTimeInterval(3_600),
            now: now
        )
        await store.refreshScheduledMessages()
        let message = try #require(store.scheduledMessages(for: "C1").first)
        try await store.deleteScheduledMessage(message)

        #expect(
            requests.paths == [
                "/api/chat.scheduleMessage",
                "/api/chat.scheduledMessages.list",
                "/api/chat.deleteScheduledMessage",
            ]
        )
        let scheduleBody = try #require(requests.values.first?.httpBody)
        let schedulePayload = try #require(
            JSONSerialization.jsonObject(with: scheduleBody) as? [String: String]
        )
        #expect(schedulePayload["text"] == "Hello <@U1>")
        #expect(store.scheduledMessagesState.messages.isEmpty)
    }

    @Test
    func presetsAlwaysProduceFutureDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        for preset in ScheduledMessagePreset.allCases {
            let date = preset.date(relativeTo: now, calendar: calendar)
            #expect(date.timeIntervalSince(now) >= 60)
            #expect(AppStore.isValidScheduledDate(date, now: now))
        }
    }

    private func previewStore() -> AppStore {
        let store = AppStore(
            conversations: [conversation()],
            users: [
                WorkspaceUser(
                    id: "U1",
                    displayName: "Alex",
                    status: "",
                    isActive: true
                )
            ]
        )
        store.select("C1")
        return store
    }

    private func liveStore(client: SlackAPIClient, token: String) -> AppStore {
        let store = AppStore(
            conversations: [conversation()],
            users: [
                WorkspaceUser(
                    id: "U1",
                    displayName: "Alex",
                    status: "",
                    isActive: true
                )
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
            )
        )
        store.select("C1")
        return store
    }

    private func conversation() -> Conversation {
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
    }
}

private typealias ScheduledHandler =
    @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

private enum ScheduledStubError: Error {
    case missingHandler
    case unexpectedRequest
}

private final class ScheduledRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: ScheduledHandler] = [:]

    func register(token: String, handler: @escaping ScheduledHandler) {
        lock.lock()
        handlers[token] = handler
        lock.unlock()
    }

    func unregister(token: String) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    func handler(for request: URLRequest) -> ScheduledHandler? {
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

private final class ScheduledURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = ScheduledRegistry()

    static func register(token: String, handler: @escaping ScheduledHandler) {
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
            client?.urlProtocol(self, didFailWithError: ScheduledStubError.missingHandler)
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

private final class ScheduledRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var values: [URLRequest] {
        lock.lock()
        let values = requests
        lock.unlock()
        return values
    }

    var paths: [String] {
        values.compactMap(\.url?.path)
    }

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}

private func scheduledClient(
    token: String,
    handler: @escaping ScheduledHandler
) -> SlackAPIClient {
    ScheduledURLProtocol.register(token: token, handler: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScheduledURLProtocol.self]
    return SlackAPIClient(urlSession: URLSession(configuration: configuration))
}

private func scheduledResponse(
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

private func materializedScheduledRequest(_ request: URLRequest) throws -> URLRequest {
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
            throw ScheduledStubError.unexpectedRequest
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
