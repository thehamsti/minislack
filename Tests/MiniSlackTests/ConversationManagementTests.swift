import Foundation
import Testing
@testable import MiniSlack

@MainActor
struct ConversationManagementTests {
    @Test
    func discoversAndJoinsPaginatedPublicChannels() async throws {
        let token = "discover-\(UUID().uuidString)"
        let requests = ManagementRequestRecorder()
        let client = managementClient(token: token) { request in
            requests.append(request)
            switch request.url?.path {
            case "/api/conversations.list":
                let cursor = URLComponents(
                    url: try #require(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems?.first { $0.name == "cursor" }?.value
                if cursor == "page-2" {
                    return try managementResponse(
                        for: request,
                        json: """
                        {
                          "ok": true,
                          "channels": [{
                            "id": "C1",
                            "name": "alpha",
                            "is_member": true,
                            "num_members": 8
                          }],
                          "response_metadata": {"next_cursor": ""}
                        }
                        """
                    )
                }
                return try managementResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "channels": [{
                        "id": "C2",
                        "name": "zeta",
                        "is_member": false,
                        "num_members": 24,
                        "purpose": {"value": "Launch planning"}
                      }],
                      "response_metadata": {"next_cursor": "page-2"}
                    }
                    """
                )
            case "/api/conversations.join":
                return try managementResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "channel": {
                        "id": "C2",
                        "name": "zeta",
                        "is_member": true,
                        "is_private": false,
                        "created": 500,
                        "purpose": {"value": "Launch planning"}
                      }
                    }
                    """
                )
            default:
                throw ManagementStubError.unexpectedRequest
            }
        }
        defer { ManagementURLProtocol.unregister(token: token) }
        let store = liveStore(client: client, token: token)

        try await store.refreshPublicChannels()

        #expect(store.publicChannels.map(\.name) == ["alpha", "zeta"])
        #expect(store.publicChannels.first { $0.id == "C2" }?.memberCount == 24)
        #expect(
            requests.values.filter { $0.url?.path == "/api/conversations.list" }
                .count == 2
        )

        let channel = try #require(
            store.publicChannels.first { $0.id == "C2" }
        )
        try await store.joinPublicChannel(channel)

        #expect(store.destination == .conversation("C2"))
        #expect(store.selectedConversation?.title == "zeta")
        #expect(store.selectedConversation?.subtitle == "Launch planning")
        #expect(store.publicChannels.first { $0.id == "C2" }?.isMember == true)
        #expect(
            try requestBody(
                requests.values.first { $0.url?.path == "/api/conversations.join" }
            )["channel"] as? String == "C2"
        )
    }

    @Test
    func createsPublicAndPrivateChannelsThenLeavesThem() async throws {
        let token = "create-\(UUID().uuidString)"
        let requests = ManagementRequestRecorder()
        let client = managementClient(token: token) { request in
            requests.append(request)
            switch request.url?.path {
            case "/api/conversations.create":
                let body = try requestBody(request)
                let isPrivate = body["is_private"] as? Bool == true
                let id = isPrivate ? "GPRIVATE" : "CPUBLIC"
                return try managementResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "channel": {
                        "id": "\(id)",
                        "name": "\(body["name"] as? String ?? "")",
                        "is_private": \(isPrivate),
                        "is_member": true,
                        "created": 700
                      }
                    }
                    """
                )
            case "/api/conversations.leave":
                return try managementResponse(
                    for: request,
                    json: #"{"ok":true}"#
                )
            default:
                throw ManagementStubError.unexpectedRequest
            }
        }
        defer { ManagementURLProtocol.unregister(token: token) }
        let store = liveStore(client: client, token: token)

        try await store.createChannel(name: "Private Planning", isPrivate: true)

        #expect(store.selectedConversation?.id == "GPRIVATE")
        #expect(store.selectedConversation?.title == "private-planning")
        #expect(store.selectedConversation?.isPrivate == true)
        #expect(store.selectedConversation?.systemImage == "lock.fill")

        try await store.leaveChannel("GPRIVATE")

        #expect(store.destination == .unreadInbox)
        #expect(!store.conversations.contains { $0.id == "GPRIVATE" })

        try await store.createChannel(name: "Public Room", isPrivate: false)
        try await store.leaveChannel("CPUBLIC")

        #expect(store.publicChannels.first { $0.id == "CPUBLIC" }?.isMember == false)
        let createBodies = try requests.values
            .filter { $0.url?.path == "/api/conversations.create" }
            .map(requestBody)
        #expect(createBodies.map { $0["name"] as? String } == [
            "private-planning",
            "public-room",
        ])
        #expect(createBodies.map { $0["is_private"] as? Bool } == [true, false])
    }

    @Test
    func startsGroupDMWithTwoToEightDistinctWorkspaceUsers() async throws {
        let token = "group-\(UUID().uuidString)"
        let requests = ManagementRequestRecorder()
        let client = managementClient(token: token) { request in
            requests.append(request)
            guard request.url?.path == "/api/conversations.open" else {
                throw ManagementStubError.unexpectedRequest
            }
            return try managementResponse(
                for: request,
                json: #"{"ok":true,"channel":{"id":"G1"}}"#
            )
        }
        defer { ManagementURLProtocol.unregister(token: token) }
        let users = (0 ... 9).map {
            WorkspaceUser(
                id: "U\($0)",
                displayName: "Person \($0)",
                status: "",
                isActive: true
            )
        }
        let store = liveStore(
            client: client,
            token: token,
            users: users,
            currentUserID: "U0"
        )

        #expect(!store.groupDirectMessageCandidates.map(\.id).contains("U0"))
        await #expect(throws: ConversationManagementError.invalidGroupSize) {
            try await store.startGroupDirectMessage(with: ["U1"])
        }
        await #expect(throws: ConversationManagementError.invalidGroupSize) {
            try await store.startGroupDirectMessage(
                with: (1 ... 9).map { "U\($0)" }
            )
        }
        await #expect(throws: ConversationManagementError.invalidGroupMembers) {
            try await store.startGroupDirectMessage(with: ["U0", "U1"])
        }

        try await store.startGroupDirectMessage(with: ["U1", "U1", "U2"])

        #expect(store.destination == .conversation("G1"))
        #expect(store.selectedConversation?.kind == .groupDirectMessage)
        #expect(store.selectedConversation?.participants.map(\.id) == ["U1", "U2"])
        #expect(store.selectedConversation?.title == "Person 1, Person 2")
        #expect(
            try requestBody(
                requests.values.first { $0.url?.path == "/api/conversations.open" }
            )["users"] as? String == "U1,U2"
        )
    }

    @Test
    func updatesChannelDetailsArchiveStateAndMembers() async throws {
        let token = "manage-\(UUID().uuidString)"
        let requests = ManagementRequestRecorder()
        let client = managementClient(token: token) { request in
            requests.append(request)
            switch request.url?.path {
            case "/api/conversations.rename":
                return try managementResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "channel": {
                        "id": "C1",
                        "name": "launch-room",
                        "is_member": true
                      }
                    }
                    """
                )
            case "/api/conversations.members":
                return try managementResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "members": ["U0", "U1"],
                      "response_metadata": {"next_cursor": ""}
                    }
                    """
                )
            case "/api/conversations.setTopic",
                 "/api/conversations.setPurpose",
                 "/api/conversations.invite",
                 "/api/conversations.kick",
                 "/api/conversations.archive",
                 "/api/conversations.unarchive":
                return try managementResponse(
                    for: request,
                    json: #"{"ok":true}"#
                )
            default:
                throw ManagementStubError.unexpectedRequest
            }
        }
        defer { ManagementURLProtocol.unregister(token: token) }
        let users = [
            WorkspaceUser(id: "U0", displayName: "You", status: "", isActive: true),
            WorkspaceUser(id: "U1", displayName: "Maya", status: "", isActive: true),
            WorkspaceUser(id: "U2", displayName: "Alex", status: "", isActive: true),
        ]
        let channel = Conversation(
            id: "C1",
            title: "launch",
            kind: .channel,
            subtitle: "Old topic",
            isFavorite: false,
            topic: "Old topic",
            purpose: "Old purpose",
            unreadCount: 0,
            mentionCount: 0,
            latestActivity: .now,
            messages: []
        )
        let store = liveStore(
            client: client,
            token: token,
            users: users,
            conversations: [channel]
        )

        try await store.updateChannelDetails(
            conversationID: "C1",
            name: "Launch Room",
            topic: "Shipping this week",
            purpose: "Coordinate the launch"
        )
        let members = try await store.channelMembers(conversationID: "C1")
        try await store.updateChannelMembers(
            conversationID: "C1",
            selectedUserIDs: ["U0", "U2"]
        )
        try await store.setChannelArchived(true, conversationID: "C1")
        try await store.setChannelArchived(false, conversationID: "C1")

        #expect(store.selectedConversation == nil)
        #expect(store.conversations[0].title == "launch-room")
        #expect(store.conversations[0].topic == "Shipping this week")
        #expect(store.conversations[0].purpose == "Coordinate the launch")
        #expect(store.conversations[0].subtitle == "Shipping this week")
        #expect(store.conversations[0].isArchived == false)
        #expect(members.map(\.id) == ["U1", "U0"])
        #expect(Set(store.conversations[0].participants.map(\.id)) == ["U0", "U2"])

        let invite = try #require(
            requests.values.first { $0.url?.path == "/api/conversations.invite" }
        )
        let kick = try #require(
            requests.values.first { $0.url?.path == "/api/conversations.kick" }
        )
        #expect(try requestBody(invite)["users"] as? String == "U2")
        #expect(try requestBody(kick)["user"] as? String == "U1")
        #expect(
            requests.values.map(\.url?.path).contains("/api/conversations.archive")
        )
        #expect(
            requests.values.map(\.url?.path).contains("/api/conversations.unarchive")
        )
    }

    @Test
    func changingGroupMembersOpensAReplacementAndKeepsTheOriginal() async throws {
        let token = "replace-group-\(UUID().uuidString)"
        let requests = ManagementRequestRecorder()
        let client = managementClient(token: token) { request in
            requests.append(request)
            guard request.url?.path == "/api/conversations.open" else {
                throw ManagementStubError.unexpectedRequest
            }
            let users = try requestBody(request)["users"] as? String
            let id = users == "U1" ? "D1" : "G1"
            return try managementResponse(
                for: request,
                json: #"{"ok":true,"channel":{"id":"\#(id)"}}"#
            )
        }
        defer { ManagementURLProtocol.unregister(token: token) }
        let users = (0 ... 3).map {
            WorkspaceUser(
                id: "U\($0)",
                displayName: "Person \($0)",
                status: "",
                isActive: true
            )
        }
        let original = Conversation(
            id: "G0",
            title: "Person 1, Person 2",
            kind: .groupDirectMessage,
            subtitle: "Group DM · 2 people",
            isFavorite: false,
            participants: [users[1], users[2]],
            unreadCount: 0,
            mentionCount: 0,
            latestActivity: .now,
            messages: []
        )
        let store = liveStore(
            client: client,
            token: token,
            users: users,
            conversations: [original],
            currentUserID: "U0"
        )

        try await store.replaceGroupDirectMessageParticipants(
            conversationID: "G0",
            with: ["U1", "U3"]
        )

        #expect(store.destination == .conversation("G1"))
        #expect(store.conversations.contains { $0.id == "G0" })
        #expect(
            Set(
                try #require(store.conversations.first { $0.id == "G1" })
                    .participants.map(\.id)
            ) == ["U1", "U3"]
        )

        try await store.replaceGroupDirectMessageParticipants(
            conversationID: "G0",
            with: ["U1"]
        )

        #expect(store.destination == .conversation("D1"))
        #expect(store.selectedConversation?.kind == .directMessage)
        #expect(store.selectedConversation?.participantUserID == "U1")
        #expect(
            try requests.values
                .filter { $0.url?.path == "/api/conversations.open" }
                .map(requestBody)
                .compactMap { $0["users"] as? String } == ["U1,U3", "U1"]
        )
    }

    @Test
    func explainsWhenSlackScopesNeedReauthorization() async throws {
        let token = "missing-scope-\(UUID().uuidString)"
        let client = managementClient(token: token) { request in
            guard request.url?.path == "/api/conversations.rename" else {
                throw ManagementStubError.unexpectedRequest
            }
            return try managementResponse(
                for: request,
                json: #"{"ok":false,"error":"missing_scope"}"#
            )
        }
        defer { ManagementURLProtocol.unregister(token: token) }
        let channel = Conversation(
            id: "C1",
            title: "launch",
            kind: .channel,
            subtitle: nil,
            isFavorite: false,
            unreadCount: 0,
            mentionCount: 0,
            latestActivity: .now,
            messages: []
        )
        let store = liveStore(
            client: client,
            token: token,
            conversations: [channel]
        )

        await #expect(
            throws: ConversationManagementError.reconnectRequired(
                "rename this channel"
            )
        ) {
            try await store.updateChannelDetails(
                conversationID: "C1",
                name: "renamed",
                topic: "",
                purpose: ""
            )
        }
    }

    @Test
    func initialSnapshotKeepsOnlyJoinedPublicChannels() throws {
        let data = Data(
            """
            [
              {"id":"C1","name":"joined","is_member":true},
              {"id":"C2","name":"browse-me","is_member":false},
              {"id":"C3","name":"archived","is_member":true,"is_archived":true},
              {"id":"G1","name":"private","is_private":true}
            ]
            """.utf8
        )
        let conversations = try JSONDecoder().decode(
            [SlackConversationDTO].self,
            from: data
        )

        let snapshot = SlackAPIClient.makeSnapshot(
            users: [],
            conversations: conversations
        )

        #expect(Set(snapshot.conversations.map(\.id)) == ["C1", "C3", "G1"])
        #expect(snapshot.conversations.first { $0.id == "G1" }?.isPrivate == true)
        #expect(snapshot.conversations.first { $0.id == "C3" }?.isArchived == true)
    }

    @Test
    func backgroundGroupDMHydrationIsLimitedToTenPriorityConversations() async throws {
        let token = "group-hydration-\(UUID().uuidString)"
        let requests = ManagementRequestRecorder()
        let client = managementClient(token: token) { request in
            requests.append(request)
            guard request.url?.path == "/api/conversations.members" else {
                throw ManagementStubError.unexpectedRequest
            }
            return try managementResponse(
                for: request,
                json: """
                {
                  "ok": true,
                  "members": ["U0", "U1"],
                  "response_metadata": {"next_cursor": ""}
                }
                """
            )
        }
        defer { ManagementURLProtocol.unregister(token: token) }
        let conversations = (0 ..< 12).map { index in
            Conversation(
                id: "G\(index)",
                title: "Group DM",
                kind: .groupDirectMessage,
                subtitle: nil,
                isFavorite: false,
                unreadCount: 0,
                mentionCount: 0,
                latestActivity: Date(timeIntervalSince1970: TimeInterval(index)),
                messages: []
            )
        }
        let store = liveStore(
            client: client,
            token: token,
            users: [
                WorkspaceUser(id: "U0", displayName: "You", status: "", isActive: true),
                WorkspaceUser(id: "U1", displayName: "Maya", status: "", isActive: true),
            ],
            conversations: conversations
        )

        await store.hydratePriorityGroupDirectMessages(
            session: try store.captureWorkspaceSession(),
            requestSpacing: .zero
        )

        let hydratedIDs = Set(requests.values.compactMap { request in
            request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first { $0.name == "channel" }?
                    .value
            }
        })
        #expect(hydratedIDs == Set((2 ..< 12).map { "G\($0)" }))
        #expect(requests.values.count == 10)
        #expect(store.conversations.filter { $0.title == "Maya" }.count == 10)
    }

    @Test
    func validatesAndNormalizesChannelNames() {
        #expect(AppStore.normalizedChannelName("  Project Launch  ") == "project-launch")
        #expect(AppStore.isValidChannelName("Project Launch"))
        #expect(AppStore.isValidChannelName("release_2026"))
        #expect(!AppStore.isValidChannelName(""))
        #expect(!AppStore.isValidChannelName("project!"))
        #expect(!AppStore.isValidChannelName(String(repeating: "a", count: 81)))
    }

    private func liveStore(
        client: SlackAPIClient,
        token: String,
        users: [WorkspaceUser] = [],
        conversations: [Conversation] = [],
        currentUserID: String = "U0"
    ) -> AppStore {
        AppStore(
            conversations: conversations,
            users: users,
            connectionState: .connected("Acme"),
            slackAPI: client,
            credentials: SlackCredentials(
                accessToken: token,
                refreshToken: "refresh",
                expiresAt: .distantFuture,
                teamID: "T1",
                teamName: "Acme",
                userID: currentUserID
            )
        )
    }
}

private typealias ManagementHandler =
    @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

private enum ManagementStubError: Error {
    case missingHandler
    case unexpectedRequest
}

private final class ManagementRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: ManagementHandler] = [:]

    func register(token: String, handler: @escaping ManagementHandler) {
        lock.lock()
        handlers[token] = handler
        lock.unlock()
    }

    func unregister(token: String) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    func handler(for request: URLRequest) -> ManagementHandler? {
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

private final class ManagementURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = ManagementRegistry()

    static func register(token: String, handler: @escaping ManagementHandler) {
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
            client?.urlProtocol(self, didFailWithError: ManagementStubError.missingHandler)
            return
        }
        do {
            let request = try requestWithMaterializedBody(request)
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

private final class ManagementRequestRecorder: @unchecked Sendable {
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

private func managementClient(
    token: String,
    handler: @escaping ManagementHandler
) -> SlackAPIClient {
    ManagementURLProtocol.register(token: token, handler: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ManagementURLProtocol.self]
    return SlackAPIClient(urlSession: URLSession(configuration: configuration))
}

private func managementResponse(
    for request: URLRequest,
    status: Int = 200,
    json: String
) throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    let response = try #require(
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
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
            throw ManagementStubError.unexpectedRequest
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

private func requestBody(_ request: URLRequest?) throws -> [String: Any] {
    let request = try #require(request)
    let data = try #require(request.httpBody)
    return try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
}
