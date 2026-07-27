import Foundation

struct SlackWorkspaceSnapshot: Codable, Sendable {
    let users: [WorkspaceUser]
    let messageUsers: [WorkspaceUser]
    let conversations: [Conversation]
    let customEmojiURLs: [String: URL]
    let readCursorsByConversationID: [String: MessageHistoryReadCursor]
    let conversationsWithAuthoritativeUnreadCounts: Set<String>
}

struct SlackMessagePage: Sendable {
    let messages: [Message]
    let nextCursor: String?
}

struct SlackConversationReadState: Equatable, Sendable {
    let readCursor: MessageHistoryReadCursor?
    let unreadCount: Int?
}

struct SlackAPIClient: Sendable {
    enum RequestRetryPolicy: Equatable, Sendable {
        case rateLimitOnly
        case transientFailures
    }

    enum APIError: LocalizedError, Equatable {
        case http(Int)
        case rateLimited(Int)
        case slack(String)
        case decoding(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case let .http(status):
                "Slack returned HTTP \(status)."
            case let .rateLimited(seconds):
                "Slack is rate limiting requests. Try again in \(seconds) seconds."
            case let .slack(error):
                switch error {
                case "missing_scope":
                    "Reconnect this workspace so Mini Slack can request the required access (missing_scope)."
                case "not_in_channel":
                    "Join this channel in Slack, then retry."
                case "channel_not_found":
                    "This channel is not available to the connected Slack account."
                default:
                    "Slack API error: \(error)."
                }
            case let .decoding(detail):
                "Slack response decoding failed at \(detail)."
            case .invalidResponse:
                "Slack returned an invalid response."
            }
        }
    }

    let urlSession: URLSession
    let requestCoordinator: SlackRequestCoordinator

    init(
        urlSession: URLSession = .shared,
        requestCoordinator: SlackRequestCoordinator = SlackRequestCoordinator()
    ) {
        self.urlSession = urlSession
        self.requestCoordinator = requestCoordinator
    }

    func fetchWorkspace(
        accessToken: String,
        currentUserID: String
    ) async throws -> SlackWorkspaceSnapshot {
        async let users = fetchUsers(accessToken: accessToken)
        async let conversations = fetchConversations(accessToken: accessToken)
        let (userDTOs, conversationDTOs) = try await (users, conversations)
        return Self.makeSnapshot(
            users: userDTOs,
            conversations: conversationDTOs,
            currentUserID: currentUserID,
            customEmojiURLs: [:]
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

    func fetchConversationReadState(
        channelID: String,
        accessToken: String
    ) async throws -> SlackConversationReadState {
        let response: SlackConversationInfoResponse = try await get(
            method: "conversations.info",
            query: [
                URLQueryItem(name: "channel", value: channelID),
                URLQueryItem(name: "include_num_members", value: "false"),
            ],
            accessToken: accessToken
        )
        try validate(response)
        guard let channel = response.channel else {
            throw APIError.invalidResponse
        }
        return SlackConversationReadState(
            readCursor: Self.readCursor(from: channel.lastRead),
            unreadCount: channel.hasUnreadCountDisplay
                ? channel.unreadCountDisplay
                : nil
        )
    }

    func fetchMessagePage(
        channelID: String,
        cursor: String? = nil,
        oldest: String? = nil,
        latest: String? = nil,
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
        if let oldest, !oldest.isEmpty {
            query.append(URLQueryItem(name: "oldest", value: oldest))
            query.append(URLQueryItem(name: "inclusive", value: "true"))
        }
        if let latest, !latest.isEmpty {
            query.append(URLQueryItem(name: "latest", value: latest))
            if oldest == nil {
                query.append(URLQueryItem(name: "inclusive", value: "true"))
            }
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

    func sendMessage(
        channelID: String,
        text: String,
        clientMessageID: UUID? = nil,
        accessToken: String
    ) async throws -> SlackMessageDTO {
        var body = ["channel": channelID, "text": text]
        if let clientMessageID {
            body["client_msg_id"] = clientMessageID.uuidString.lowercased()
        }
        let response: SlackPostMessageResponse = try await post(
            method: "chat.postMessage",
            body: body,
            accessToken: accessToken,
            retryPolicy: clientMessageID == nil
                ? .rateLimitOnly
                : .transientFailures
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
        let userIDsByName = Dictionary(
            uniqueKeysWithValues: userDTOs.compactMap { user in
                user.name.map { ($0.lowercased(), user.id) }
            }
        )
        let formattingContext = SlackMessageFormatting.Context(
            userNames: messageUserMap.mapValues(\.displayName),
            channelNames: Dictionary(
                uniqueKeysWithValues: conversationDTOs.compactMap { dto in
                    dto.name.map { (dto.id, $0) }
                }
            )
        )

        var readCursorsByConversationID: [String: MessageHistoryReadCursor] = [:]
        var authoritativeUnreadConversationIDs = Set<String>()
        let conversations = conversationDTOs.compactMap { dto -> Conversation? in
            if !dto.isIM, !dto.isGroupDirectMessage, dto.isMember == false {
                return nil
            }
            let participant = dto.user.flatMap { userMap[$0] }
            let groupParticipants = dto.resolvedMemberIDs(userIDsByName: userIDsByName)
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
            let latestActivity = latestMessage?.timestamp ?? createdAt

            let kind: ConversationKind = if dto.isIM {
                .directMessage
            } else if dto.isGroupDirectMessage {
                .groupDirectMessage
            } else {
                .channel
            }
            if let readCursor = Self.readCursor(from: dto.lastRead) {
                readCursorsByConversationID[dto.id] = readCursor
            }
            if dto.hasUnreadCountDisplay {
                authoritativeUnreadConversationIDs.insert(dto.id)
            }

            return Conversation(
                id: dto.id,
                title: title,
                kind: kind,
                isPrivate: dto.isPrivate,
                subtitle: dto.isGroupDirectMessage
                    ? "Group DM · \(groupParticipants.count) people"
                    : participant?.status ?? dto.topic?.value ?? dto.purpose?.value,
                isFavorite: dto.isStarred,
                createdAt: createdAt,
                topic: dto.topic?.value.isEmpty == false ? dto.topic?.value : nil,
                purpose: dto.purpose?.value.isEmpty == false ? dto.purpose?.value : nil,
                isArchived: dto.isArchived,
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
            customEmojiURLs: customEmojiURLs,
            readCursorsByConversationID: readCursorsByConversationID,
            conversationsWithAuthoritativeUnreadCounts:
                authoritativeUnreadConversationIDs
        )
    }

    private static func readCursor(
        from remoteID: String?
    ) -> MessageHistoryReadCursor? {
        guard let remoteID, !remoteID.isEmpty else {
            return nil
        }
        return MessageHistoryReadCursor(
            remoteID: remoteID,
            timestamp: Double(remoteID).map {
                Date(timeIntervalSince1970: $0)
            }
        )
    }

    private func fetchUsers(accessToken: String) async throws -> [SlackUserDTO] {
        var members: [SlackUserDTO] = []
        var cursor: String?
        var seenCursors: Set<String> = []
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
            if let cursor, !cursor.isEmpty, !seenCursors.insert(cursor).inserted {
                throw APIError.invalidResponse
            }
        } while cursor?.isEmpty == false
        return members
    }

    private func fetchConversations(accessToken: String) async throws -> [SlackConversationDTO] {
        var channels: [SlackConversationDTO] = []
        var cursor: String?
        var seenCursors: Set<String> = []
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
            if let cursor, !cursor.isEmpty, !seenCursors.insert(cursor).inserted {
                throw APIError.invalidResponse
            }
        } while cursor?.isEmpty == false
        return channels
    }

    func fetchCustomEmojiURLs(accessToken: String) async throws -> [String: URL] {
        let response: SlackEmojiResponse = try await get(
            method: "emoji.list",
            query: [],
            accessToken: accessToken
        )
        try validate(response)
        return SlackEmoji.resolveCustomEmoji(response.emoji)
    }

    func get<T: Decodable>(
        method: String,
        query: [URLQueryItem],
        accessToken: String
    ) async throws -> T {
        var components = URLComponents(string: "https://slack.com/api/\(method)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await perform(
            request,
            accessToken: accessToken,
            retryPolicy: .transientFailures
        )
    }

    func post<T: Decodable>(
        method: String,
        body: [String: String],
        accessToken: String,
        retryPolicy: RequestRetryPolicy = .rateLimitOnly
    ) async throws -> T {
        var request = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
        request.timeoutInterval = 20
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(
            request,
            accessToken: accessToken,
            retryPolicy: retryPolicy
        )
    }

    func perform<T: Decodable>(
        _ request: URLRequest,
        accessToken: String,
        retryPolicy: RequestRetryPolicy
    ) async throws -> T {
        let maximumAttempts = 3
        let method = request.url?.lastPathComponent ?? "unknown"
        let credentialScope = accessToken.hashValue
        for attempt in 0 ..< maximumAttempts {
            try await requestCoordinator.waitIfNeeded(
                method: method,
                credentialScope: credentialScope
            )
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await urlSession.data(for: request)
            } catch {
                guard retryPolicy == .transientFailures,
                      attempt + 1 < maximumAttempts,
                      Self.isRetryableTransportError(error)
                else {
                    throw error
                }
                try await Task.sleep(for: Self.retryDelay(attempt: attempt))
                continue
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            if httpResponse.statusCode == 429 {
                let retryAfter = Int(
                    httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "1"
                ) ?? 1
                await requestCoordinator.pause(
                    for: max(1, retryAfter),
                    method: method,
                    credentialScope: credentialScope
                )
                if attempt + 1 < maximumAttempts {
                    continue
                }
                throw APIError.rateLimited(retryAfter)
            }
            if retryPolicy == .transientFailures,
               (500 ..< 600).contains(httpResponse.statusCode),
               attempt + 1 < maximumAttempts
            {
                try await Task.sleep(for: Self.retryDelay(attempt: attempt))
                continue
            }
            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                throw APIError.http(httpResponse.statusCode)
            }
            let decoder = JSONDecoder()
            if let envelope = try? decoder.decode(SlackBaseResponse.self, from: data),
               !envelope.ok
            {
                throw APIError.slack(envelope.error ?? "unknown_error")
            }
            do {
                return try decoder.decode(T.self, from: data)
            } catch let error as DecodingError {
                throw APIError.decoding(Self.decodingFailureDescription(error))
            }
        }
        throw APIError.invalidResponse
    }

    private static func decodingFailureDescription(_ error: DecodingError) -> String {
        let path: [CodingKey]
        let description: String
        switch error {
        case let .typeMismatch(_, context),
             let .valueNotFound(_, context),
             let .dataCorrupted(context):
            path = context.codingPath
            description = context.debugDescription
        case let .keyNotFound(key, context):
            path = context.codingPath + [key]
            description = context.debugDescription
        @unknown default:
            return "an unknown field"
        }
        let renderedPath = path.reduce("$") { partialResult, key in
            if let index = key.intValue {
                return "\(partialResult)[\(index)]"
            }
            return "\(partialResult).\(key.stringValue)"
        }
        return "\(renderedPath): \(description)"
    }

    private static func retryDelay(attempt: Int) -> Duration {
        .milliseconds(250 * (1 << attempt))
    }

    private static func isRetryableTransportError(_ error: Error) -> Bool {
        guard let error = error as? URLError else {
            return false
        }
        return switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .timedOut:
            true
        default:
            false
        }
    }

    func validate(_ response: some SlackResponse) throws {
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
    let name: String?
    let realName: String?
    let deleted: Bool
    let isBot: Bool
    let profile: Profile

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case realName = "real_name"
        case deleted
        case isBot = "is_bot"
        case profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
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

private struct SlackConversationInfoResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let channel: SlackConversationDTO?
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
    let isMember: Bool?
    let isPrivate: Bool
    let isArchived: Bool
    var members: [String]
    let isStarred: Bool
    let unreadCountDisplay: Int
    let hasUnreadCountDisplay: Bool
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
        case isMember = "is_member"
        case isPrivate = "is_private"
        case isArchived = "is_archived"
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
        isMember = try container.decodeIfPresent(Bool.self, forKey: .isMember)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        members = try container.decodeIfPresent([String].self, forKey: .members) ?? []
        isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        let unreadCount = try container.decodeIfPresent(
            Int.self,
            forKey: .unreadCountDisplay
        )
        unreadCountDisplay = unreadCount ?? 0
        hasUnreadCountDisplay = unreadCount != nil
        created = try container.decodeIfPresent(Int.self, forKey: .created)
        lastRead = try container.decodeIfPresent(String.self, forKey: .lastRead)
        latest = try? container.decodeIfPresent(SlackMessageDTO.self, forKey: .latest)
        topic = try container.decodeIfPresent(TextValue.self, forKey: .topic)
        purpose = try container.decodeIfPresent(TextValue.self, forKey: .purpose)
    }

    var isGroupDirectMessage: Bool {
        isMPIM || name?.hasPrefix("mpdm-") == true
    }

    func resolvedMemberIDs(userIDsByName: [String: String]) -> [String] {
        guard members.isEmpty, let name, name.hasPrefix("mpdm-") else {
            return members
        }
        var encodedNames = String(name.dropFirst("mpdm-".count))
        if let separator = encodedNames.lastIndex(of: "-") {
            let suffix = encodedNames[encodedNames.index(after: separator)...]
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                encodedNames.removeSubrange(separator...)
            }
        }
        return encodedNames
            .components(separatedBy: "--")
            .compactMap { userIDsByName[$0.lowercased()] }
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
        let users: [String]?
    }

    struct EditedDTO: Decodable {
        let timestamp: String?

        enum CodingKeys: String, CodingKey {
            case timestamp = "ts"
        }
    }

    let timestamp: String
    let clientMessageID: String?
    let user: String?
    let username: String?
    let text: String
    let subtype: String?
    let botID: String?
    let appID: String?
    let botProfile: SlackBotProfileDTO?
    let icons: SlackMessageIconsDTO?
    let reactions: [ReactionDTO]?
    let blocks: [SlackRichTextNode]?
    let attachments: [SlackAttachmentDTO]?
    let files: [SlackFileDTO]?
    let edited: EditedDTO?
    let deletedTimestamp: String?
    let threadTimestamp: String?
    let replyCount: Int?
    let replyUsers: [String]?
    let latestReply: String?
    let subscribed: Bool?
    let pinnedTo: [String]?

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case clientMessageID = "client_msg_id"
        case user
        case username
        case text
        case subtype
        case botID = "bot_id"
        case appID = "app_id"
        case botProfile = "bot_profile"
        case icons
        case reactions
        case blocks
        case attachments
        case files
        case edited
        case deletedTimestamp = "deleted_ts"
        case threadTimestamp = "thread_ts"
        case replyCount = "reply_count"
        case replyUsers = "reply_users"
        case latestReply = "latest_reply"
        case subscribed
        case pinnedTo = "pinned_to"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        clientMessageID = try container.decodeIfPresent(
            String.self,
            forKey: .clientMessageID
        )
        user = try container.decodeIfPresent(String.self, forKey: .user)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        botID = try container.decodeIfPresent(String.self, forKey: .botID)
        appID = try container.decodeIfPresent(String.self, forKey: .appID)
        botProfile = try container.decodeIfPresent(SlackBotProfileDTO.self, forKey: .botProfile)
        icons = try container.decodeIfPresent(SlackMessageIconsDTO.self, forKey: .icons)
        reactions = try container.decodeIfPresent([ReactionDTO].self, forKey: .reactions)
        blocks = try container.decodeIfPresent([SlackRichTextNode].self, forKey: .blocks)
        attachments = try container.decodeIfPresent(
            [SlackAttachmentDTO].self,
            forKey: .attachments
        )
        files = try container.decodeIfPresent([SlackFileDTO].self, forKey: .files)
        edited = try container.decodeIfPresent(EditedDTO.self, forKey: .edited)
        deletedTimestamp = try container.decodeIfPresent(
            String.self,
            forKey: .deletedTimestamp
        )
        threadTimestamp = try container.decodeIfPresent(
            String.self,
            forKey: .threadTimestamp
        )
        replyCount = try container.decodeIfPresent(Int.self, forKey: .replyCount)
        replyUsers = try container.decodeIfPresent([String].self, forKey: .replyUsers)
        latestReply = try container.decodeIfPresent(String.self, forKey: .latestReply)
        subscribed = try container.decodeIfPresent(Bool.self, forKey: .subscribed)
        pinnedTo = try container.decodeIfPresent([String].self, forKey: .pinnedTo)
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
        let richText = SlackRichTextParser.parse(
            blocks: blocks ?? [],
            context: context,
            messageEmoji: emojiUnicode
        )
        let resolvedIntegration = integration
        let isDeleted = subtype == "message_deleted"
            || subtype == "tombstone"
            || deletedTimestamp != nil
        let displayBody = isDeleted
            ? "This message was deleted."
            : SlackEmoji.replacingUnicodeShortcodes(
                in: formattedBody,
                messageEmoji: emojiUnicode
            )
        let threadRootTimestamp = threadTimestamp
            ?? ((replyCount ?? 0) > 0 ? timestamp : nil)
        var resolvedAttachments = (attachments ?? []).compactMap {
            $0.attachment(context: context, messageEmoji: emojiUnicode)
        }
        // Some apps put the visual "footer" in a top-level context block while the
        // colored card is a sparse attachment (title + color only).
        if let contextFooter = Self.messageContextFooter(from: blocks),
           let index = resolvedAttachments.indices.last
        {
            let existing = resolvedAttachments[index]
            if !existing.hasFooter {
                resolvedAttachments[index] = MessageAttachment(
                    fallback: existing.fallback,
                    color: existing.color,
                    pretext: existing.pretext,
                    authorName: existing.authorName,
                    authorURL: existing.authorURL,
                    authorIconURL: existing.authorIconURL,
                    serviceName: existing.serviceName,
                    serviceURL: existing.serviceURL,
                    title: existing.title,
                    titleURL: existing.titleURL,
                    text: existing.text,
                    fields: existing.fields,
                    imageSource: existing.imageSource,
                    thumbnailSource: existing.thumbnailSource,
                    footer: contextFooter.text.map {
                        MessageFormattedText(
                            raw: $0,
                            context: context,
                            messageEmoji: emojiUnicode
                        )
                    },
                    footerIconURL: contextFooter.iconURL.flatMap(URL.init(string:)),
                    timestamp: existing.timestamp
                )
            }
        }
        let messageContext = resolvedAttachments.isEmpty
            ? SlackRichTextParser.parseContext(
                blocks: blocks ?? [],
                context: context,
                messageEmoji: emojiUnicode
            )
            : nil
        return Message(
            id: clientMessageID.flatMap(UUID.init(uuidString:)) ?? UUID(),
            author: authorUser?.displayName ?? resolvedIntegration?.name ?? username ?? "Slack",
            authorUserID: user,
            body: text,
            timestamp: Double(timestamp).map(Date.init(timeIntervalSince1970:)) ?? .now,
            authorAvatarURL: authorUser?.avatarURL ?? resolvedIntegration?.avatarURL,
            remoteID: timestamp,
            isCurrentUser: user == currentUserID,
            displayBody: displayBody,
            richText: isDeleted ? nil : richText,
            context: isDeleted ? nil : messageContext,
            integration: resolvedIntegration,
            attachments: resolvedAttachments,
            files: (files ?? []).map(\.file),
            images: (blocks ?? []).compactMap(\.messageImage),
            reactions: reactions?.map {
                Reaction(
                    name: $0.name,
                    emoji: SlackEmoji.replacingUnicodeShortcodes(
                        in: ":\($0.name):",
                        messageEmoji: emojiUnicode
                    ),
                    count: $0.count,
                    userIDs: $0.users ?? [],
                    isCurrentUserIncluded: $0.users?.contains(currentUserID) == true
                )
            } ?? [],
            emojiUnicode: emojiUnicode,
            editedAt: edited?.timestamp
                .flatMap(Double.init)
                .map(Date.init(timeIntervalSince1970:)),
            isDeleted: isDeleted,
            thread: threadRootTimestamp.map {
                MessageThreadMetadata(
                    rootTimestamp: $0,
                    replyCount: replyCount ?? 0,
                    replyUserIDs: replyUsers ?? [],
                    latestReplyAt: latestReply
                        .flatMap(Double.init)
                        .map(Date.init(timeIntervalSince1970:)),
                    isFollowing: subscribed == true
                )
            },
            isPinned: pinnedTo?.isEmpty == false
        )
    }

    private var integration: MessageIntegration? {
        let resolvedAppID = appID ?? botProfile?.appID
        guard subtype == "bot_message"
                || botID != nil
                || botProfile != nil
                || resolvedAppID != nil
        else {
            return nil
        }
        let name = username ?? botProfile?.name ?? "Slack app"
        return MessageIntegration(
            kind: resolvedAppID == nil ? .bot : .app,
            botID: botID ?? botProfile?.id,
            appID: resolvedAppID,
            name: name,
            avatarURL: icons?.avatarURL ?? botProfile?.icons?.avatarURL
        )
    }

    /// Footer-like content from top-level message `context` blocks.
    private static func messageContextFooter(
        from blocks: [SlackRichTextNode]?
    ) -> (text: String?, iconURL: String?)? {
        guard let blocks else {
            return nil
        }
        var texts: [String] = []
        var iconURL: String?
        var sawContext = false
        for block in blocks where block.type == "context" {
            sawContext = true
            for element in block.elements ?? [] {
                switch element.type {
                case "image":
                    if iconURL == nil {
                        iconURL = element.imageURL
                    }
                case "mrkdwn", "plain_text":
                    if let text = element.text?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty
                    {
                        texts.append(text)
                    }
                default:
                    continue
                }
            }
        }
        guard sawContext else {
            return nil
        }
        let text = texts.isEmpty ? nil : texts.joined(separator: "  ")
        guard text != nil || iconURL != nil else {
            return nil
        }
        return (text, iconURL)
    }
}

struct SlackRichTextNode: Decodable {
    let type: String?
    let text: String?
    let name: String?
    let unicode: String?
    let skinTone: Int?
    let url: String?
    let userID: String?
    let channelID: String?
    let range: String?
    let inlineStyle: SlackRichTextStyleDTO?
    let listStyle: String?
    let indent: Int?
    let offset: Int?
    let language: String?
    let imageURL: String?
    let altText: String?
    let titleObject: SlackTextObjectDTO?
    let slackFile: SlackImageBlockFileDTO?
    let elements: [SlackRichTextNode]?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case name
        case unicode
        case skinTone = "skin_tone"
        case url
        case userID = "user_id"
        case channelID = "channel_id"
        case range
        case style
        case indent
        case offset
        case language
        case imageURL = "image_url"
        case altText = "alt_text"
        case titleObject = "title"
        case slackFile = "slack_file"
        case elements
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        if let stringText = try? container.decode(String.self, forKey: .text) {
            text = stringText
        } else {
            text = try container.decodeIfPresent(
                SlackTextObjectDTO.self,
                forKey: .text
            )?.text
        }
        name = try container.decodeIfPresent(String.self, forKey: .name)
        unicode = try container.decodeIfPresent(String.self, forKey: .unicode)
        skinTone = try container.decodeIfPresent(Int.self, forKey: .skinTone)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        userID = try container.decodeIfPresent(String.self, forKey: .userID)
        channelID = try container.decodeIfPresent(String.self, forKey: .channelID)
        range = try container.decodeIfPresent(String.self, forKey: .range)
        inlineStyle = try? container.decode(SlackRichTextStyleDTO.self, forKey: .style)
        listStyle = try? container.decode(String.self, forKey: .style)
        indent = try container.decodeIfPresent(Int.self, forKey: .indent)
        offset = try container.decodeIfPresent(Int.self, forKey: .offset)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL)
        altText = try container.decodeIfPresent(String.self, forKey: .altText)
        titleObject = try container.decodeIfPresent(SlackTextObjectDTO.self, forKey: .titleObject)
        slackFile = try container.decodeIfPresent(
            SlackImageBlockFileDTO.self,
            forKey: .slackFile
        )
        elements = try container.decodeIfPresent([SlackRichTextNode].self, forKey: .elements)
    }

    var emoji: [SlackRichTextNode] {
        let nested = (elements ?? []).flatMap(\.emoji)
        return type == "emoji" ? [self] + nested : nested
    }
}

struct SlackRichTextStyleDTO: Decodable {
    let bold: Bool?
    let italic: Bool?
    let strike: Bool?
    let code: Bool?
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
