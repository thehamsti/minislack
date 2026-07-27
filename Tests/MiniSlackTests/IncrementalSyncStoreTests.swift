import Foundation
import Testing
@testable import MiniSlack

@Suite(.serialized)
@MainActor
struct IncrementalSyncStoreTests {
    @Test
    func markingConversationReadRefreshesDockBadgeImmediately() {
        let dockBadge = RecordingDockBadge()
        let store = AppStore(
            conversations: [conversation(id: "C1", unreadCount: 4)],
            notificationService: RecordingNotificationService(),
            dockBadgeService: dockBadge
        )
        store.select("C1")

        store.markSelectedConversationRead()

        #expect(dockBadge.unreadCounts == [0])
    }

    @Test
    func conversationMutesPersistPerWorkspace() {
        let teamID = "T-\(UUID().uuidString)"
        let key = "mutedConversationIDs.\(teamID)"
        defer {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let credentials = SlackCredentials(
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: .distantFuture,
            teamID: teamID,
            teamName: "Test",
            userID: "U1"
        )
        let firstStore = AppStore(
            conversations: [conversation(id: "C1", unreadCount: 0)],
            credentials: credentials
        )

        firstStore.toggleConversationMute("C1")

        let restoredStore = AppStore(
            conversations: [conversation(id: "C1", unreadCount: 0)],
            credentials: credentials
        )
        restoredStore.loadConversationMutes(workspaceID: teamID)
        #expect(restoredStore.isConversationMuted("C1"))

        restoredStore.toggleConversationMute("C1")
        #expect(!restoredStore.isConversationMuted("C1"))
    }

    @Test
    func signOutClearsNotificationRoutingAndDockBadge() {
        let notifications = RecordingNotificationService()
        let dockBadge = RecordingDockBadge()
        notifications.onOpenConversation = { _ in }
        let store = AppStore(
            conversations: [conversation(id: "C1", unreadCount: 3)],
            notificationService: notifications,
            dockBadgeService: dockBadge
        )

        store.signOut()

        #expect(!notifications.hasOpenHandler)
        #expect(dockBadge.unreadCounts == [0])
    }

    @Test
    func unreadBootstrapCountsHistoryButOnlyNotifiesForPostLaunchMessages() async throws {
        let token = "unread-bootstrap-\(UUID().uuidString)"
        let notifications = RecordingNotificationService()
        let client = makeIncrementalClient(accessToken: token) { request in
            switch request.url?.path {
            case "/api/conversations.info":
                return try incrementalJSONResponse(
                    request,
                    json: """
                    {
                      "ok": true,
                      "channel": {
                        "id": "C1",
                        "name": "general",
                        "last_read": "100.000000"
                      }
                    }
                    """
                )
            case "/api/conversations.history":
                let components = try #require(
                    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                )
                let query = Dictionary(
                    uniqueKeysWithValues: (components.queryItems ?? []).map {
                        ($0.name, $0.value ?? "")
                    }
                )
                #expect(query["oldest"] == "100.000000")
                return try incrementalResponse(
                    request,
                    messages: [
                        """
                        {
                          "ts":"201.000000",
                          "user":"U2",
                          "text":"Live message"
                        }
                        """,
                        """
                        {
                          "ts":"101.000000",
                          "user":"U2",
                          "text":"Historical mention <@U1>"
                        }
                        """,
                    ]
                )
            default:
                throw IncrementalStubError.invalidRequest
            }
        }
        defer { IncrementalURLProtocol.unregister(accessToken: token) }
        let store = liveStore(
            token: token,
            client: client,
            messages: [],
            notificationService: notifications
        )
        store.unreadBaselinedConversationIDs.remove("C1")

        try await store.pollConversation(
            IncrementalSyncDecision(
                conversationID: "C1",
                priority: .background,
                isInitialPoll: true
            ),
            detectingMessagesAfter: Date(timeIntervalSince1970: 200)
        )

        #expect(store.conversations[0].unreadCount == 2)
        #expect(store.conversations[0].mentionCount == 1)
        #expect(store.conversations[0].messages.count == 2)
        #expect(notifications.delivered.map(\.messageID) == ["201.000000"])
        #expect(
            store.readCursorsByConversationID["C1"]?.remoteID
                == "100.000000"
        )
        store.clearWorkspaceSession()
    }

    @Test
    func staleChannelUnreadZeroDoesNotRemoveSocketMessageFromUnreads() async throws {
        let token = "stale-channel-unread-\(UUID().uuidString)"
        let message = Message(
            author: "Maya",
            authorUserID: "U2",
            body: "Socket message",
            timestamp: Date(timeIntervalSince1970: 101),
            remoteID: "101.000000"
        )
        let client = makeIncrementalClient(accessToken: token) { request in
            switch request.url?.path {
            case "/api/conversations.info":
                try incrementalJSONResponse(
                    request,
                    json: """
                    {
                      "ok": true,
                      "channel": {
                        "id": "C1",
                        "name": "general",
                        "last_read": "100.000000",
                        "unread_count_display": 0
                      }
                    }
                    """
                )
            case "/api/conversations.history":
                try incrementalResponse(
                    request,
                    messages: [
                        """
                        {
                          "ts":"101.000000",
                          "user":"U2",
                          "text":"Socket message"
                        }
                        """
                    ]
                )
            default:
                throw IncrementalStubError.invalidRequest
            }
        }
        defer { IncrementalURLProtocol.unregister(accessToken: token) }
        let store = liveStore(token: token, client: client, messages: [message])
        store.conversations[0].unreadCount = 1
        store.unreadBaselinedConversationIDs.remove("C1")

        try await store.pollConversation(
            IncrementalSyncDecision(
                conversationID: "C1",
                priority: .background,
                isInitialPoll: false
            ),
            detectingMessagesAfter: Date(timeIntervalSince1970: 90)
        )

        #expect(store.conversations[0].unreadCount == 1)
        #expect(store.unreadConversations.map(\.id) == ["C1"])
        store.clearWorkspaceSession()
    }

    @Test
    func unreadBootstrapFetchesOnePagePerTurnAndStopsAfterFourPages() async throws {
        let token = "bounded-bootstrap-\(UUID().uuidString)"
        let historyRequests = IncrementalRequestLog()
        let client = makeIncrementalClient(accessToken: token) { request in
            switch request.url?.path {
            case "/api/conversations.info":
                return try incrementalJSONResponse(
                    request,
                    json: """
                    {
                      "ok": true,
                      "channel": {
                        "id": "C1",
                        "name": "general",
                        "last_read": "100.000000"
                      }
                    }
                    """
                )
            case "/api/conversations.history":
                historyRequests.append(request)
                let pageNumber = historyRequests.count
                let upperBound = 161 - ((pageNumber - 1) * 15)
                let lowerBound = upperBound - 15
                return try incrementalResponse(
                    request,
                    messages: (lowerBound ..< upperBound).reversed().map {
                        messageJSON(timestamp: $0)
                    },
                    nextCursor: "page-\(pageNumber + 1)"
                )
            default:
                throw IncrementalStubError.invalidRequest
            }
        }
        defer { IncrementalURLProtocol.unregister(accessToken: token) }
        let store = liveStore(
            token: token,
            client: client,
            messages: []
        )
        store.unreadBaselinedConversationIDs.remove("C1")
        let decision = IncrementalSyncDecision(
            conversationID: "C1",
            priority: .background,
            isInitialPoll: true
        )

        for _ in 0 ..< 4 {
            try await store.pollConversation(
                decision,
                detectingMessagesAfter: Date(timeIntervalSince1970: 200)
            )
        }

        #expect(historyRequests.count == 4)
        #expect(!store.incrementalSyncCatchups.keys.contains("C1"))
        #expect(store.conversations[0].unreadCount == 60)
        #expect(store.conversations[0].messages.count == 60)
        store.clearWorkspaceSession()
    }

    @Test
    func notificationAuthorizationDoesNotBlockTheFirstPoll() async throws {
        let defaults = UserDefaults.standard
        let key = IncrementalSyncMode.defaultsKey
        let previousMode = defaults.object(forKey: key)
        defaults.set(IncrementalSyncMode.conservative.rawValue, forKey: key)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let token = "authorization-\(UUID().uuidString)"
        let requests = IncrementalRequestLog()
        let authorization = BlockingNotificationService()
        let client = makeIncrementalClient(accessToken: token) { request in
            requests.append(request)
            #expect(request.url?.path == "/api/conversations.history")
            return try incrementalResponse(request, messages: [])
        }
        defer { IncrementalURLProtocol.unregister(accessToken: token) }
        let store = liveStore(
            token: token,
            client: client,
            messages: [],
            notificationService: authorization
        )

        store.startIncrementalSync()
        for _ in 0 ..< 100 {
            if requests.count > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(authorization.didRequestAuthorization)
        #expect(requests.count == 1)
        authorization.release()
        store.clearWorkspaceSession()
    }

    @Test
    func pollingPagesPastFifteenMessagesWithoutSkippingBurst() async throws {
        let token = "burst-\(UUID().uuidString)"
        let requests = IncrementalRequestLog()
        let client = makeIncrementalClient(accessToken: token) { request in
            requests.append(request)
            let components = try #require(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }
            )
            #expect(query["oldest"] == "100.000000")
            #expect(query["inclusive"] == "true")
            #expect(query["limit"] == "15")
            if query["cursor"] == nil {
                return try incrementalResponse(
                    request,
                    messages: (106 ... 120).reversed().map {
                        messageJSON(timestamp: $0)
                    },
                    nextCursor: "older"
                )
            }
            #expect(query["cursor"] == "older")
            return try incrementalResponse(
                request,
                messages: (100 ... 105).reversed().map {
                    messageJSON(timestamp: $0)
                }
            )
        }
        defer { IncrementalURLProtocol.unregister(accessToken: token) }
        let existing = Message(
            author: "Maya",
            authorUserID: "U2",
            body: "Existing",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100.000000"
        )
        let store = liveStore(
            token: token,
            client: client,
            messages: [existing]
        )

        let decision = IncrementalSyncDecision(
            conversationID: "C1",
            priority: .selected,
            isInitialPoll: false
        )
        try await store.pollConversation(
            decision,
            detectingMessagesAfter: Date(timeIntervalSince1970: 90)
        )
        try await store.pollConversation(
            decision,
            detectingMessagesAfter: Date(timeIntervalSince1970: 90)
        )

        let conversation = try #require(store.conversations.first)
        #expect(conversation.messages.count == 21)
        #expect(conversation.unreadCount == 20)
        #expect(conversation.messages.last?.remoteID == "120.000000")
        #expect(requests.count == 2)
        store.clearWorkspaceSession()
    }

    @Test
    func initialBaselineReactionKeepsMessageTimestamp() async throws {
        let token = "reaction-\(UUID().uuidString)"
        let client = makeIncrementalClient(accessToken: token) { request in
            try incrementalResponse(
                request,
                messages: [
                    """
                    {
                      "ts":"100.000000",
                      "user":"U1",
                      "text":"Existing",
                      "reactions":[
                        {"name":"eyes","count":1,"users":["U2"]}
                      ]
                    }
                    """,
                ]
            )
        }
        defer { IncrementalURLProtocol.unregister(accessToken: token) }
        let existing = Message(
            author: "You",
            authorUserID: "U1",
            body: "Existing",
            timestamp: Date(timeIntervalSince1970: 100),
            remoteID: "100.000000",
            isCurrentUser: true
        )
        let store = liveStore(
            token: token,
            client: client,
            messages: [existing]
        )

        try await store.pollConversation(
            IncrementalSyncDecision(
                conversationID: "C1",
                priority: .selected,
                isInitialPoll: true
            ),
            detectingMessagesAfter: Date(timeIntervalSince1970: 200)
        )

        let reaction = try #require(
            store.activityItems.first { $0.kind == .reaction }
        )
        #expect(reaction.date == Date(timeIntervalSince1970: 100))
        #expect(store.conversations[0].unreadCount == 0)
        store.clearWorkspaceSession()
    }

    @Test
    func delayedPollCannotMutateMatchingChannelAfterWorkspaceSwitch() async throws {
        let token = "delayed-\(UUID().uuidString)"
        let gate = IncrementalResponseGate()
        let client = makeIncrementalClient(accessToken: token) { request in
            gate.begin(request)
            return try incrementalResponse(
                request,
                messages: [messageJSON(timestamp: 101)]
            )
        }
        defer {
            gate.release()
            IncrementalURLProtocol.unregister(accessToken: token)
        }
        let store = liveStore(
            token: token,
            client: client,
            messages: [
                Message(
                    author: "Maya",
                    body: "Old workspace",
                    timestamp: Date(timeIntervalSince1970: 100),
                    remoteID: "100.000000"
                ),
            ]
        )
        let poll = Task {
            try await store.pollConversation(
                IncrementalSyncDecision(
                    conversationID: "C1",
                    priority: .selected,
                    isInitialPoll: false
                ),
                detectingMessagesAfter: Date(timeIntervalSince1970: 90)
            )
        }
        for _ in 0 ..< 100 {
            if gate.hasRequest {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.hasRequest)

        store.clearWorkspaceSession()
        let betaMessage = Message(
            author: "Beta",
            body: "New workspace",
            timestamp: Date(timeIntervalSince1970: 500),
            remoteID: "500.000000"
        )
        store.credentials = credentials(
            token: "beta",
            teamID: "T2",
            teamName: "Beta"
        )
        store.connectionState = .connected("Beta")
        store.conversations = [
            conversation(id: "C1", unreadCount: 0, messages: [betaMessage])
        ]
        gate.release()

        await #expect(throws: (any Error).self) {
            try await poll.value
        }
        #expect(gate.authorization == "Bearer \(token)")
        #expect(store.conversations[0].messages == [betaMessage])
        store.clearWorkspaceSession()
    }

    private func conversation(id: String, unreadCount: Int) -> Conversation {
        conversation(id: id, unreadCount: unreadCount, messages: [])
    }

    private func conversation(
        id: String,
        unreadCount: Int,
        messages: [Message]
    ) -> Conversation {
        Conversation(
            id: id,
            title: "General",
            kind: .channel,
            isFavorite: false,
            unreadCount: unreadCount,
            mentionCount: 0,
            latestActivity: .now,
            messages: messages
        )
    }

    private func liveStore(
        token: String,
        client: SlackAPIClient,
        messages: [Message],
        notificationService: (any MessageNotificationDelivering)? = nil
    ) -> AppStore {
        return AppStore(
            conversations: [
                conversation(id: "C1", unreadCount: 0, messages: messages),
            ],
            users: [
                WorkspaceUser(
                    id: "U1",
                    displayName: "You",
                    status: "",
                    isActive: true
                ),
                WorkspaceUser(
                    id: "U2",
                    displayName: "Maya",
                    status: "",
                    isActive: true
                ),
            ],
            connectionState: .connected("Acme"),
            slackAPI: client,
            credentials: credentials(
                token: token,
                teamID: "T1",
                teamName: "Acme"
            ),
            notificationService:
                notificationService ?? RecordingNotificationService(),
            dockBadgeService: RecordingDockBadge()
        )
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
            userID: "U1"
        )
    }
}

@MainActor
private final class RecordingNotificationService: MessageNotificationDelivering {
    var onOpenConversation: ((String) -> Void)?
    private(set) var delivered: [LocalMessageNotification] = []

    var hasOpenHandler: Bool {
        onOpenConversation != nil
    }

    func requestAuthorizationIfNeeded() async {}

    func deliver(_ notification: LocalMessageNotification) async {
        delivered.append(notification)
    }
}

@MainActor
private final class BlockingNotificationService: MessageNotificationDelivering {
    var onOpenConversation: ((String) -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var didRequestAuthorization = false

    func requestAuthorizationIfNeeded() async {
        didRequestAuthorization = true
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func deliver(_ notification: LocalMessageNotification) async {}

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class RecordingDockBadge: DockBadgeUpdating {
    private(set) var unreadCounts: [Int] = []

    func update(unreadCount: Int) {
        unreadCounts.append(unreadCount)
    }
}

private typealias IncrementalRequestHandler =
    @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

private enum IncrementalStubError: Error {
    case missingHandler
    case invalidRequest
}

private final class IncrementalStubRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: IncrementalRequestHandler] = [:]

    func register(
        accessToken: String,
        handler: @escaping IncrementalRequestHandler
    ) {
        lock.withLock {
            handlers[accessToken] = handler
        }
    }

    func unregister(accessToken: String) {
        lock.withLock {
            handlers[accessToken] = nil
        }
    }

    func handler(for request: URLRequest) -> IncrementalRequestHandler? {
        let authorization = request.value(
            forHTTPHeaderField: "Authorization"
        ) ?? ""
        let token = authorization.hasPrefix("Bearer ")
            ? String(authorization.dropFirst(7))
            : ""
        return lock.withLock {
            handlers[token]
        }
    }
}

private final class IncrementalURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = IncrementalStubRegistry()

    static func register(
        accessToken: String,
        handler: @escaping IncrementalRequestHandler
    ) {
        registry.register(accessToken: accessToken, handler: handler)
    }

    static func unregister(accessToken: String) {
        registry.unregister(accessToken: accessToken)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "slack.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.registry.handler(for: request) else {
            client?.urlProtocol(
                self,
                didFailWithError: IncrementalStubError.missingHandler
            )
            return
        }
        do {
            let result = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: result.0,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class IncrementalRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.withLock {
            requests.append(request)
        }
    }

    var count: Int {
        lock.withLock { requests.count }
    }
}

private final class IncrementalResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var responseGate = DispatchSemaphore(value: 0)
    private var requestAuthorization: String?

    func begin(_ request: URLRequest) {
        let gate = lock.withLock { () -> DispatchSemaphore in
            requestAuthorization = request.value(
                forHTTPHeaderField: "Authorization"
            )
            return responseGate
        }
        _ = gate.wait(timeout: .now() + 5)
    }

    func release() {
        lock.withLock { responseGate }.signal()
    }

    var hasRequest: Bool {
        lock.withLock { requestAuthorization != nil }
    }

    var authorization: String? {
        lock.withLock { requestAuthorization }
    }
}

private func makeIncrementalClient(
    accessToken: String,
    handler: @escaping IncrementalRequestHandler
) -> SlackAPIClient {
    IncrementalURLProtocol.register(
        accessToken: accessToken,
        handler: handler
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [IncrementalURLProtocol.self]
    return SlackAPIClient(urlSession: URLSession(configuration: configuration))
}

private func incrementalResponse(
    _ request: URLRequest,
    messages: [String],
    nextCursor: String? = nil
) throws -> (HTTPURLResponse, Data) {
    let metadata = nextCursor.map {
        #","response_metadata":{"next_cursor":"\#($0)"}"#
    } ?? ""
    return try incrementalJSONResponse(
        request,
        json: """
        {"ok":true,"messages":[\(messages.joined(separator: ","))]\(metadata)}
        """
    )
}

private func incrementalJSONResponse(
    _ request: URLRequest,
    json: String
) throws -> (HTTPURLResponse, Data) {
    guard let url = request.url,
          let response = HTTPURLResponse(
              url: url,
              statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/json"]
          )
    else {
        throw IncrementalStubError.invalidRequest
    }
    return (response, Data(json.utf8))
}

private func messageJSON(timestamp: Int) -> String {
    """
    {
      "ts":"\(timestamp).000000",
      "user":"U2",
      "text":"Message \(timestamp)"
    }
    """
}
