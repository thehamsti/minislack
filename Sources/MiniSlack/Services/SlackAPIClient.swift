import Foundation

struct SlackWorkspaceSnapshot: Sendable {
    let users: [WorkspaceUser]
    let conversations: [Conversation]
}

struct SlackConversationMetadata: Sendable {
    let conversationID: String
    let createdAt: Date
    let latestActivity: Date
}

struct SlackMessagePage: Sendable {
    let messages: [Message]
    let nextCursor: String?
}

struct SlackAPIClient: Sendable {
    enum APIError: LocalizedError, Equatable {
        case http(Int)
        case rateLimited(Int)
        case slack(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case let .http(status):
                "Slack returned HTTP \(status)."
            case let .rateLimited(seconds):
                "Slack is rate limiting requests. Try again in \(seconds) seconds."
            case let .slack(error):
                "Slack API error: \(error)."
            case .invalidResponse:
                "Slack returned an invalid response."
            }
        }
    }

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func fetchWorkspace(
        accessToken: String,
        currentUserID: String
    ) async throws -> SlackWorkspaceSnapshot {
        async let users = fetchUsers(accessToken: accessToken)
        async let conversations = fetchConversations(accessToken: accessToken)
        let (userDTOs, conversationDTOs) = try await (users, conversations)
        let hydratedConversations = await hydrateGroupMembers(
            in: conversationDTOs,
            accessToken: accessToken
        )
        return Self.makeSnapshot(
            users: userDTOs,
            conversations: hydratedConversations,
            currentUserID: currentUserID
        )
    }

    func fetchMessages(
        channelID: String,
        accessToken: String,
        users: [WorkspaceUser],
        currentUserID: String
    ) async throws -> [Message] {
        try await fetchMessagePage(
            channelID: channelID,
            accessToken: accessToken,
            users: users,
            currentUserID: currentUserID
        ).messages
    }

    func fetchMessagePage(
        channelID: String,
        cursor: String? = nil,
        limit: Int = 50,
        accessToken: String,
        users: [WorkspaceUser],
        currentUserID: String
    ) async throws -> SlackMessagePage {
        var query = [
            URLQueryItem(name: "channel", value: channelID),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let response: SlackHistoryResponse = try await get(
            method: "conversations.history",
            query: query,
            accessToken: accessToken
        )
        try validate(response)
        let userMap = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
        let messages = response.messages
            .map { $0.message(users: userMap, currentUserID: currentUserID) }
            .sorted { $0.timestamp < $1.timestamp }
        let nextCursor = response.responseMetadata?.nextCursor
            .flatMap { $0.isEmpty ? nil : $0 }
        return SlackMessagePage(messages: messages, nextCursor: nextCursor)
    }

    func fetchConversationMetadata(
        channelID: String,
        accessToken: String
    ) async throws -> SlackConversationMetadata {
        let response: SlackConversationInfoResponse = try await get(
            method: "conversations.info",
            query: [URLQueryItem(name: "channel", value: channelID)],
            accessToken: accessToken
        )
        try validate(response)
        return Self.makeMetadata(from: response.channel)
    }

    static func makeMetadata(from conversation: SlackConversationDTO) -> SlackConversationMetadata {
        let createdAt = conversation.created
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? .distantPast
        let latestActivity = conversation.latest
            .flatMap { Self.date(fromSlackTimestamp: $0.timestamp) }
            ?? Self.date(fromSlackTimestamp: conversation.lastRead)
            ?? createdAt
        return SlackConversationMetadata(
            conversationID: conversation.id,
            createdAt: createdAt,
            latestActivity: latestActivity
        )
    }

    func openDirectMessage(userID: String, accessToken: String) async throws -> String {
        let response: SlackOpenConversationResponse = try await post(
            method: "conversations.open",
            body: ["users": userID],
            accessToken: accessToken
        )
        try validate(response)
        guard let channelID = response.channel?.id else {
            throw APIError.invalidResponse
        }
        return channelID
    }

    func sendMessage(channelID: String, text: String, accessToken: String) async throws -> SlackMessageDTO {
        let response: SlackPostMessageResponse = try await post(
            method: "chat.postMessage",
            body: ["channel": channelID, "text": text],
            accessToken: accessToken
        )
        try validate(response)
        guard let message = response.message else {
            throw APIError.invalidResponse
        }
        return message
    }

    func markRead(channelID: String, timestamp: String, accessToken: String) async throws {
        let response: SlackBaseResponse = try await post(
            method: "conversations.mark",
            body: ["channel": channelID, "ts": timestamp],
            accessToken: accessToken
        )
        try validate(response)
    }

    static func makeSnapshot(
        users userDTOs: [SlackUserDTO],
        conversations conversationDTOs: [SlackConversationDTO],
        currentUserID: String = ""
    ) -> SlackWorkspaceSnapshot {
        let visibleUsers = userDTOs
            .filter { !$0.deleted && !$0.isBot }
            .map(\.workspaceUser)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let userMap = Dictionary(uniqueKeysWithValues: visibleUsers.map { ($0.id, $0) })
        let groupMemberMap = Dictionary(
            uniqueKeysWithValues: userDTOs
                .filter { !$0.isBot }
                .map(\.workspaceUser)
                .map { ($0.id, $0) }
        )

        let conversations = conversationDTOs.compactMap { dto -> Conversation? in
            let participant = dto.user.flatMap { userMap[$0] }
            let groupParticipants = dto.members
                .filter { $0 != currentUserID }
                .compactMap { groupMemberMap[$0] }
            let title: String
            if dto.isIM {
                guard let participant else {
                    return nil
                }
                title = participant.displayName
            } else if dto.isGroupDirectMessage {
                title = groupParticipants.isEmpty
                    ? "Group DM"
                    : groupParticipants.map(\.displayName).joined(separator: ", ")
            } else {
                guard let name = dto.name else {
                    return nil
                }
                title = name
            }

            let latestMessage = dto.latest.map {
                $0.message(
                    users: userMap,
                    currentUserID: currentUserID
                )
            }
            let createdAt = dto.created
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                ?? .distantPast
            let latestActivity = latestMessage?.timestamp
                ?? Self.date(fromSlackTimestamp: dto.lastRead)
                ?? createdAt

            let kind: ConversationKind = if dto.isIM {
                .directMessage
            } else if dto.isGroupDirectMessage {
                .groupDirectMessage
            } else {
                .channel
            }

            return Conversation(
                id: dto.id,
                title: title,
                kind: kind,
                subtitle: dto.isGroupDirectMessage
                    ? "Group DM · \(groupParticipants.count) people"
                    : participant?.status ?? dto.topic?.value ?? dto.purpose?.value,
                isFavorite: dto.isStarred,
                createdAt: createdAt,
                participantUserID: dto.user,
                avatarURL: participant?.avatarURL,
                participants: dto.isGroupDirectMessage
                    ? groupParticipants
                    : participant.map { [$0] } ?? [],
                unreadCount: dto.unreadCountDisplay,
                mentionCount: 0,
                latestActivity: latestActivity,
                messages: latestMessage.map { [$0] } ?? []
            )
        }
        .sorted { $0.latestActivity > $1.latestActivity }

        return SlackWorkspaceSnapshot(users: visibleUsers, conversations: conversations)
    }

    private func fetchUsers(accessToken: String) async throws -> [SlackUserDTO] {
        var members: [SlackUserDTO] = []
        var cursor: String?
        repeat {
            var query = [URLQueryItem(name: "limit", value: "200")]
            if let cursor, !cursor.isEmpty {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let response: SlackUsersResponse = try await get(
                method: "users.list",
                query: query,
                accessToken: accessToken
            )
            try validate(response)
            members.append(contentsOf: response.members)
            cursor = response.responseMetadata?.nextCursor
        } while cursor?.isEmpty == false
        return members
    }

    private func fetchConversations(accessToken: String) async throws -> [SlackConversationDTO] {
        var channels: [SlackConversationDTO] = []
        var cursor: String?
        repeat {
            var query = [
                URLQueryItem(name: "types", value: "public_channel,private_channel,im,mpim"),
                URLQueryItem(name: "exclude_archived", value: "true"),
                URLQueryItem(name: "limit", value: "200"),
            ]
            if let cursor, !cursor.isEmpty {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let response: SlackConversationsResponse = try await get(
                method: "conversations.list",
                query: query,
                accessToken: accessToken
            )
            try validate(response)
            channels.append(contentsOf: response.channels)
            cursor = response.responseMetadata?.nextCursor
        } while cursor?.isEmpty == false
        return channels
    }

    private func hydrateGroupMembers(
        in conversations: [SlackConversationDTO],
        accessToken: String
    ) async -> [SlackConversationDTO] {
        let groups = conversations.filter { $0.isGroupDirectMessage && $0.members.isEmpty }
        guard !groups.isEmpty else {
            return conversations
        }

        var hydrated = conversations
        await withTaskGroup(of: (String, [String]?).self) { group in
            for conversation in groups {
                let conversationID = conversation.id
                group.addTask {
                    let members = try? await fetchConversationMembers(
                        channelID: conversationID,
                        accessToken: accessToken
                    )
                    return (conversationID, members)
                }
            }

            for await (conversationID, members) in group {
                guard let members,
                      let index = hydrated.firstIndex(where: { $0.id == conversationID })
                else {
                    continue
                }
                hydrated[index].members = members
            }
        }
        return hydrated
    }

    private func fetchConversationMembers(
        channelID: String,
        accessToken: String
    ) async throws -> [String] {
        var members: [String] = []
        var cursor: String?
        repeat {
            var query = [
                URLQueryItem(name: "channel", value: channelID),
                URLQueryItem(name: "limit", value: "200"),
            ]
            if let cursor, !cursor.isEmpty {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let response: SlackConversationMembersResponse = try await get(
                method: "conversations.members",
                query: query,
                accessToken: accessToken
            )
            try validate(response)
            members.append(contentsOf: response.members)
            cursor = response.responseMetadata?.nextCursor
        } while cursor?.isEmpty == false
        return members
    }

    private func get<T: Decodable>(
        method: String,
        query: [URLQueryItem],
        accessToken: String
    ) async throws -> T {
        var components = URLComponents(string: "https://slack.com/api/\(method)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    private func post<T: Decodable>(
        method: String,
        body: [String: String],
        accessToken: String
    ) async throws -> T {
        var request = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if httpResponse.statusCode == 429 {
            throw APIError.rateLimited(Int(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1)
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw APIError.http(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func validate(_ response: some SlackResponse) throws {
        guard response.ok else {
            throw APIError.slack(response.error ?? "unknown_error")
        }
    }

    private static func date(fromSlackTimestamp timestamp: String?) -> Date? {
        timestamp.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }
}

protocol SlackResponse {
    var ok: Bool { get }
    var error: String? { get }
}

struct SlackResponseMetadata: Decodable {
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case nextCursor = "next_cursor"
    }
}

struct SlackBaseResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
}

struct SlackUsersResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let members: [SlackUserDTO]
    let responseMetadata: SlackResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case members
        case responseMetadata = "response_metadata"
    }
}

struct SlackUserDTO: Decodable {
    struct Profile: Decodable {
        let displayName: String
        let realName: String
        let statusText: String
        let image72: String?
        let image192: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case realName = "real_name"
            case statusText = "status_text"
            case image72 = "image_72"
            case image192 = "image_192"
        }
    }

    let id: String
    let realName: String?
    let deleted: Bool
    let isBot: Bool
    let presence: String?
    let profile: Profile

    enum CodingKeys: String, CodingKey {
        case id
        case realName = "real_name"
        case deleted
        case isBot = "is_bot"
        case presence
        case profile
    }

    var workspaceUser: WorkspaceUser {
        let displayName = profile.displayName.isEmpty
            ? (profile.realName.isEmpty ? realName ?? id : profile.realName)
            : profile.displayName
        return WorkspaceUser(
            id: id,
            displayName: displayName,
            status: profile.statusText.isEmpty ? "Slack member" : profile.statusText,
            isActive: presence == "active",
            avatarURL: [profile.image72, profile.image192]
                .compactMap { $0 }
                .first { !$0.isEmpty }
                .flatMap(URL.init(string:))
        )
    }
}

struct SlackConversationsResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let channels: [SlackConversationDTO]
    let responseMetadata: SlackResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case channels
        case responseMetadata = "response_metadata"
    }
}

struct SlackConversationInfoResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let channel: SlackConversationDTO
}

struct SlackConversationMembersResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let members: [String]
    let responseMetadata: SlackResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case members
        case responseMetadata = "response_metadata"
    }
}

struct SlackConversationDTO: Decodable {
    struct TextValue: Decodable {
        let value: String
    }

    let id: String
    let name: String?
    let user: String?
    let isIM: Bool
    let isMPIM: Bool
    var members: [String]
    let isStarred: Bool
    let unreadCountDisplay: Int
    let created: Int?
    let lastRead: String?
    let latest: SlackMessageDTO?
    let topic: TextValue?
    let purpose: TextValue?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case user
        case isIM = "is_im"
        case isMPIM = "is_mpim"
        case members
        case isStarred = "is_starred"
        case unreadCountDisplay = "unread_count_display"
        case created
        case lastRead = "last_read"
        case latest
        case topic
        case purpose
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        isIM = try container.decodeIfPresent(Bool.self, forKey: .isIM) ?? false
        isMPIM = try container.decodeIfPresent(Bool.self, forKey: .isMPIM) ?? false
        members = try container.decodeIfPresent([String].self, forKey: .members) ?? []
        isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        unreadCountDisplay = try container.decodeIfPresent(Int.self, forKey: .unreadCountDisplay) ?? 0
        created = try container.decodeIfPresent(Int.self, forKey: .created)
        lastRead = try container.decodeIfPresent(String.self, forKey: .lastRead)
        latest = try? container.decodeIfPresent(SlackMessageDTO.self, forKey: .latest)
        topic = try container.decodeIfPresent(TextValue.self, forKey: .topic)
        purpose = try container.decodeIfPresent(TextValue.self, forKey: .purpose)
    }

    var isGroupDirectMessage: Bool {
        isMPIM || name?.hasPrefix("mpdm-") == true
    }
}

struct SlackHistoryResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let messages: [SlackMessageDTO]
    let responseMetadata: SlackResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case messages
        case responseMetadata = "response_metadata"
    }
}

struct SlackMessageDTO: Decodable {
    struct ReactionDTO: Decodable {
        let name: String
        let count: Int
    }

    let timestamp: String
    let user: String?
    let username: String?
    let text: String
    let reactions: [ReactionDTO]?

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case user
        case username
        case text
        case reactions
    }

    func message(users: [String: WorkspaceUser], currentUserID: String) -> Message {
        let authorUser = user.flatMap { users[$0] }
        return Message(
            author: authorUser?.displayName ?? username ?? "Slack",
            body: text,
            timestamp: Double(timestamp).map(Date.init(timeIntervalSince1970:)) ?? .now,
            authorAvatarURL: authorUser?.avatarURL,
            remoteID: timestamp,
            isCurrentUser: user == currentUserID,
            reactions: reactions?.map { Reaction(emoji: ":\($0.name):", count: $0.count) } ?? []
        )
    }
}

struct SlackOpenConversationResponse: Decodable, SlackResponse {
    struct Channel: Decodable {
        let id: String
    }

    let ok: Bool
    let error: String?
    let channel: Channel?
}

struct SlackPostMessageResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let message: SlackMessageDTO?
}
