import CoreGraphics
import Foundation
import Testing
@testable import MiniSlack

struct MessageMediaTests {
    @Test
    func slackAuthorizationRequestsFileReadAccess() {
        #expect(SlackOAuthService.userScopes.contains("files:read"))
    }

    @Test
    func decodesBotAttachmentsFilesAndImageBlocks() throws {
        let json = """
        {
          "ts": "1700000200.000100",
          "subtype": "bot_message",
          "bot_id": "B123",
          "app_id": "A123",
          "bot_profile": {
            "id": "B123",
            "app_id": "A123",
            "name": "Deploy Bot",
            "icons": {
              "image_36": "https://avatars.slack-edge.com/deploy-36.png",
              "image_72": "https://avatars.slack-edge.com/deploy-72.png"
            }
          },
          "attachments": [
            {
              "fallback": "Build 42 passed",
              "color": "good",
              "service_name": "Buildkite",
              "service_url": "https://buildkite.com",
              "title": "Build 42 passed",
              "title_link": "https://buildkite.com/acme/builds/42",
              "text": "<@U2> shipped <#C9> :rocket:",
              "fields": [
                {"title": "Duration", "value": "2m 14s", "short": true}
              ],
              "thumb_url": "https://images.example.com/build-42-thumb.png",
              "footer": "production",
              "ts": "1700000199"
            }
          ],
          "files": [
            {
              "id": "F123",
              "name": "release-notes.pdf",
              "title": "Release notes",
              "mimetype": "application/pdf",
              "pretty_type": "PDF",
              "size": 48231,
              "mode": "hosted",
              "is_external": false,
              "url_private": "https://files.slack.com/files-pri/T1-F123/release-notes.pdf",
              "url_private_download": "https://files.slack.com/files-pri/T1-F123/download/release-notes.pdf",
              "thumb_360": "https://slack-files.com/files-tmb/T1-F123/release-notes_360.png",
              "permalink": "https://acme.slack.com/files/U1/F123/release-notes.pdf"
            },
            {
              "id": "F456",
              "name": "diagram.png",
              "mimetype": "image/png",
              "is_external": true,
              "external_url": "https://cdn.example.com/diagram.png",
              "alt_txt": "Architecture diagram",
              "original_w": 1200,
              "original_h": 800
            }
          ],
          "blocks": [
            {
              "type": "image",
              "image_url": "https://images.example.com/deploy.png",
              "alt_text": "Deployment graph",
              "title": {"type": "plain_text", "text": "Production deploy"}
            },
            {
              "type": "image",
              "slack_file": {
                "id": "F789",
                "url": "https://files.slack.com/files-pri/T1-F789/chart.png"
              },
              "alt_text": "Private chart"
            }
          ]
        }
        """
        let dto = try JSONDecoder().decode(SlackMessageDTO.self, from: Data(json.utf8))
        let context = SlackMessageFormatting.Context(
            userNames: ["U2": "Maya Chen"],
            channelNames: ["C9": "shipping"]
        )

        let message = dto.message(
            users: [:],
            currentUserID: "",
            formattingContext: context
        )

        #expect(message.author == "Deploy Bot")
        #expect(message.authorUserID == nil)
        #expect(message.integration?.kind == .app)
        #expect(message.integration?.botID == "B123")
        #expect(message.integration?.appID == "A123")
        #expect(
            message.authorAvatarURL
                == URL(string: "https://avatars.slack-edge.com/deploy-72.png")
        )

        let attachment = try #require(message.attachments.first)
        #expect(attachment.serviceName == "Buildkite")
        #expect(attachment.text?.display == "@Maya Chen shipped #shipping 🚀")
        #expect(attachment.fields.first?.value.display == "2m 14s")
        #expect(attachment.thumbnailSource?.requiresSlackAuthorization == false)
        #expect(
            attachment.timestamp == Date(timeIntervalSince1970: 1_700_000_199)
        )

        let privateFile = try #require(message.files.first)
        #expect(privateFile.displayName == "Release notes")
        #expect(privateFile.contentSource?.requiresSlackAuthorization == true)
        #expect(privateFile.thumbnailSource?.requiresSlackAuthorization == true)
        #expect(privateFile.detail?.contains("PDF") == true)
        #expect(privateFile.detail?.contains("48 KB") == true)

        let externalFile = message.files[1]
        #expect(externalFile.isImage)
        #expect(externalFile.contentSource?.requiresSlackAuthorization == false)
        #expect(externalFile.altText == "Architecture diagram")
        #expect(message.images.count == 2)
        #expect(message.images[0].source?.requiresSlackAuthorization == false)
        #expect(message.images[1].source?.requiresSlackAuthorization == true)
        #expect(message.compactPreviewText == "Build 42 passed")
    }

    @Test
    func mediaMetadataSurvivesTheHistoryCacheCodableBoundary() throws {
        let message = Message(
            author: "Build Bot",
            body: "",
            timestamp: Date(timeIntervalSince1970: 100),
            integration: MessageIntegration(
                kind: .bot,
                botID: "B1",
                appID: nil,
                name: "Build Bot",
                avatarURL: nil
            ),
            files: [
                MessageFile(
                    id: "F1",
                    name: "result.txt",
                    title: "Result",
                    mimeType: "text/plain",
                    prettyType: "Plain Text",
                    size: 12,
                    mode: "hosted",
                    contentSource: MessageMediaSource(
                        url: URL(string: "https://files.slack.com/files-pri/T1-F1/result.txt")!,
                        requiresSlackAuthorization: true
                    ),
                    thumbnailSource: nil,
                    permalink: nil,
                    previewText: "passed",
                    altText: nil,
                    originalWidth: nil,
                    originalHeight: nil
                )
            ]
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == message)
        #expect(decoded.compactPreviewText == "Result")
    }

    @Test
    func messagesCachedBeforeMediaMetadataDecodeWithEmptyDefaults() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "author": "Maya",
          "body": "Hello",
          "timestamp": 100,
          "isCurrentUser": false,
          "reactions": []
        }
        """

        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))

        #expect(message.integration == nil)
        #expect(message.attachments.isEmpty)
        #expect(message.files.isEmpty)
        #expect(message.images.isEmpty)
    }

    @Test
    func privateMediaUsesHeadersWithoutLeakingTokensIntoURLs() throws {
        let source = MessageMediaSource(
            url: URL(string: "https://files.slack.com/files-pri/T1-F1/report.pdf")!,
            requiresSlackAuthorization: true
        )

        let request = try SlackFileTransferService.makeRequest(
            for: source,
            accessToken: "secret-token"
        )

        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer secret-token"
        )
        #expect(request.url?.absoluteString.contains("secret-token") == false)
    }

    @Test
    func externalMediaNeverReceivesTheSlackAuthorizationHeader() throws {
        let source = MessageMediaSource(
            url: URL(string: "https://cdn.example.com/report.pdf")!,
            requiresSlackAuthorization: false
        )

        let request = try SlackFileTransferService.makeRequest(
            for: source,
            accessToken: "secret-token"
        )

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func authenticatedMediaRejectsNonSlackHosts() {
        let source = MessageMediaSource(
            url: URL(string: "https://example.com/pretend-private-file")!,
            requiresSlackAuthorization: true
        )

        #expect(throws: SlackFileTransferService.TransferError.self) {
            try SlackFileTransferService.makeRequest(
                for: source,
                accessToken: "secret-token"
            )
        }
    }

    @Test
    func decodedImageCacheHasDeterministicMemoryBounds() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 12,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 12 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let image = context?.makeImage()

        #expect(SlackFileTransferService.imageCacheCountLimit == 96)
        #expect(
            SlackFileTransferService.imageCacheTotalCostLimit
                == 64 * 1_024 * 1_024
        )
        #expect(
            image.map(SlackFileTransferService.imageCacheCost)
                == 12 * 4 * 8
        )
    }

    @Test
    func privateImageCacheKeysAreCredentialScopedWithoutRetainingTokens() {
        let source = MessageMediaSource(
            url: URL(string: "https://files.slack.com/files-pri/T1-F1/chart.png")!,
            requiresSlackAuthorization: true
        )
        let firstToken = "Bearer xoxp-first-secret"
        let secondToken = "Bearer xoxp-second-secret"
        let firstKey = SlackFileTransferService.imageCacheKey(
            for: source,
            authorizationHeader: firstToken,
            maximumPixelSize: 720
        ) as String
        let repeatedKey = SlackFileTransferService.imageCacheKey(
            for: source,
            authorizationHeader: firstToken,
            maximumPixelSize: 720
        ) as String
        let secondKey = SlackFileTransferService.imageCacheKey(
            for: source,
            authorizationHeader: secondToken,
            maximumPixelSize: 720
        ) as String
        let smallerKey = SlackFileTransferService.imageCacheKey(
            for: source,
            authorizationHeader: firstToken,
            maximumPixelSize: 160
        ) as String

        #expect(firstKey == repeatedKey)
        #expect(firstKey != secondKey)
        #expect(firstKey != smallerKey)
        #expect(!firstKey.contains(firstToken))
        #expect(!secondKey.contains(secondToken))

        let firstFileKey = SlackFileTransferService.fileCacheKey(
            for: source,
            authorizationHeader: firstToken,
            fileID: "F1"
        )
        let secondFileKey = SlackFileTransferService.fileCacheKey(
            for: source,
            authorizationHeader: secondToken,
            fileID: "F1"
        )
        let otherWorkspaceURLKey = SlackFileTransferService.fileCacheKey(
            for: MessageMediaSource(
                url: URL(
                    string: "https://files.slack.com/files-pri/T2-F1/chart.png"
                )!,
                requiresSlackAuthorization: true
            ),
            authorizationHeader: firstToken,
            fileID: "F1"
        )
        #expect(firstFileKey != secondFileKey)
        #expect(firstFileKey != otherWorkspaceURLKey)
        #expect(!firstFileKey.contains(firstToken))
    }
}
