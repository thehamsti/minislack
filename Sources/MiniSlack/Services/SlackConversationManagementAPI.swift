import Foundation

extension SlackAPIClient {
    func renameConversation(
        channelID: String,
        name: String,
        accessToken: String
    ) async throws -> SlackConversationDTO {
        let response: SlackManagedConversationResponse = try await post(
            method: "conversations.rename",
            body: ["channel": channelID, "name": name],
            accessToken: accessToken
        )
        try validate(response)
        guard let channel = response.channel else {
            throw APIError.invalidResponse
        }
        return channel
    }

    func setConversationTopic(
        channelID: String,
        topic: String,
        accessToken: String
    ) async throws {
        let response: SlackBaseResponse = try await post(
            method: "conversations.setTopic",
            body: ["channel": channelID, "topic": topic],
            accessToken: accessToken
        )
        try validate(response)
    }

    func setConversationPurpose(
        channelID: String,
        purpose: String,
        accessToken: String
    ) async throws {
        let response: SlackBaseResponse = try await post(
            method: "conversations.setPurpose",
            body: ["channel": channelID, "purpose": purpose],
            accessToken: accessToken
        )
        try validate(response)
    }

    func setConversationArchived(
        channelID: String,
        isArchived: Bool,
        accessToken: String
    ) async throws {
        let response: SlackBaseResponse = try await post(
            method: isArchived
                ? "conversations.archive"
                : "conversations.unarchive",
            body: ["channel": channelID],
            accessToken: accessToken
        )
        try validate(response)
    }

    func inviteUsers(
        _ userIDs: [String],
        to channelID: String,
        accessToken: String
    ) async throws {
        let response: SlackBaseResponse = try await post(
            method: "conversations.invite",
            body: [
                "channel": channelID,
                "users": userIDs.joined(separator: ","),
            ],
            accessToken: accessToken
        )
        try validate(response)
    }

    func removeUser(
        _ userID: String,
        from channelID: String,
        accessToken: String
    ) async throws {
        let response: SlackBaseResponse = try await post(
            method: "conversations.kick",
            body: ["channel": channelID, "user": userID],
            accessToken: accessToken
        )
        try validate(response)
    }

    func fetchConversationMemberIDs(
        channelID: String,
        accessToken: String
    ) async throws -> [String] {
        var members: [String] = []
        var cursor: String?
        var seenCursors: Set<String> = []
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
            if let cursor, !cursor.isEmpty, !seenCursors.insert(cursor).inserted {
                throw APIError.invalidResponse
            }
        } while cursor?.isEmpty == false
        return members
    }
}

private struct SlackManagedConversationResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let channel: SlackConversationDTO?
}
