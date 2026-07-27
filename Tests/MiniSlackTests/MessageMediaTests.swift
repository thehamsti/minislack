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
        #expect(attachment.footer?.display == "production")
        #expect(attachment.hasFooter)
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
    func decodesClassicFooterIconAndMrkdwnFooterLinks() throws {
        let json = """
        {
          "ts": "1700000200.000100",
          "subtype": "bot_message",
          "bot_id": "B123",
          "text": "",
          "attachments": [
            {
              "color": "danger",
              "title": "<https://www.ncbi.nlm.nih.gov/pubmed/123|📄 New Research Publication>",
              "title_link": "https://www.ncbi.nlm.nih.gov/pubmed/123",
              "text": "https://www.ncbi.nlm.nih.gov/pubmed/123",
              "footer": "<https://example.com/research|Research Publication>",
              "footer_icon": "https://images.example.com/research-icon.png",
              "ts": "1700000117"
            }
          ]
        }
        """
        let dto = try JSONDecoder().decode(SlackMessageDTO.self, from: Data(json.utf8))
        let message = dto.message(users: [:], currentUserID: "")
        let attachment = try #require(message.attachments.first)

        #expect(attachment.title == "📄 New Research Publication")
        #expect(
            attachment.titleURL
                == URL(string: "https://www.ncbi.nlm.nih.gov/pubmed/123")
        )
        #expect(attachment.footer?.display == "Research Publication")
        #expect(
            attachment.footerIconURL
                == URL(string: "https://images.example.com/research-icon.png")
        )
        #expect(attachment.hasFooter)
        #expect(
            attachment.timestamp == Date(timeIntervalSince1970: 1_700_000_117)
        )
    }

    @Test
    func derivesFooterFromMessageLevelContextBlocksOntoAttachment() throws {
        let json = """
        {
          "ts": "1700000200.000100",
          "subtype": "bot_message",
          "bot_id": "B123",
          "text": "",
          "attachments": [
            {
              "color": "#b71c1c",
              "title": "📄 New Research Publication",
              "title_link": "https://www.ncbi.nlm.nih.gov/pubmed/123",
              "text": "https://www.ncbi.nlm.nih.gov/pubmed/123"
            }
          ],
          "blocks": [
            {
              "type": "context",
              "elements": [
                {
                  "type": "image",
                  "image_url": "https://images.example.com/research-icon.png",
                  "alt_text": "Research"
                },
                {
                  "type": "mrkdwn",
                  "text": "Research Publication"
                }
              ]
            }
          ]
        }
        """
        let dto = try JSONDecoder().decode(SlackMessageDTO.self, from: Data(json.utf8))
        let message = dto.message(users: [:], currentUserID: "")
        let attachment = try #require(message.attachments.first)
        #expect(attachment.hasFooter)
        #expect(attachment.footer?.display == "Research Publication")
        #expect(
            attachment.footerIconURL
                == URL(string: "https://images.example.com/research-icon.png")
        )
    }

    @Test
    func preservesLinkedContextWhenMessageHasNoAttachment() throws {
        let json = """
        {
          "ts": "1700000200.000100",
          "subtype": "bot_message",
          "bot_id": "B123",
          "text": "Triaged K16-886 as a bug and opened a fix PR.",
          "blocks": [
            {
              "type": "rich_text",
              "elements": [
                {
                  "type": "rich_text_section",
                  "elements": [
                    {
                      "type": "text",
                      "text": "Triaged K16-886 as a bug and opened a fix PR."
                    }
                  ]
                }
              ]
            },
            {
              "type": "context",
              "elements": [
                {
                  "type": "mrkdwn",
                  "text": "<cursor://open/composer|Open in Cursor> · Composer 2.5 · <https://linear.app/k16/issue/K16-886|Triage Linear issues for internal-admin> · <https://github.com/k16-solutions/internal-admin/pull/123|View PR>"
                }
              ]
            }
          ]
        }
        """
        let dto = try JSONDecoder().decode(SlackMessageDTO.self, from: Data(json.utf8))
        let message = dto.message(users: [:], currentUserID: "")
        let context = try #require(message.context)

        #expect(message.attachments.isEmpty)
        #expect(
            context.plainText
                == "Open in Cursor · Composer 2.5 · "
                    + "Triage Linear issues for internal-admin · View PR"
        )
        guard case let .section(runs) = context.blocks[0] else {
            Issue.record("Expected context links in a rich text section")
            return
        }
        #expect(
            runs.contains {
                $0.content == .link(
                    url: "cursor://open/composer",
                    label: "Open in Cursor"
                )
            }
        )
        #expect(
            runs.contains {
                $0.content == .link(
                    url: "https://github.com/k16-solutions/internal-admin/pull/123",
                    label: "View PR"
                )
            }
        )

        let cached = try JSONDecoder().decode(
            Message.self,
            from: JSONEncoder().encode(message)
        )
        #expect(cached.context == context)
    }

    @Test
    func derivesFooterFromAttachmentContextBlocksWhenClassicFieldsMissing() throws {
        let json = """
        {
          "ts": "1700000200.000100",
          "subtype": "bot_message",
          "bot_id": "B123",
          "text": "",
          "attachments": [
            {
              "color": "#b71c1c",
              "title": "📄 New Research Publication",
              "title_link": "https://www.ncbi.nlm.nih.gov/pubmed/123",
              "blocks": [
                {
                  "type": "context",
                  "elements": [
                    {
                      "type": "image",
                      "image_url": "https://images.example.com/research-icon.png",
                      "alt_text": "Research"
                    },
                    {
                      "type": "mrkdwn",
                      "text": "Research Publication  |  <!date^1700000117^{date_short_pretty} {time}|Today at 12:17 PM>"
                    }
                  ]
                }
              ]
            }
          ]
        }
        """
        let dto = try JSONDecoder().decode(SlackMessageDTO.self, from: Data(json.utf8))
        let message = dto.message(users: [:], currentUserID: "")
        let attachment = try #require(message.attachments.first)

        #expect(attachment.title == "📄 New Research Publication")
        #expect(attachment.hasFooter)
        #expect(
            attachment.footerIconURL
                == URL(string: "https://images.example.com/research-icon.png")
        )
        #expect(attachment.footer?.display.contains("Research Publication") == true)
        #expect(attachment.footer?.display.contains("Today at 12:17 PM") == true)
    }

    @Test
    func legacyPlainStringFootersStillDecodeFromCache() throws {
        let json = """
        {
          "fallback": "Build 42",
          "color": "good",
          "title": "Build 42 passed",
          "fields": [],
          "footer": "<https://example.com/repo|acme/repo>",
          "footerIconURL": "https://images.example.com/icon.png",
          "timestamp": 100
        }
        """
        let attachment = try JSONDecoder().decode(
            MessageAttachment.self,
            from: Data(json.utf8)
        )
        #expect(attachment.footer?.raw == "<https://example.com/repo|acme/repo>")
        #expect(attachment.footer?.display == "acme/repo")
        #expect(
            attachment.footerIconURL
                == URL(string: "https://images.example.com/icon.png")
        )
        #expect(attachment.hasFooter)
    }

    @Test
    func parsesLinearStyleMrkdwnBoldLabelsInAttachmentText() throws {
        let json = """
        {
          "ts": "1700000200.000100",
          "subtype": "bot_message",
          "bot_id": "B123",
          "text": "John Cummings created an issue in the internal-admin dashboard project",
          "attachments": [
            {
              "color": "#5E6AD2",
              "text": "*State* Backlog *Labels* Improvement *Project* Internal-admin dashboard *Product* | <!date^1753632000^{date_short}|July 27, 2026>",
              "mrkdwn_in": ["text"]
            }
          ]
        }
        """
        let dto = try JSONDecoder().decode(SlackMessageDTO.self, from: Data(json.utf8))
        let message = dto.message(users: [:], currentUserID: "")
        let attachment = try #require(message.attachments.first)
        let text = try #require(attachment.text)

        #expect(
            text.display
                == "State Backlog Labels Improvement Project Internal-admin dashboard "
                    + "Product | July 27, 2026"
        )
        #expect(!text.display.contains("*"))

        let boldLabels = text.runs
            .filter(\.style.isBold)
            .map(\.displayText)
        #expect(boldLabels == ["State", "Labels", "Project", "Product"])

        let attributed = MessageRichTextAttributedString.make(from: text.runs)
        #expect(
            Array(attributed.runs).contains {
                String(attributed[$0.range].characters) == "State"
                    && $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            }
        )
    }

    @Test
    func parsesNestedMrkdwnEmphasisAndCodeInAttachmentFields() throws {
        let json = """
        {
          "ts": "1700000200.000100",
          "subtype": "bot_message",
          "bot_id": "B123",
          "text": "",
          "attachments": [
            {
              "color": "good",
              "fields": [
                {
                  "title": "Notes",
                  "value": "*_ship it_* with `main` and ~old plan~",
                  "short": false
                }
              ]
            }
          ]
        }
        """
        let dto = try JSONDecoder().decode(SlackMessageDTO.self, from: Data(json.utf8))
        let message = dto.message(users: [:], currentUserID: "")
        let field = try #require(message.attachments.first?.fields.first)

        #expect(field.value.display == "ship it with main and old plan")
        #expect(
            field.value.runs.contains {
                $0.displayText == "ship it" && $0.style.isBold && $0.style.isItalic
            }
        )
        #expect(
            field.value.runs.contains {
                $0.displayText == "main" && $0.style.isCode
            }
        )
        #expect(
            field.value.runs.contains {
                $0.displayText == "old plan" && $0.style.isStruck
            }
        )
    }

    @Test
    func parsesMrkdwnBoldInsideMessageContextBlocks() throws {
        let json = """
        {
          "ts": "1700000200.000100",
          "subtype": "bot_message",
          "bot_id": "B123",
          "text": "Status update",
          "blocks": [
            {
              "type": "context",
              "elements": [
                {
                  "type": "mrkdwn",
                  "text": "*State* Backlog · <https://linear.app/issue/ABC|Open issue>"
                }
              ]
            }
          ]
        }
        """
        let dto = try JSONDecoder().decode(SlackMessageDTO.self, from: Data(json.utf8))
        let message = dto.message(users: [:], currentUserID: "")
        let context = try #require(message.context)

        #expect(context.plainText == "State Backlog · Open issue")
        guard case let .section(runs) = context.blocks[0] else {
            Issue.record("Expected a context section")
            return
        }
        #expect(
            runs.contains {
                $0.displayText == "State" && $0.style.isBold
            }
        )
        #expect(
            runs.contains {
                $0.content == .link(
                    url: "https://linear.app/issue/ABC",
                    label: "Open issue"
                )
            }
        )
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

    @Test
    func decodesRealCachedGitHubAttachmentFooterShape() throws {
        // Mirrors payloads currently in the local history cache (plain-string footer).
        let json = """
        {
          "fallback": "[k16-solutions/e2-lambda] Pull request merged",
          "color": "6f42c1",
          "title": "<https://github.com/k16-solutions/e2-lambda/pull/8916|#8916 fix>",
          "fields": [],
          "footer": "<https://github.com/k16-solutions/e2-lambda|k16-solutions/e2-lambda>",
          "footerIconURL": "https://slack.github.com/static/img/favicon-neutral.png",
          "timestamp": 806432211
        }
        """
        let attachment = try JSONDecoder().decode(
            MessageAttachment.self,
            from: Data(json.utf8)
        )
        #expect(attachment.hasFooter)
        #expect(attachment.footer?.display == "k16-solutions/e2-lambda")
        #expect(attachment.footerIconURL != nil)
        #expect(attachment.timestamp != nil)
    }

    @Test
    func fullCachedMessageWithAttachmentsKeepsFooter() throws {
        let json = """
        {
          "id": "DB95638E-A2BB-4404-8B06-8286143C15C2",
          "author": "GitHub",
          "authorUserID": "U0442RWRAGZ",
          "body": "",
          "timestamp": 806433520.194659,
          "authorAvatarURL": "https://avatars.slack-edge.com/x.png",
          "remoteID": "1784740720.194659",
          "isCurrentUser": false,
          "displayBody": "",
          "integration": {
            "kind": "app",
            "botID": "B0439L5P57H",
            "appID": "A01BP7R4KNY",
            "name": "Slack app"
          },
          "attachments": [
            {
              "timestamp": 806432211,
              "fallback": "PR merged",
              "title": "title",
              "footerIconURL": "https://slack.github.com/static/img/favicon-neutral.png",
              "footer": "<https://github.com/k16-solutions/e2-lambda|k16-solutions/e2-lambda>",
              "color": "6f42c1",
              "fields": []
            }
          ],
          "files": [],
          "images": [],
          "reactions": [],
          "emojiUnicode": {},
          "isDeleted": false,
          "deliveryState": { "received": {} },
          "isPinned": false
        }
        """
        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        #expect(message.attachments.count == 1)
        #expect(message.attachments[0].hasFooter)
        #expect(message.attachments[0].footer?.display == "k16-solutions/e2-lambda")
    }
