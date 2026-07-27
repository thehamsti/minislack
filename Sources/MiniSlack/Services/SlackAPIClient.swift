import Foundation

struct SlackWorkspaceSnapshot: Sendable {
    let users: [WorkspaceUser]
    let messageUsers: [WorkspaceUser]
    let conversations: [Conversation]
    let customEmojiURLs: [String: URL]
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
        async let customEmoji = fetchCustomEmoji(accessToken: accessToken)
        let (userDTOs, conversationDTOs) = try await (users, conversations)
        let customEmojiURLs = (try? await customEmoji) ?? [:]
        let hydratedConversations = await hydrateGroupMembers(
            in: conversationDTOs,
            accessToken: accessToken
        )
        return Self.makeSnapshot(
            users: userDTOs,
            conversations: hydratedConversations,
            currentUserID: currentUserID,
            customEmojiURLs: customEmojiURLs
        )
    }

    func fetchWorkspaceUsers(accessToken: String) async throws -> [WorkspaceUser] {
        try await fetchUsers(accessToken: accessToken).map(\.workspaceUser)
    }

    func fetchPresence(
        userID: String,
        currentUserID: String,
        accessToken: String
    ) async throws -> UserPresence {
        let response: SlackPresenceResponse = try await get(
            method: "users.getPresence",
            query: [URLQueryItem(name: "user", value: userID)],
            accessToken: accessToken
        )
        try validate(response)
        return response.userPresence(isCurrentUser: userID == currentUserID)
    }

    func fetchDoNotDisturb(
        userIDs: [String],
        accessToken: String
    ) async throws -> [String: UserDoNotDisturb] {
        var seen = Set<String>()
        let uniqueUserIDs = userIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        var statuses: [String: UserDoNotDisturb] = [:]

        for start in stride(from: 0, to: uniqueUserIDs.count, by: 50) {
            let end = min(start + 50, uniqueUserIDs.count)
            let chunk = Array(uniqueUserIDs[start ..< end])
            if chunk.count == 1, let userID = chunk.first {
                let response: SlackDoNotDisturbInfoResponse = try await get(
                    method: "dnd.info",
                    query: [URLQueryItem(name: "user", value: userID)],
                    accessToken: accessToken
                )
                try validate(response)
                statuses[userID] = response.doNotDisturb
                continue
            }

            let response: SlackDoNotDisturbTeamResponse = try await get(
                method: "dnd.teamInfo",
                query: [URLQueryItem(name: "users", value: chunk.joined(separator: ","))],
                accessToken: accessToken
            )
            try validate(response)
            for (userID, status) in response.users {
                statuses[userID] = status.doNotDisturb
            }
        }

        return statuses
    }

    func fetchMessages(
        channelID: String,
        accessToken: String,
        users: [WorkspaceUser],
        channelNames: [String: String] = [:],
        currentUserID: String
    ) async throws -> [Message] {
        try await fetchMessagePage(
            channelID: channelID,
            accessToken: accessToken,
            users: users,
            channelNames: channelNames,
            currentUserID: currentUserID
        ).messages
    }

    func fetchMessagePage(
        channelID: String,
        cursor: String? = nil,
        limit: Int = 50,
        accessToken: String,
        users: [WorkspaceUser],
        channelNames: [String: String] = [:],
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
        let formattingContext = SlackMessageFormatting.Context(
            userNames: userMap.mapValues(\.displayName),
            channelNames: channelNames
        )
        let messages = response.messages
            .map {
                $0.message(
                    users: userMap,
                    currentUserID: currentUserID,
                    formattingContext: formattingContext
                )
            }
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
        currentUserID: String = "",
        customEmojiURLs: [String: URL] = [:]
    ) -> SlackWorkspaceSnapshot {
        let visibleUsers = userDTOs
            .filter { !$0.deleted && !$0.isBot }
            .map(\.workspaceUser)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let userMap = Dictionary(uniqueKeysWithValues: visibleUsers.map { ($0.id, $0) })
        let messageUsers = userDTOs.map(\.workspaceUser)
        let messageUserMap = Dictionary(uniqueKeysWithValues: messageUsers.map { ($0.id, $0) })
        let groupMemberMap = Dictionary(
            uniqueKeysWithValues: userDTOs
                .filter { !$0.isBot }
                .map(\.workspaceUser)
                .map { ($0.id, $0) }
        )
        let formattingContext = SlackMessageFormatting.Context(
            userNames: messageUserMap.mapValues(\.displayName),
            channelNames: Dictionary(
                uniqueKeysWithValues: conversationDTOs.compactMap { dto in
                    dto.name.map { (dto.id, $0) }
                }
            )
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
                    users: messageUserMap,
                    currentUserID: currentUserID,
                    formattingContext: formattingContext
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

        return SlackWorkspaceSnapshot(
            users: visibleUsers,
            messageUsers: messageUsers,
            conversations: conversations,
            customEmojiURLs: customEmojiURLs
        )
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

    private func fetchCustomEmoji(accessToken: String) async throws -> [String: URL] {
        let response: SlackEmojiResponse = try await get(
            method: "emoji.list",
            query: [],
            accessToken: accessToken
        )
        try validate(response)
        return SlackEmoji.resolveCustomEmoji(response.emoji)
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

struct SlackEmojiResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let emoji: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        emoji = try container.decodeIfPresent([String: String].self, forKey: .emoji) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case error
        case emoji
    }
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
        let title: String?
        let statusText: String
        let statusEmoji: String?
        let statusExpiration: Int?
        let image72: String?
        let image192: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
            realName = try container.decodeIfPresent(String.self, forKey: .realName) ?? ""
            title = try container.decodeIfPresent(String.self, forKey: .title)
            statusText = try container.decodeIfPresent(String.self, forKey: .statusText) ?? ""
            statusEmoji = try container.decodeIfPresent(String.self, forKey: .statusEmoji)
            statusExpiration = try container.decodeIfPresent(
                Int.self,
                forKey: .statusExpiration
            )
            image72 = try container.decodeIfPresent(String.self, forKey: .image72)
            image192 = try container.decodeIfPresent(String.self, forKey: .image192)
        }

        init() {
            displayName = ""
            realName = ""
            title = nil
            statusText = ""
            statusEmoji = nil
            statusExpiration = nil
            image72 = nil
            image192 = nil
        }

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case realName = "real_name"
            case title
            case statusText = "status_text"
            case statusEmoji = "status_emoji"
            case statusExpiration = "status_expiration"
            case image72 = "image_72"
            case image192 = "image_192"
        }

        var customStatus: UserCustomStatus? {
            let emoji = statusEmoji.flatMap { $0.isEmpty ? nil : $0 }
            guard !statusText.isEmpty || emoji != nil else {
                return nil
            }
            let expiresAt = statusExpiration
                .flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
            return UserCustomStatus(
                text: statusText,
                emoji: emoji,
                expiresAt: expiresAt
            )
        }
    }

    let id: String
    let realName: String?
    let deleted: Bool
    let isBot: Bool
    let profile: Profile

    enum CodingKeys: String, CodingKey {
        case id
        case realName = "real_name"
        case deleted
        case isBot = "is_bot"
        case profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        realName = try container.decodeIfPresent(String.self, forKey: .realName)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        isBot = try container.decodeIfPresent(Bool.self, forKey: .isBot) ?? false
        profile = try container.decodeIfPresent(Profile.self, forKey: .profile) ?? Profile()
    }

    var workspaceUser: WorkspaceUser {
        let displayName = profile.displayName.isEmpty
            ? (profile.realName.isEmpty ? realName ?? id : profile.realName)
            : profile.displayName
        return WorkspaceUser(
            id: id,
            displayName: displayName,
            profileTitle: profile.title.flatMap { $0.isEmpty ? nil : $0 },
            availability: UserAvailability(
                presence: deleted || isBot ? .notApplicable : .unknown,
                customStatus: profile.customStatus,
                doNotDisturb: nil,
                fetchedAt: nil
            ),
            avatarURL: [profile.image72, profile.image192]
                .compactMap { $0 }
                .first { !$0.isEmpty }
                .flatMap(URL.init(string:))
        )
    }
}

struct SlackPresenceResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let presence: String?
    let online: Bool?

    func userPresence(isCurrentUser: Bool) -> UserPresence {
        if isCurrentUser, online == false {
            return .offline
        }
        switch presence {
        case "active":
            return .active
        case "away":
            return .away
        default:
            return .unknown
        }
    }
}

struct SlackDoNotDisturbStatus: Decodable {
    let isEnabled: Bool
    let nextEndTimestamp: Int?
    let isSnoozed: Bool
    let snoozeEndTimestamp: Int?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "dnd_enabled"
        case nextEndTimestamp = "next_dnd_end_ts"
        case isSnoozed = "snooze_enabled"
        case snoozeEndTimestamp = "snooze_endtime"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        nextEndTimestamp = try container.decodeIfPresent(Int.self, forKey: .nextEndTimestamp)
        isSnoozed = try container.decodeIfPresent(Bool.self, forKey: .isSnoozed) ?? false
        snoozeEndTimestamp = try container.decodeIfPresent(
            Int.self,
            forKey: .snoozeEndTimestamp
        )
    }

    var doNotDisturb: UserDoNotDisturb {
        let active = isEnabled || isSnoozed
        let endTimestamp = isSnoozed
            ? snoozeEndTimestamp ?? nextEndTimestamp
            : nextEndTimestamp
        return UserDoNotDisturb(
            isEnabled: active,
            endsAt: active
                ? endTimestamp.flatMap {
                    $0 > 1 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
                }
                : nil
        )
    }
}

struct SlackDoNotDisturbTeamResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let users: [String: SlackDoNotDisturbStatus]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        users = try container.decodeIfPresent(
            [String: SlackDoNotDisturbStatus].self,
            forKey: .users
        ) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case error
        case users
    }
}

struct SlackDoNotDisturbInfoResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let status: SlackDoNotDisturbStatus

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        status = try SlackDoNotDisturbStatus(from: decoder)
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case error
    }

    var doNotDisturb: UserDoNotDisturb {
        status.doNotDisturb
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
    let blocks: [SlackRichTextNode]?

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case user
        case username
        case text
        case reactions
        case blocks
    }

    func message(
        users: [String: WorkspaceUser],
        currentUserID: String,
        formattingContext: SlackMessageFormatting.Context? = nil
    ) -> Message {
        let authorUser = user.flatMap { users[$0] }
        var emojiUnicode: [String: String] = [:]
        for emoji in (blocks ?? []).flatMap(\.emoji) {
            guard let name = emoji.name,
                  let unicode = emoji.unicode,
                  let value = SlackEmoji.string(
                      fromSlackUnicode: unicode,
                      skinTone: emoji.skinTone
                  )
            else {
                continue
            }
            emojiUnicode[name] = value
        }
        let context = formattingContext ?? SlackMessageFormatting.Context(
            userNames: users.mapValues(\.displayName),
            channelNames: [:]
        )
        let formattedBody = SlackMessageFormatting.render(in: text, context: context)
        return Message(
            author: authorUser?.displayName ?? username ?? "Slack",
            authorUserID: user,
            body: text,
            timestamp: Double(timestamp).map(Date.init(timeIntervalSince1970:)) ?? .now,
            authorAvatarURL: authorUser?.avatarURL,
            remoteID: timestamp,
            isCurrentUser: user == currentUserID,
            displayBody: SlackEmoji.replacingUnicodeShortcodes(
                in: formattedBody,
                messageEmoji: emojiUnicode
            ),
            reactions: reactions?.map {
                Reaction(
                    emoji: SlackEmoji.replacingUnicodeShortcodes(
                        in: ":\($0.name):",
                        messageEmoji: emojiUnicode
                    ),
                    count: $0.count
                )
            } ?? [],
            emojiUnicode: emojiUnicode
        )
    }
}

struct SlackRichTextNode: Decodable {
    let type: String?
    let name: String?
    let unicode: String?
    let skinTone: Int?
    let elements: [SlackRichTextNode]?

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case unicode
        case skinTone = "skin_tone"
        case elements
    }

    var emoji: [SlackRichTextNode] {
        let nested = (elements ?? []).flatMap(\.emoji)
        return type == "emoji" ? [self] + nested : nested
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
