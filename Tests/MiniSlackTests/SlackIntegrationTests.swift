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
        #expect(snapshot.conversations.first?.messages.first?.authorAvatarURL == snapshot.users.first?.avatarURL)
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
