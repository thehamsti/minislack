import Foundation

struct SlackThreadPage: Sendable {
    let messages: [Message]
    let nextCursor: String?
}

struct SlackSearchResult: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case message
        case file
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let conversationID: String?
    let timestamp: String?
    let permalink: URL?
}

struct SlackScheduledMessage: Identifiable, Hashable, Sendable {
    let id: String
    let conversationID: String
    let text: String
    let postAt: Date
}

struct SlackUploadedFile: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

struct SlackPublicChannel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let purpose: String?
    let memberCount: Int?
    let isMember: Bool
}

extension SlackAPIClient {
    func updateMessage(
        channelID: String,
        timestamp: String,
        text: String,
        accessToken: String
    ) async throws {
        let response: SlackBaseResponse = try await post(
            method: "chat.update",
            body: ["channel": channelID, "ts": timestamp, "text": text],
            accessToken: accessToken
        )
        try validate(response)
    }

    func deleteMessage(
        channelID: String,
        timestamp: String,
        accessToken: String
    ) async throws {
        let response: SlackBaseResponse = try await post(
            method: "chat.delete",
            body: ["channel": channelID, "ts": timestamp],
            accessToken: accessToken
        )
        try validate(response)
    }

    func setReaction(
        name: String,
        channelID: String,
        timestamp: String,
        isRemoving: Bool,
        accessToken: String
    ) async throws {
        let response: SlackBaseResponse = try await post(
            method: isRemoving ? "reactions.remove" : "reactions.add",
            body: [
                "channel": channelID,
                "timestamp": timestamp,
                "name": name,
            ],
            accessToken: accessToken
        )
        try validate(response)
    }

    func permalink(
        channelID: String,
        timestamp: String,
        accessToken: String
    ) async throws -> URL {
        let response: SlackPermalinkResponse = try await get(
            method: "chat.getPermalink",
            query: [
                URLQueryItem(name: "channel", value: channelID),
                URLQueryItem(name: "message_ts", value: timestamp),
            ],
            accessToken: accessToken
        )
        try validate(response)
        guard let url = response.permalink.flatMap(URL.init(string:)) else {
            throw APIError.invalidResponse
        }
        return url
    }

    func setPinned(
        _ isPinned: Bool,
        channelID: String,
        timestamp: String,
        accessToken: String
    ) async throws {
        let response: SlackBaseResponse = try await post(
            method: isPinned ? "pins.add" : "pins.remove",
            body: ["channel": channelID, "timestamp": timestamp],
            accessToken: accessToken
        )
        try validate(response)
    }

    func addReminder(
        text: String,
        at date: Date,
        accessToken: String
    ) async throws {
        let response: SlackBaseResponse = try await post(
            method: "reminders.add",
            body: [
                "text": text,
                "time": String(Int(date.timeIntervalSince1970)),
            ],
            accessToken: accessToken
        )
        try validate(response)
    }

    func fetchThreadPage(
        channelID: String,
        threadTimestamp: String,
        cursor: String? = nil,
        limit: Int = 15,
        accessToken: String,
        users: [WorkspaceUser],
        channelNames: [String: String] = [:],
        currentUserID: String
    ) async throws -> SlackThreadPage {
        var query = [
            URLQueryItem(name: "channel", value: channelID),
            URLQueryItem(name: "ts", value: threadTimestamp),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let response: SlackRepliesResponse = try await get(
            method: "conversations.replies",
            query: query,
            accessToken: accessToken
        )
        try validate(response)
        let userMap = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
        let context = SlackMessageFormatting.Context(
            userNames: userMap.mapValues(\.displayName),
            channelNames: channelNames
        )
        let messages = response.messages.map {
            $0.message(
                users: userMap,
                currentUserID: currentUserID,
                formattingContext: context
            )
        }
        return SlackThreadPage(
            messages: messages,
            nextCursor: response.responseMetadata?.nextCursor.flatMap {
                $0.isEmpty ? nil : $0
            }
        )
    }

    func sendThreadReply(
        channelID: String,
        threadTimestamp: String,
        text: String,
        accessToken: String
    ) async throws -> SlackMessageDTO {
        let response: SlackPostMessageResponse = try await post(
            method: "chat.postMessage",
            body: [
                "channel": channelID,
                "thread_ts": threadTimestamp,
                "text": text,
            ],
            accessToken: accessToken
        )
        try validate(response)
        guard let message = response.message else {
            throw APIError.invalidResponse
        }
        return message
    }

    func createConversation(
        name: String,
        isPrivate: Bool,
        accessToken: String
    ) async throws -> SlackConversationDTO {
        let response: SlackConversationMutationResponse = try await postEncodable(
            method: "conversations.create",
            body: SlackCreateConversationRequest(
                name: name,
                isPrivate: isPrivate
            ),
            accessToken: accessToken
        )
        try validate(response)
        guard let channel = response.channel else {
            throw APIError.invalidResponse
        }
        return channel
    }

    func joinConversation(
        channelID: String,
        accessToken: String
    ) async throws -> SlackConversationDTO {
        let response: SlackConversationMutationResponse = try await post(
            method: "conversations.join",
            body: ["channel": channelID],
            accessToken: accessToken
        )
        try validate(response)
        guard let channel = response.channel else {
            throw APIError.invalidResponse
        }
        return channel
    }

    func leaveConversation(
        channelID: String,
        accessToken: String
    ) async throws {
        let response: SlackBaseResponse = try await post(
            method: "conversations.leave",
            body: ["channel": channelID],
            accessToken: accessToken
        )
        try validate(response)
    }

    func openGroupDirectMessage(
        userIDs: [String],
        accessToken: String
    ) async throws -> String {
        let response: SlackOpenConversationResponse = try await post(
            method: "conversations.open",
            body: ["users": userIDs.joined(separator: ",")],
            accessToken: accessToken
        )
        try validate(response)
        guard let channelID = response.channel?.id else {
            throw APIError.invalidResponse
        }
        return channelID
    }

    func fetchPublicChannels(
        accessToken: String
    ) async throws -> [SlackPublicChannel] {
        var channels: [SlackPublicChannel] = []
        var cursor: String?
        repeat {
            var query = [
                URLQueryItem(name: "types", value: "public_channel"),
                URLQueryItem(name: "exclude_archived", value: "true"),
                URLQueryItem(name: "limit", value: "200"),
            ]
            if let cursor, !cursor.isEmpty {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let response: SlackPublicChannelsResponse = try await get(
                method: "conversations.list",
                query: query,
                accessToken: accessToken
            )
            try validate(response)
            channels.append(contentsOf: response.channels.map(\.publicChannel))
            cursor = response.responseMetadata?.nextCursor
        } while cursor?.isEmpty == false

        return channels.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func scheduleMessage(
        channelID: String,
        text: String,
        postAt: Date,
        accessToken: String
    ) async throws -> SlackScheduledMessage {
        let response: SlackScheduleMessageResponse = try await post(
            method: "chat.scheduleMessage",
            body: [
                "channel": channelID,
                "text": text,
                "post_at": String(Int(postAt.timeIntervalSince1970)),
            ],
            accessToken: accessToken
        )
        try validate(response)
        guard let id = response.scheduledMessageID,
              let postAt = response.postAt
        else {
            throw APIError.invalidResponse
        }
        return SlackScheduledMessage(
            id: id,
            conversationID: response.channel ?? channelID,
            text: response.message?.text ?? text,
            postAt: Date(timeIntervalSince1970: TimeInterval(postAt))
        )
    }

    func fetchScheduledMessages(
        cursor: String? = nil,
        accessToken: String
    ) async throws -> ([SlackScheduledMessage], String?) {
        var body = ["limit": "100"]
        if let cursor, !cursor.isEmpty {
            body["cursor"] = cursor
        }
        let response: SlackScheduledMessagesResponse = try await post(
            method: "chat.scheduledMessages.list",
            body: body,
            accessToken: accessToken,
            retryPolicy: .transientFailures
        )
        try validate(response)
        return (
            response.scheduledMessages.map(\.scheduledMessage),
            response.responseMetadata?.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    func deleteScheduledMessage(
        id: String,
        channelID: String,
        accessToken: String
    ) async throws {
        let response: SlackBaseResponse = try await post(
            method: "chat.deleteScheduledMessage",
            body: ["channel": channelID, "scheduled_message_id": id],
            accessToken: accessToken
        )
        try validate(response)
    }

    func searchMessages(
        query: String,
        page: Int = 1,
        accessToken: String
    ) async throws -> [SlackSearchResult] {
        let response: SlackMessageSearchResponse = try await get(
            method: "search.messages",
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "count", value: "100"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "sort", value: "timestamp"),
                URLQueryItem(name: "sort_dir", value: "desc"),
            ],
            accessToken: accessToken
        )
        try validate(response)
        return response.messages.matches.map(\.searchResult)
    }

    func searchFiles(
        query: String,
        page: Int = 1,
        accessToken: String
    ) async throws -> [SlackSearchResult] {
        let response: SlackFileSearchResponse = try await get(
            method: "search.files",
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "count", value: "100"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "sort", value: "timestamp"),
                URLQueryItem(name: "sort_dir", value: "desc"),
            ],
            accessToken: accessToken
        )
        try validate(response)
        return response.files.matches.map(\.searchResult)
    }

    func setProfileStatus(
        text: String,
        emoji: String,
        expiration: Date?,
        accessToken: String
    ) async throws {
        let profile = SlackProfileStatusRequest(
            statusText: text,
            statusEmoji: emoji,
            statusExpiration: expiration.map { Int($0.timeIntervalSince1970) } ?? 0
        )
        let response: SlackBaseResponse = try await postEncodable(
            method: "users.profile.set",
            body: SlackProfileRequest(profile: profile),
            accessToken: accessToken
        )
        try validate(response)
    }

    func setManualPresence(
        _ setting: ManualPresenceSetting,
        accessToken: String
    ) async throws {
        let response: SlackBaseResponse = try await post(
            method: "users.setPresence",
            body: ["presence": setting.slackValue],
            accessToken: accessToken
        )
        try validate(response)
    }

    func snoozeDoNotDisturb(
        minutes: Int,
        accessToken: String
    ) async throws -> UserDoNotDisturb {
        let response: SlackDoNotDisturbMutationResponse = try await post(
            method: "dnd.setSnooze",
            body: ["num_minutes": String(minutes)],
            accessToken: accessToken
        )
        try validate(response)
        return response.doNotDisturb(
            fallbackEnabled: true,
            fallbackEndsAt: .now.addingTimeInterval(TimeInterval(minutes * 60))
        )
    }

    func endDoNotDisturbSnooze(
        accessToken: String
    ) async throws -> UserDoNotDisturb {
        let response: SlackDoNotDisturbMutationResponse = try await post(
            method: "dnd.endSnooze",
            body: [:],
            accessToken: accessToken
        )
        try validate(response)
        return response.doNotDisturb(
            fallbackEnabled: false,
            fallbackEndsAt: nil
        )
    }

    func uploadFile(
        data: Data,
        filename: String,
        title: String,
        channelID: String?,
        threadTimestamp: String? = nil,
        initialComment: String? = nil,
        accessToken: String
    ) async throws -> SlackUploadedFile {
        let (uploadURL, fileID) = try await externalUploadDestination(
            filename: filename,
            byteCount: Int64(data.count),
            accessToken: accessToken
        )
        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.httpBody = data
        uploadRequest.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Content-Type"
        )
        let (_, response) = try await urlSession.data(for: uploadRequest)
        try validateExternalUpload(response)
        return try await completeExternalUpload(
            fileID: fileID,
            title: title,
            channelID: channelID,
            threadTimestamp: threadTimestamp,
            initialComment: initialComment,
            accessToken: accessToken
        )
    }

    func uploadFile(
        fileURL: URL,
        filename: String,
        title: String,
        channelID: String?,
        threadTimestamp: String? = nil,
        initialComment: String? = nil,
        accessToken: String
    ) async throws -> SlackUploadedFile {
        let isAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, let byteCount = values.fileSize else {
            throw APIError.invalidResponse
        }
        let (uploadURL, fileID) = try await externalUploadDestination(
            filename: filename,
            byteCount: Int64(byteCount),
            accessToken: accessToken
        )
        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Content-Type"
        )
        let (_, response) = try await urlSession.upload(
            for: uploadRequest,
            fromFile: fileURL
        )
        try validateExternalUpload(response)
        return try await completeExternalUpload(
            fileID: fileID,
            title: title,
            channelID: channelID,
            threadTimestamp: threadTimestamp,
            initialComment: initialComment,
            accessToken: accessToken
        )
    }

    private func externalUploadDestination(
        filename: String,
        byteCount: Int64,
        accessToken: String
    ) async throws -> (url: URL, fileID: String) {
        let upload: SlackUploadURLResponse = try await post(
            method: "files.getUploadURLExternal",
            body: ["filename": filename, "length": String(byteCount)],
            accessToken: accessToken
        )
        try validate(upload)
        guard let uploadURL = upload.uploadURL.flatMap(URL.init(string:)),
              let fileID = upload.fileID
        else {
            throw APIError.invalidResponse
        }
        return (uploadURL, fileID)
    }

    private func completeExternalUpload(
        fileID: String,
        title: String,
        channelID: String?,
        threadTimestamp: String?,
        initialComment: String?,
        accessToken: String
    ) async throws -> SlackUploadedFile {
        let completed: SlackCompleteUploadResponse = try await postEncodable(
            method: "files.completeUploadExternal",
            body: SlackCompleteUploadRequest(
                files: [.init(id: fileID, title: title)],
                channelID: channelID,
                threadTimestamp: threadTimestamp,
                initialComment: initialComment
            ),
            accessToken: accessToken
        )
        try validate(completed)
        guard let file = completed.files?.first else {
            throw APIError.invalidResponse
        }
        return SlackUploadedFile(id: file.id, title: file.title ?? title)
    }

    private func validateExternalUpload(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else {
            throw APIError.invalidResponse
        }
    }

    func postEncodable<Response: Decodable, Body: Encodable>(
        method: String,
        body: Body,
        accessToken: String
    ) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
        request.timeoutInterval = 20
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(
            request,
            accessToken: accessToken,
            retryPolicy: .rateLimitOnly
        )
    }
}

private struct SlackPermalinkResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let permalink: String?
}

private struct SlackRepliesResponse: Decodable, SlackResponse {
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

private struct SlackConversationMutationResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let channel: SlackConversationDTO?
}

private struct SlackCreateConversationRequest: Encodable {
    let name: String
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case isPrivate = "is_private"
    }
}

private struct SlackPublicChannelsResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let channels: [SlackPublicChannelDTO]
    let responseMetadata: SlackResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case channels
        case responseMetadata = "response_metadata"
    }
}

private struct SlackPublicChannelDTO: Decodable {
    struct TextValue: Decodable {
        let value: String
    }

    let id: String
    let name: String
    let topic: TextValue?
    let purpose: TextValue?
    let numberOfMembers: Int?
    let isMember: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case topic
        case purpose
        case numberOfMembers = "num_members"
        case isMember = "is_member"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        topic = try container.decodeIfPresent(TextValue.self, forKey: .topic)
        purpose = try container.decodeIfPresent(TextValue.self, forKey: .purpose)
        numberOfMembers = try container.decodeIfPresent(Int.self, forKey: .numberOfMembers)
        isMember = try container.decodeIfPresent(Bool.self, forKey: .isMember) ?? false
    }

    var publicChannel: SlackPublicChannel {
        SlackPublicChannel(
            id: id,
            name: name,
            purpose: topic?.value.nilIfEmpty ?? purpose?.value.nilIfEmpty,
            memberCount: numberOfMembers,
            isMember: isMember
        )
    }
}

private struct SlackScheduleMessageResponse: Decodable, SlackResponse {
    struct MessageBody: Decodable {
        let text: String
    }

    let ok: Bool
    let error: String?
    let scheduledMessageID: String?
    let channel: String?
    let postAt: Int?
    let message: MessageBody?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case scheduledMessageID = "scheduled_message_id"
        case channel
        case postAt = "post_at"
        case message
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct SlackScheduledMessageDTO: Decodable {
    let id: String
    let channelID: String
    let text: String
    let postAt: Int

    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
        case text
        case postAt = "post_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else {
            id = String(try container.decode(Int.self, forKey: .id))
        }
        channelID = try container.decode(String.self, forKey: .channelID)
        text = try container.decode(String.self, forKey: .text)
        postAt = try container.decode(Int.self, forKey: .postAt)
    }

    var scheduledMessage: SlackScheduledMessage {
        SlackScheduledMessage(
            id: id,
            conversationID: channelID,
            text: text,
            postAt: Date(timeIntervalSince1970: TimeInterval(postAt))
        )
    }
}

private struct SlackScheduledMessagesResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let scheduledMessages: [SlackScheduledMessageDTO]
    let responseMetadata: SlackResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case scheduledMessages = "scheduled_messages"
        case responseMetadata = "response_metadata"
    }
}

private struct SlackMessageSearchResponse: Decodable, SlackResponse {
    struct Matches: Decodable {
        let matches: [SlackMessageSearchMatch]
    }

    let ok: Bool
    let error: String?
    let messages: Matches
}

private struct SlackMessageSearchMatch: Decodable {
    struct Channel: Decodable {
        let id: String
        let name: String?
    }

    let type: String?
    let channel: Channel?
    let channelID: String?
    let channelName: String?
    let timestamp: String?
    let username: String?
    let userName: String?
    let text: String
    let permalink: String?

    enum CodingKeys: String, CodingKey {
        case type
        case channel
        case channelID = "channel_id"
        case channelName = "channel_name"
        case timestamp = "ts"
        case username
        case userName = "user_name"
        case text
        case permalink
    }

    var searchResult: SlackSearchResult {
        let resolvedChannelID = channel?.id ?? channelID
        let location = (channel?.name ?? channelName).map { "#\($0)" } ?? "Message"
        return SlackSearchResult(
            id: "message-\(resolvedChannelID ?? "")-\(timestamp ?? UUID().uuidString)",
            kind: .message,
            title: "\(userName ?? username ?? "Slack") in \(location)",
            detail: text,
            conversationID: resolvedChannelID,
            timestamp: timestamp,
            permalink: permalink.flatMap(URL.init(string:))
        )
    }
}

private struct SlackFileSearchResponse: Decodable, SlackResponse {
    struct Matches: Decodable {
        let matches: [SlackFileSearchMatch]
    }

    let ok: Bool
    let error: String?
    let files: Matches
}

private struct SlackFileSearchMatch: Decodable {
    let id: String
    let name: String?
    let title: String?
    let mimetype: String?
    let permalink: String?
    let channels: [String]?
    let groups: [String]?
    let ims: [String]?

    var searchResult: SlackSearchResult {
        SlackSearchResult(
            id: "file-\(id)",
            kind: .file,
            title: title ?? name ?? "File",
            detail: mimetype ?? "File",
            conversationID: channels?.first ?? groups?.first ?? ims?.first,
            timestamp: nil,
            permalink: permalink.flatMap(URL.init(string:))
        )
    }
}

private struct SlackProfileRequest: Encodable {
    let profile: SlackProfileStatusRequest
}

private struct SlackProfileStatusRequest: Encodable {
    let statusText: String
    let statusEmoji: String
    let statusExpiration: Int

    enum CodingKeys: String, CodingKey {
        case statusText = "status_text"
        case statusEmoji = "status_emoji"
        case statusExpiration = "status_expiration"
    }
}

private struct SlackDoNotDisturbMutationResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let doNotDisturbEnabled: Bool?
    let nextEndTimestamp: Int?
    let snoozeEnabled: Bool?
    let snoozeEndTimestamp: Int?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case doNotDisturbEnabled = "dnd_enabled"
        case nextEndTimestamp = "next_dnd_end_ts"
        case snoozeEnabled = "snooze_enabled"
        case snoozeEndTimestamp = "snooze_endtime"
    }

    func doNotDisturb(
        fallbackEnabled: Bool,
        fallbackEndsAt: Date?
    ) -> UserDoNotDisturb {
        let isEnabled = (snoozeEnabled ?? false)
            || (doNotDisturbEnabled ?? false)
            || fallbackEnabled
        let endTimestamp = snoozeEnabled == true
            ? snoozeEndTimestamp ?? nextEndTimestamp
            : nextEndTimestamp ?? snoozeEndTimestamp
        return UserDoNotDisturb(
            isEnabled: isEnabled,
            endsAt: endTimestamp.flatMap {
                $0 > 1 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
            } ?? (isEnabled ? fallbackEndsAt : nil)
        )
    }
}

private struct SlackUploadURLResponse: Decodable, SlackResponse {
    let ok: Bool
    let error: String?
    let uploadURL: String?
    let fileID: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case uploadURL = "upload_url"
        case fileID = "file_id"
    }
}

private struct SlackCompleteUploadRequest: Encodable {
    struct File: Encodable {
        let id: String
        let title: String
    }

    let files: [File]
    let channelID: String?
    let threadTimestamp: String?
    let initialComment: String?

    enum CodingKeys: String, CodingKey {
        case files
        case channelID = "channel_id"
        case threadTimestamp = "thread_ts"
        case initialComment = "initial_comment"
    }
}

private struct SlackCompleteUploadResponse: Decodable, SlackResponse {
    struct File: Decodable {
        let id: String
        let title: String?
    }

    let ok: Bool
    let error: String?
    let files: [File]?
}
