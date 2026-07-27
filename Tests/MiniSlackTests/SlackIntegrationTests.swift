import Foundation
import Testing
@testable import MiniSlack

struct SlackIntegrationTests {
    @Test
    func appBundleConfigurationContainsSlackClientIDAndCallback() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlist = projectRoot.appending(path: "Config/MiniSlack-Info.plist")
        let data = try Data(contentsOf: infoPlist)
        let values = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        let urlTypes = try #require(values["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = try #require(urlTypes.first?["CFBundleURLSchemes"] as? [String])

        #expect(values["SlackClientID"] as? String == "126335682064.11705943614720")
        #expect(schemes == ["minislack"])
    }

    @Test
    func authorizationURLUsesPKCEAndOnlyUserScopes() async throws {
        let service = SlackOAuthService(
            configuration: SlackConfiguration(clientID: "123.456")
        )
        let session = SlackOAuthService.Session(state: "state-value", verifier: "secretpassword")

        let url = try await service.authorizationURL(for: session)
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

        #expect(query["client_id"] == "123.456")
        #expect(query["state"] == session.state)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == "ldMBaaWcQYtSATMV_IG8mf3wp7A6EW80arYoSW80ntU")
        #expect(query["redirect_uri"] == SlackConfiguration.redirectURI)
        #expect(query["scope"] == nil)
        #expect(query["client_secret"] == nil)
        #expect(query["user_scope"]?.contains("channels:read") == true)
        #expect(query["user_scope"]?.contains("dnd:read") == true)
        #expect(query["user_scope"]?.contains("emoji:read") == true)
    }

    @Test
    func callbackRejectsMismatchedStateBeforeTokenExchange() async throws {
        let service = SlackOAuthService(
            configuration: SlackConfiguration(clientID: "123.456")
        )
        _ = try await service.beginAuthorization()
        let callback = URL(string: "minislack://oauth/slack?code=abc&state=wrong")!

        await #expect(throws: SlackOAuthService.OAuthError.invalidState) {
            try await service.handleCallback(callback)
        }
    }

    @Test
    func credentialsRefreshBeforeFiveMinuteBoundary() {
        let credentials = SlackCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            teamID: "T1",
            teamName: "Acme",
            userID: "U1"
        )

        #expect(credentials.needsRefresh(now: Date(timeIntervalSince1970: 701)))
        #expect(!credentials.needsRefresh(now: Date(timeIntervalSince1970: 699)))
    }

    @Test
    func slackResponsesMapToWorkspaceModels() throws {
        let usersJSON = """
        [
          {
            "id": "U1",
            "real_name": "Maya Chen",
            "deleted": false,
            "is_bot": false,
            "presence": "active",
              "profile": {
                "display_name": "Maya",
                "real_name": "Maya Chen",
                "status_text": "Product",
                "image_72": "https://avatars.slack-edge.com/maya-72.png",
                "image_192": "https://avatars.slack-edge.com/maya-192.png"
              }
          }
        ]
        """
        let conversationsJSON = """
        [
          {
            "id": "D1",
            "user": "U1",
            "is_im": true,
            "created": 1600000000,
            "is_starred": true,
            "unread_count_display": 2,
            "last_read": "1700000000.000000",
            "latest": {
              "ts": "1700000100.000000",
              "user": "U1",
              "text": "Hello from Slack"
            }
          },
          {
            "id": "C1",
            "name": "general",
            "is_im": false,
            "is_starred": false,
            "unread_count_display": 0,
            "topic": {"value": "Company-wide"}
          }
        ]
        """
        let users = try JSONDecoder().decode([SlackUserDTO].self, from: Data(usersJSON.utf8))
        let conversations = try JSONDecoder().decode(
            [SlackConversationDTO].self,
            from: Data(conversationsJSON.utf8)
        )

        let snapshot = SlackAPIClient.makeSnapshot(users: users, conversations: conversations)

        #expect(snapshot.users.map(\.displayName) == ["Maya"])
        #expect(snapshot.users.first?.avatarURL?.absoluteString == "https://avatars.slack-edge.com/maya-72.png")
        #expect(snapshot.conversations.count == 2)
        #expect(snapshot.conversations.first?.title == "Maya")
        #expect(snapshot.conversations.first?.participantUserID == "U1")
        #expect(snapshot.conversations.first?.avatarURL == snapshot.users.first?.avatarURL)
        #expect(snapshot.conversations.first?.createdAt == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(snapshot.conversations.first?.unreadCount == 2)
        #expect(snapshot.conversations.first?.messages.first?.body == "Hello from Slack")
        #expect(snapshot.conversations.first?.messages.first?.authorUserID == "U1")
        #expect(snapshot.conversations.first?.messages.first?.authorAvatarURL == snapshot.users.first?.avatarURL)
    }

    @Test
    func slackUsersDecodeCustomStatusAndStartWithUnknownPresence() throws {
        let json = """
        [
          {
            "id": "U1",
            "real_name": "Maya Chen",
            "deleted": false,
            "is_bot": false,
            "presence": "active",
            "profile": {
              "display_name": "Maya",
              "real_name": "Maya Chen",
              "title": "Product",
              "status_text": "Heads down",
              "status_emoji": ":dart:",
              "status_expiration": 1900000000
            }
          },
          {
            "id": "B1",
            "real_name": "Build Bot",
            "is_bot": true,
            "profile": null
          },
          {
            "id": "U2",
            "real_name": "Former Member",
            "deleted": true
          },
          {
            "id": "U3",
            "real_name": "No Status",
            "profile": {
              "display_name": null,
              "real_name": null,
              "status_text": null,
              "status_emoji": null,
              "status_expiration": null
            }
          }
        ]
        """

        let users = try JSONDecoder().decode([SlackUserDTO].self, from: Data(json.utf8))
        let maya = users[0].workspaceUser

        #expect(maya.profileTitle == "Product")
        #expect(maya.availability.presence == .unknown)
        #expect(maya.availability.customStatus?.text == "Heads down")
        #expect(maya.availability.customStatus?.emoji == ":dart:")
        #expect(
            maya.availability.customStatus?.expiresAt
                == Date(timeIntervalSince1970: 1_900_000_000)
        )
        #expect(users[1].workspaceUser.availability.presence == .notApplicable)
        #expect(users[2].workspaceUser.availability.presence == .notApplicable)
        #expect(users[3].workspaceUser.availability.presence == .unknown)
        #expect(users[3].workspaceUser.availability.customStatus == nil)
    }

    @Test
    func presenceOnlyUsesOnlineToIdentifyTheCurrentUserAsOffline() async throws {
        let token = "presence-\(UUID().uuidString)"
        let client = makeStubbedSlackClient(accessToken: token) { request in
            guard request.url?.path == "/api/users.getPresence",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)"
            else {
                throw SlackStubError.unexpectedRequest
            }
            return try slackResponse(
                for: request,
                json: #"{"ok":true,"presence":"away","online":false}"#
            )
        }
        defer { SlackStubURLProtocol.unregister(accessToken: token) }

        let currentUserPresence = try await client.fetchPresence(
            userID: "U1",
            currentUserID: "U1",
            accessToken: token
        )
        let remoteUserPresence = try await client.fetchPresence(
            userID: "U2",
            currentUserID: "U1",
            accessToken: token
        )

        #expect(currentUserPresence == .offline)
        #expect(remoteUserPresence == .away)
    }

    @Test
    func doNotDisturbUsesTeamChunksAndInfoForASingleRemainder() async throws {
        let token = "dnd-\(UUID().uuidString)"
        let client = makeStubbedSlackClient(accessToken: token) { request in
            let url = try #require(request.url)
            let components = try #require(
                URLComponents(url: url, resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }
            )
            switch components.path {
            case "/api/dnd.teamInfo":
                let users = query["users"]?.split(separator: ",").map(String.init) ?? []
                guard users.count == 50, users.first == "U0", users.last == "U49" else {
                    throw SlackStubError.unexpectedRequest
                }
                return try slackResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "users": {
                        "U0": {
                          "dnd_enabled": true,
                          "next_dnd_end_ts": 1900000000
                        }
                      }
                    }
                    """
                )
            case "/api/dnd.info":
                guard query["user"] == "U50" else {
                    throw SlackStubError.unexpectedRequest
                }
                return try slackResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "dnd_enabled": false,
                      "next_dnd_end_ts": 1,
                      "snooze_enabled": true,
                      "snooze_endtime": 1900000100
                    }
                    """
                )
            default:
                throw SlackStubError.unexpectedRequest
            }
        }
        defer { SlackStubURLProtocol.unregister(accessToken: token) }

        let statuses = try await client.fetchDoNotDisturb(
            userIDs: (0 ... 50).map { "U\($0)" },
            accessToken: token
        )

        #expect(statuses["U0"]?.isEnabled == true)
        #expect(statuses["U0"]?.endsAt == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(statuses["U50"]?.isEnabled == true)
        #expect(statuses["U50"]?.endsAt == Date(timeIntervalSince1970: 1_900_000_100))
    }

    @Test
    func conversationInfoProvidesCreationAndLatestActivitySortingDates() throws {
        let json = """
        {
          "id": "C1",
          "name": "general",
          "created": 1600000000,
          "last_read": "1690000000.000000",
          "latest": {
            "ts": "1700000100.000000",
            "user": "U1",
            "text": "Latest message"
          }
        }
        """
        let conversation = try JSONDecoder().decode(
            SlackConversationDTO.self,
            from: Data(json.utf8)
        )

        let metadata = SlackAPIClient.makeMetadata(from: conversation)

        #expect(metadata.conversationID == "C1")
        #expect(metadata.createdAt == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(metadata.latestActivity == Date(timeIntervalSince1970: 1_700_000_100))
    }

    @Test
    func historyResponseDecodesTheCursorForTheNextOlderPage() throws {
        let json = """
        {
          "ok": true,
          "messages": [],
          "response_metadata": {
            "next_cursor": "dGVhbTpDMTIz"
          }
        }
        """

        let response = try JSONDecoder().decode(
            SlackHistoryResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.responseMetadata?.nextCursor == "dGVhbTpDMTIz")
    }

    @Test
    func richTextEmojiMetadataMapsSlackShortcodesToUnicode() throws {
        let json = """
        {
          "ts": "1700000100.000000",
          "user": "U1",
          "text": "Ship it :tada:",
          "blocks": [
            {
              "type": "rich_text",
              "elements": [
                {
                  "type": "rich_text_section",
                  "elements": [
                    {"type": "text", "text": "Ship it "},
                    {"type": "emoji", "name": "tada", "unicode": "1f389"}
                  ]
                }
              ]
            }
          ]
        }
        """
        let dto = try JSONDecoder().decode(SlackMessageDTO.self, from: Data(json.utf8))

        let message = dto.message(users: [:], currentUserID: "")

        #expect(message.emojiUnicode == ["tada": "🎉"])
        #expect(message.displayBody == "Ship it 🎉")
        #expect(
            SlackEmoji.replacingUnicodeShortcodes(
                in: message.body,
                messageEmoji: message.emojiUnicode
            ) == "Ship it 🎉"
        )
    }

    @Test
    @MainActor
    func mpdmChannelsResolveMembersAndAppearWithDirectMessages() throws {
        let usersJSON = """
        [
          {
            "id": "U0",
            "real_name": "Current User",
            "deleted": false,
            "is_bot": false,
            "profile": {
              "display_name": "Current User",
              "real_name": "Current User",
              "status_text": ""
            }
          },
          {
            "id": "U1",
            "real_name": "Maya Chen",
            "deleted": false,
            "is_bot": false,
            "profile": {
              "display_name": "Maya",
              "real_name": "Maya Chen",
              "status_text": "Product",
              "image_72": "https://avatars.slack-edge.com/maya.png"
            }
          },
          {
            "id": "U2",
            "real_name": "Alex Morgan",
            "deleted": false,
            "is_bot": false,
            "profile": {
              "display_name": "Alex",
              "real_name": "Alex Morgan",
              "status_text": "Engineering",
              "image_72": "https://avatars.slack-edge.com/alex.png"
            }
          },
          {
            "id": "U3",
            "real_name": "Former Teammate",
            "deleted": true,
            "is_bot": false,
            "profile": {
              "display_name": "Former Teammate",
              "real_name": "Former Teammate",
              "status_text": ""
            }
          }
        ]
        """
        let conversationsJSON = """
        [
          {
            "id": "G1",
            "name": "mpdm-current.user--maya--alex-1",
            "is_im": false,
            "is_mpim": false,
            "members": ["U0", "U1", "U2", "U3"],
            "is_starred": false,
            "unread_count_display": 1
          }
        ]
        """
        let users = try JSONDecoder().decode([SlackUserDTO].self, from: Data(usersJSON.utf8))
        let conversations = try JSONDecoder().decode(
            [SlackConversationDTO].self,
            from: Data(conversationsJSON.utf8)
        )

        let snapshot = SlackAPIClient.makeSnapshot(
            users: users,
            conversations: conversations,
            currentUserID: "U0"
        )
        let group = try #require(snapshot.conversations.first)
        let store = AppStore(conversations: snapshot.conversations, users: snapshot.users)

        #expect(group.kind == .groupDirectMessage)
        #expect(group.title == "Maya, Alex, Former Teammate")
        #expect(group.subtitle == "Group DM · 3 people")
        #expect(group.participants.map(\.id) == ["U1", "U2", "U3"])
        #expect(store.directConversations.isEmpty)
        #expect(store.groupDirectConversations.map(\.id) == ["G1"])
        #expect(store.channelConversations.isEmpty)
        #expect(store.quickSwitcherGroupMessages.map(\.id) == ["G1"])
    }
}

private typealias SlackStubHandler =
    @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

private enum SlackStubError: Error {
    case missingHandler
    case unexpectedRequest
}

private final class SlackStubRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: SlackStubHandler] = [:]

    func register(accessToken: String, handler: @escaping SlackStubHandler) {
        lock.lock()
        handlers[accessToken] = handler
        lock.unlock()
    }

    func unregister(accessToken: String) {
        lock.lock()
        handlers[accessToken] = nil
        lock.unlock()
    }

    func handler(for request: URLRequest) -> SlackStubHandler? {
        let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let token = header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : ""
        lock.lock()
        let handler = handlers[token]
        lock.unlock()
        return handler
    }
}

private final class SlackStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = SlackStubRegistry()

    static func register(accessToken: String, handler: @escaping SlackStubHandler) {
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
            client?.urlProtocol(self, didFailWithError: SlackStubError.missingHandler)
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

private func makeStubbedSlackClient(
    accessToken: String,
    handler: @escaping SlackStubHandler
) -> SlackAPIClient {
    SlackStubURLProtocol.register(accessToken: accessToken, handler: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SlackStubURLProtocol.self]
    return SlackAPIClient(urlSession: URLSession(configuration: configuration))
}

private func slackResponse(
    for request: URLRequest,
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
