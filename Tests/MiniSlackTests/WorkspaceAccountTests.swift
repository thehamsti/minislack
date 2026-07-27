import Foundation
import Testing
@testable import MiniSlack

@Suite(.serialized)
@MainActor
struct WorkspaceAccountTests {
    @Test
    func cancelledWebAuthenticationReturnsFirstLoginToDisconnected() async {
        let authenticator = CancelledSlackOAuthWebAuthenticator()
        let store = AppStore(
            conversations: [],
            users: [],
            connectionState: .disconnected,
            slackOAuth: SlackOAuthService(
                configuration: SlackConfiguration(clientID: "123.456")
            ),
            slackOAuthWebAuthenticator: authenticator,
            notificationService: WorkspaceNotificationService(),
            dockBadgeService: WorkspaceDockBadgeService()
        )

        await store.signInWithSlack()

        #expect(store.connectionState == .disconnected)
        #expect(authenticator.requestedURL?.host == "slack.com")
        #expect(authenticator.requestedURL?.path == "/oauth/v2/authorize")
    }

    @Test
    func collectionUpsertsPerTeamAndPersistsActiveWorkspace() throws {
        let acme = credentials(teamID: "T1", teamName: "Acme", token: "old")
        let beta = credentials(teamID: "T2", teamName: "Beta", token: "beta")
        let refreshedAcme = credentials(
            teamID: "T1",
            teamName: "Acme",
            token: "refreshed"
        )
        var collection = SlackCredentialCollection(
            credentials: [acme, beta],
            activeWorkspaceID: "T1"
        )

        collection.upsert(refreshedAcme)

        #expect(collection.credentials.count == 2)
        #expect(collection.credential(for: "T1")?.accessToken == "refreshed")
        #expect(collection.activeCredentials == refreshedAcme)
        #expect(collection.accountSummaries.map(\.teamName) == ["Acme", "Beta"])
        #expect(collection.accountSummaries.first?.isActive == true)

        let data = try JSONEncoder().encode(collection)
        let restored = try JSONDecoder().decode(
            SlackCredentialCollection.self,
            from: data
        )
        #expect(restored == collection)
    }

    @Test
    func selectingAndRemovingAccountsDoesNotLeakActivation() {
        let acme = credentials(teamID: "T1", teamName: "Acme", token: "acme")
        let beta = credentials(teamID: "T2", teamName: "Beta", token: "beta")
        var collection = SlackCredentialCollection(credentials: [acme, beta])

        #expect(collection.select("T2") == beta)
        #expect(collection.activeWorkspaceID == "T2")
        collection.remove("T2")

        #expect(collection.activeWorkspaceID == nil)
        #expect(collection.credentials == [acme])
        #expect(collection.select("missing") == nil)
        #expect(collection.activeWorkspaceID == nil)
    }

    @Test
    func signingOutRemovesOnlyCurrentAccountAndClearsWorkspaceSession() throws {
        let acme = credentials(teamID: "T1", teamName: "Acme", token: "acme")
        let beta = credentials(teamID: "T2", teamName: "Beta", token: "beta")
        let credentialStore = MemoryCredentialStore(
            SlackCredentialCollection(
                credentials: [acme, beta],
                activeWorkspaceID: "T1"
            )
        )
        let store = AppStore(
            conversations: [
                Conversation(
                    id: "C1",
                    title: "general",
                    kind: .channel,
                    subtitle: nil,
                    isFavorite: false,
                    unreadCount: 2,
                    mentionCount: 1,
                    latestActivity: .now,
                    messages: []
                )
            ],
            users: [
                WorkspaceUser(
                    id: "U1",
                    displayName: "Alex",
                    status: "",
                    isActive: true
                )
            ],
            connectionState: .connected("Acme"),
            credentialStore: credentialStore,
            credentials: acme
        )

        store.refreshWorkspaceAccounts()
        store.signOut()

        let remaining = try credentialStore.loadCollection()
        #expect(remaining.credentials == [beta])
        #expect(remaining.activeWorkspaceID == nil)
        #expect(store.workspaceAccounts.map(\.teamID) == ["T2"])
        #expect(store.credentials == nil)
        #expect(store.conversations.isEmpty)
        #expect(store.users.isEmpty)
        #expect(store.connectionState == .disconnected)
    }

    @Test
    func inMemoryCredentialSeamSwitchesActiveAccount() throws {
        let acme = credentials(teamID: "T1", teamName: "Acme", token: "acme")
        let beta = credentials(teamID: "T2", teamName: "Beta", token: "beta")
        let store = MemoryCredentialStore(
            SlackCredentialCollection(
                credentials: [acme, beta],
                activeWorkspaceID: "T1"
            )
        )

        let selected = try store.select(teamID: "T2")

        #expect(selected == beta)
        #expect(try store.load() == beta)
        #expect(
            try store.loadCollection().accountSummaries.first {
                $0.teamID == "T2"
            }?.isActive == true
        )
    }

    @Test
    func failedAuthorizedWorkspaceRestoresPreviousConnectedWorkspace() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceSwitchURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let oauth = SlackOAuthService(
            configuration: SlackConfiguration(clientID: "123.456"),
            urlSession: urlSession
        )
        let authorizationURL = try await oauth.beginAuthorization()
        let state = try #require(
            URLComponents(
                url: authorizationURL,
                resolvingAgainstBaseURL: false
            )?.queryItems?.first { $0.name == "state" }?.value
        )
        let acme = credentials(teamID: "T1", teamName: "Acme", token: "acme")
        let credentialStore = MemoryCredentialStore(
            SlackCredentialCollection(
                credentials: [acme],
                activeWorkspaceID: acme.teamID
            )
        )
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: snapshotRoot)
        }
        let store = AppStore(
            conversations: [],
            users: [],
            connectionState: .connected(acme.teamName),
            slackOAuth: oauth,
            credentialStore: credentialStore,
            slackAPI: SlackAPIClient(urlSession: urlSession),
            credentials: acme,
            notificationService: WorkspaceNotificationService(),
            dockBadgeService: WorkspaceDockBadgeService(),
            snapshotStoreRootURL: snapshotRoot
        )
        let callback = try #require(
            URL(string: "minislack://oauth/slack?code=new-code&state=\(state)")
        )

        await store.handleSlackCallback(callback)

        #expect(store.credentials == acme)
        #expect(store.connectionState == .connected(acme.teamName))
        #expect(store.transientError != nil)
        let stored = try credentialStore.loadCollection()
        #expect(stored.activeWorkspaceID == acme.teamID)
        #expect(stored.credentials.map(\.teamID).sorted() == ["T1", "T2"])
        store.clearWorkspaceSession()
    }

    @Test
    func failedSavedWorkspaceSwitchRestoresPreviousConnectedWorkspace() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceSwitchURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let acme = credentials(teamID: "T1", teamName: "Acme", token: "acme")
        let beta = credentials(teamID: "T2", teamName: "Beta", token: "beta")
        let credentialStore = MemoryCredentialStore(
            SlackCredentialCollection(
                credentials: [acme, beta],
                activeWorkspaceID: acme.teamID
            )
        )
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: snapshotRoot)
        }
        let store = AppStore(
            conversations: [],
            users: [],
            connectionState: .connected(acme.teamName),
            slackOAuth: SlackOAuthService(
                configuration: SlackConfiguration(clientID: "123.456"),
                urlSession: urlSession
            ),
            credentialStore: credentialStore,
            slackAPI: SlackAPIClient(urlSession: urlSession),
            credentials: acme,
            notificationService: WorkspaceNotificationService(),
            dockBadgeService: WorkspaceDockBadgeService(),
            snapshotStoreRootURL: snapshotRoot
        )

        await #expect(throws: (any Error).self) {
            try await store.switchWorkspace(to: beta.teamID)
        }

        #expect(store.credentials == acme)
        #expect(store.connectionState == .connected(acme.teamName))
        #expect(store.transientError != nil)
        #expect(try credentialStore.loadCollection().activeWorkspaceID == acme.teamID)
        store.clearWorkspaceSession()
    }

    @Test
    func startupTimeoutTransitionsOutOfLoadingState() async throws {
        SlowWorkspaceURLProtocol.prepare(shouldHang: true)
        defer {
            SlowWorkspaceURLProtocol.prepare(shouldHang: true)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowWorkspaceURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let acme = credentials(teamID: "T1", teamName: "Acme", token: "acme")
        let credentialStore = MemoryCredentialStore(
            SlackCredentialCollection(
                credentials: [acme],
                activeWorkspaceID: acme.teamID
            )
        )
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: snapshotRoot)
        }
        let store = AppStore(
            conversations: [],
            users: [],
            connectionState: .disconnected,
            slackOAuth: SlackOAuthService(
                configuration: SlackConfiguration(clientID: "123.456"),
                urlSession: urlSession
            ),
            credentialStore: credentialStore,
            slackAPI: SlackAPIClient(
                urlSession: urlSession,
                requestCoordinator: SlackRequestCoordinator(minimumSpacing: .zero)
            ),
            notificationService: WorkspaceNotificationService(),
            dockBadgeService: WorkspaceDockBadgeService(),
            workspaceLoadTimeout: .milliseconds(500),
            snapshotStoreRootURL: snapshotRoot
        )

        await store.restoreSession()

        guard case let .failed(message) = store.connectionState else {
            Issue.record("Expected startup to fail instead of remaining in loading")
            return
        }
        #expect(message == "Slack took too long to load this workspace. Try again.")
        #expect(store.workspaceAccounts.map(\.teamID) == ["T1"])

        SlowWorkspaceURLProtocol.prepare(shouldHang: false)
        await store.retrySlackConnection()

        #expect(store.credentials == acme)
        #expect(store.connectionState == .connected(acme.teamName))
        store.clearWorkspaceSession()
    }

    @Test
    func staleSavedMessageRestoreCannotMutateAClearedSession() async throws {
        let teamID = "stale-\(UUID().uuidString)"
        let acme = credentials(teamID: teamID, teamName: "Acme", token: "acme")
        let store = AppStore(
            conversations: [],
            users: [],
            connectionState: .connected(acme.teamName),
            credentials: acme
        )
        let session = try store.captureWorkspaceSession()

        store.clearWorkspaceSession()
        await store.loadSavedMessages(for: teamID, session: session)

        #expect(store.savedMessageStore == nil)
        #expect(store.savedMessages.isEmpty)
    }

    @Test
    func concurrentCredentialRefreshesShareOneSlackRequest() async throws {
        CredentialRefreshURLProtocol.prepare(blocksResponse: false)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialRefreshURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let expired = SlackCredentials(
            accessToken: "expired",
            refreshToken: "refresh-expired",
            expiresAt: .distantPast,
            teamID: "T1",
            teamName: "Acme",
            userID: "U-T1"
        )
        let credentialStore = MemoryCredentialStore(
            SlackCredentialCollection(
                credentials: [expired],
                activeWorkspaceID: expired.teamID
            )
        )
        let store = AppStore(
            conversations: [],
            users: [],
            connectionState: .connected(expired.teamName),
            slackOAuth: SlackOAuthService(
                configuration: SlackConfiguration(clientID: "123.456"),
                urlSession: urlSession
            ),
            credentialStore: credentialStore,
            credentials: expired
        )
        let session = try store.captureWorkspaceSession()

        async let first = store.activeCredentials(for: session)
        async let second = store.activeCredentials(for: session)
        let refreshed = try await [first, second]

        #expect(refreshed.allSatisfy { $0.accessToken == "refreshed" })
        #expect(CredentialRefreshURLProtocol.requestCount == 1)
        #expect(store.credentials?.accessToken == "refreshed")
        #expect(try credentialStore.load()?.accessToken == "refreshed")
        store.clearWorkspaceSession()
    }

    @Test
    func workspaceSwitchDuringRefreshCannotRestoreStaleCredentials() async throws {
        CredentialRefreshURLProtocol.prepare(blocksResponse: true)
        defer { CredentialRefreshURLProtocol.releaseResponse() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialRefreshURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let expired = SlackCredentials(
            accessToken: "expired",
            refreshToken: "refresh-expired",
            expiresAt: .distantPast,
            teamID: "T1",
            teamName: "Acme",
            userID: "U-T1"
        )
        let beta = credentials(teamID: "T2", teamName: "Beta", token: "beta")
        let credentialStore = MemoryCredentialStore(
            SlackCredentialCollection(
                credentials: [expired, beta],
                activeWorkspaceID: expired.teamID
            )
        )
        let store = AppStore(
            conversations: [],
            users: [],
            connectionState: .connected(expired.teamName),
            slackOAuth: SlackOAuthService(
                configuration: SlackConfiguration(clientID: "123.456"),
                urlSession: urlSession
            ),
            credentialStore: credentialStore,
            credentials: expired
        )
        let session = try store.captureWorkspaceSession()
        let refresh = Task {
            try await store.activeCredentials(for: session)
        }
        await Task.yield()
        #expect(await CredentialRefreshURLProtocol.waitForRequest())

        store.clearWorkspaceSession()
        try credentialStore.save(beta)
        store.credentials = beta
        store.connectionState = .connected(beta.teamName)
        CredentialRefreshURLProtocol.releaseResponse()

        await #expect(throws: (any Error).self) {
            try await refresh.value
        }
        #expect(store.credentials == beta)
        #expect(try credentialStore.load() == beta)
        #expect(
            try credentialStore.loadCollection()
                .credential(for: expired.teamID)?.accessToken == "expired"
        )
        store.clearWorkspaceSession()
    }

    @Test
    func completedSendCannotMutateMatchingChannelAfterWorkspaceSwitch() async throws {
        WorkspaceSendURLProtocol.prepare()
        defer { WorkspaceSendURLProtocol.releaseResponse() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceSendURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let acme = credentials(teamID: "T1", teamName: "Acme", token: "acme")
        let beta = credentials(teamID: "T2", teamName: "Beta", token: "beta")
        let localMessageID = UUID()
        let oldMessage = Message(
            id: localMessageID,
            author: "You",
            body: "old workspace",
            timestamp: .now,
            isCurrentUser: true,
            deliveryState: .sending
        )
        let outboxRoot = FileManager.default.temporaryDirectory
            .appending(path: "mini-slack-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outboxRoot) }
        let store = AppStore(
            conversations: [
                conversation(id: "C1", messages: [oldMessage])
            ],
            users: [],
            connectionState: .connected(acme.teamName),
            slackAPI: SlackAPIClient(urlSession: urlSession),
            credentials: acme,
            outgoingMessageOutbox: OutgoingMessageOutbox(
                workspaceID: acme.teamID,
                rootURL: outboxRoot
            ),
            notificationService: WorkspaceNotificationService(),
            dockBadgeService: WorkspaceDockBadgeService()
        )
        let send = Task {
            await store.sendOutgoingMessage(
                conversationID: "C1",
                semanticText: oldMessage.body,
                localMessageID: localMessageID
            )
        }
        for _ in 0 ..< 100 {
            if WorkspaceSendURLProtocol.hasRequest {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(WorkspaceSendURLProtocol.hasRequest)

        store.clearWorkspaceSession()
        let betaMessage = Message(
            id: localMessageID,
            author: "Beta user",
            body: "new workspace",
            timestamp: .now,
            remoteID: "beta-message"
        )
        store.credentials = beta
        store.connectionState = .connected(beta.teamName)
        store.conversations = [
            conversation(id: "C1", messages: [betaMessage])
        ]
        WorkspaceSendURLProtocol.releaseResponse()
        await send.value

        #expect(WorkspaceSendURLProtocol.authorization == "Bearer acme")
        #expect(store.conversations[0].messages == [betaMessage])
        store.clearWorkspaceSession()
    }

    private func credentials(
        teamID: String,
        teamName: String,
        token: String
    ) -> SlackCredentials {
        SlackCredentials(
            accessToken: token,
            refreshToken: "refresh-\(token)",
            expiresAt: .distantFuture,
            teamID: teamID,
            teamName: teamName,
            userID: "U-\(teamID)"
        )
    }

    private func conversation(
        id: String,
        messages: [Message]
    ) -> Conversation {
        Conversation(
            id: id,
            title: "general",
            kind: .channel,
            subtitle: nil,
            isFavorite: false,
            unreadCount: 0,
            mentionCount: 0,
            latestActivity: .now,
            messages: messages
        )
    }
}

private enum WorkspaceSwitchStubError: Error {
    case unexpectedRequest
}

private final class SlowWorkspaceStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldHang = true

    func prepare(shouldHang: Bool) {
        lock.withLock {
            self.shouldHang = shouldHang
        }
    }

    var hangs: Bool {
        lock.withLock { shouldHang }
    }
}

private final class SlowWorkspaceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = SlowWorkspaceStubState()

    static func prepare(shouldHang: Bool) {
        state.prepare(shouldHang: shouldHang)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "slack.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard !Self.state.hangs else {
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: WorkspaceSwitchStubError.unexpectedRequest
            )
            return
        }
        let json: String
        switch url.path {
        case "/api/users.list":
            json = #"{"ok":true,"members":[],"response_metadata":{"next_cursor":""}}"#
        case "/api/conversations.list":
            json = #"{"ok":true,"channels":[],"response_metadata":{"next_cursor":""}}"#
        case "/api/emoji.list":
            json = #"{"ok":true,"emoji":{}}"#
        default:
            client?.urlProtocol(
                self,
                didFailWithError: WorkspaceSwitchStubError.unexpectedRequest
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CredentialRefreshStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var responseGate: DispatchSemaphore?

    func prepare(blocksResponse: Bool) {
        lock.withLock {
            count = 0
            responseGate = blocksResponse
                ? DispatchSemaphore(value: 0)
                : nil
        }
    }

    func beginRequest() {
        let responseGate = lock.withLock { () -> DispatchSemaphore? in
            count += 1
            return self.responseGate
        }
        if let responseGate {
            _ = responseGate.wait(timeout: .now() + 5)
        } else {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func waitForRequest() async -> Bool {
        for _ in 0 ..< 500 {
            if requestCount > 0 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func releaseResponse() {
        lock.withLock { responseGate }?.signal()
    }

    var requestCount: Int {
        lock.withLock { count }
    }
}

private final class CredentialRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = CredentialRefreshStubState()

    static func prepare(blocksResponse: Bool) {
        state.prepare(blocksResponse: blocksResponse)
    }

    static func waitForRequest() async -> Bool {
        await state.waitForRequest()
    }

    static func releaseResponse() {
        state.releaseResponse()
    }

    static var requestCount: Int {
        state.requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/api/oauth.v2.access"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.beginRequest()
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: WorkspaceSwitchStubError.unexpectedRequest
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data(
                """
                {
                  "ok": true,
                  "access_token": "refreshed",
                  "refresh_token": "refresh-refreshed",
                  "expires_in": 3600
                }
                """.utf8
            )
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class WorkspaceSendStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = DispatchSemaphore(value: 0)
    private var responseGate = DispatchSemaphore(value: 0)
    private var requestAuthorization: String?

    func prepare() {
        lock.withLock {
            started = DispatchSemaphore(value: 0)
            responseGate = DispatchSemaphore(value: 0)
            requestAuthorization = nil
        }
    }

    func beginRequest(authorization: String?) {
        let values = lock.withLock { () -> (DispatchSemaphore, DispatchSemaphore) in
            requestAuthorization = authorization
            return (started, responseGate)
        }
        values.0.signal()
        _ = values.1.wait(timeout: .now() + 5)
    }

    func waitForRequest() -> Bool {
        let semaphore = lock.withLock { started }
        return semaphore.wait(timeout: .now() + 5) == .success
    }

    var hasRequest: Bool {
        lock.withLock { requestAuthorization != nil }
    }

    func releaseResponse() {
        lock.withLock { responseGate }.signal()
    }

    var authorization: String? {
        lock.withLock { requestAuthorization }
    }
}

private final class WorkspaceSendURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = WorkspaceSendStubState()

    static func prepare() {
        state.prepare()
    }

    static var hasRequest: Bool {
        state.hasRequest
    }

    static func releaseResponse() {
        state.releaseResponse()
    }

    static var authorization: String? {
        state.authorization
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/api/chat.postMessage"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.beginRequest(
            authorization: request.value(
                forHTTPHeaderField: "Authorization"
            )
        )
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: WorkspaceSwitchStubError.unexpectedRequest
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data(
                #"{"ok":true,"message":{"ts":"200.000001","text":"sent"}}"#.utf8
            )
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class WorkspaceSwitchURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "slack.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let result = try response(for: request)
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

    private func response(
        for request: URLRequest
    ) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else {
            throw WorkspaceSwitchStubError.unexpectedRequest
        }
        if url.path == "/api/oauth.v2.access" {
            return makeResponse(
                url: url,
                statusCode: 200,
                json: """
                {
                  "ok": true,
                  "team": {"id": "T2", "name": "Beta"},
                  "authed_user": {
                    "id": "U-T2",
                    "access_token": "beta",
                    "refresh_token": "refresh-beta",
                    "expires_in": 3600
                  }
                }
                """
            )
        }

        let authorization = request.value(
            forHTTPHeaderField: "Authorization"
        )
        if authorization == "Bearer beta" {
            return makeResponse(url: url, statusCode: 503, json: "{}")
        }
        guard authorization == "Bearer acme" else {
            throw WorkspaceSwitchStubError.unexpectedRequest
        }
        switch url.path {
        case "/api/users.list":
            return makeResponse(
                url: url,
                statusCode: 200,
                json: """
                {"ok":true,"members":[],"response_metadata":{"next_cursor":""}}
                """
            )
        case "/api/conversations.list":
            return makeResponse(
                url: url,
                statusCode: 200,
                json: """
                {"ok":true,"channels":[],"response_metadata":{"next_cursor":""}}
                """
            )
        case "/api/emoji.list":
            return makeResponse(
                url: url,
                statusCode: 200,
                json: #"{"ok":true,"emoji":{}}"#
            )
        default:
            throw WorkspaceSwitchStubError.unexpectedRequest
        }
    }

    private func makeResponse(
        url: URL,
        statusCode: Int,
        json: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(json.utf8)
        )
    }
}

@MainActor
private final class CancelledSlackOAuthWebAuthenticator: SlackOAuthWebAuthenticating {
    private(set) var requestedURL: URL?

    func authenticate(at url: URL) async throws -> URL {
        requestedURL = url
        throw SlackOAuthWebAuthenticationError.cancelled
    }

    func cancel() {}
}

@MainActor
private final class WorkspaceNotificationService: MessageNotificationDelivering {
    var onOpenConversation: ((String) -> Void)?

    func requestAuthorizationIfNeeded() async {}

    func deliver(_ notification: LocalMessageNotification) async {}
}

@MainActor
private final class WorkspaceDockBadgeService: DockBadgeUpdating {
    func update(unreadCount: Int) {}
}

private final class MemoryCredentialStore: SlackCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var collection: SlackCredentialCollection

    init(_ collection: SlackCredentialCollection = SlackCredentialCollection()) {
        self.collection = collection
    }

    func load() throws -> SlackCredentials? {
        lock.withLock {
            collection.activeCredentials
        }
    }

    func loadCollection() throws -> SlackCredentialCollection {
        lock.withLock {
            collection
        }
    }

    func save(_ credentials: SlackCredentials) throws {
        lock.withLock {
            collection.upsert(credentials)
        }
    }

    func select(teamID: String) throws -> SlackCredentials {
        try lock.withLock {
            guard let credentials = collection.select(teamID) else {
                throw SlackCredentialStore.StoreError.workspaceNotFound
            }
            return credentials
        }
    }

    func delete(teamID: String) throws {
        lock.withLock {
            collection.remove(teamID)
        }
    }
}
