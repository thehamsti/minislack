import Foundation
import Testing
@testable import MiniSlack

struct MessageRichTextTests {
    @Test
    func decodesProductionRichTextIntoSemanticBlocks() throws {
        let json = """
        {
          "ts": "1700000100.000000",
          "user": "U1",
          "text": "Fallback body",
          "blocks": [
            {
              "type": "rich_text",
              "elements": [
                {
                  "type": "rich_text_section",
                  "elements": [
                    {
                      "type": "text",
                      "text": "Ship ",
                      "style": {"bold": true, "italic": true}
                    },
                    {"type": "user", "user_id": "U2"},
                    {"type": "text", "text": " to "},
                    {"type": "channel", "channel_id": "C9"},
                    {
                      "type": "link",
                      "url": "https://example.com/runbook",
                      "text": " using the runbook",
                      "style": {"strike": true}
                    },
                    {
                      "type": "emoji",
                      "name": "thumbsup",
                      "unicode": "1f44d",
                      "skin_tone": 3
                    }
                  ]
                },
                {
                  "type": "rich_text_list",
                  "style": "ordered",
                  "indent": 1,
                  "offset": 2,
                  "elements": [
                    {
                      "type": "rich_text_section",
                      "elements": [
                        {"type": "text", "text": "First item", "style": {"code": true}}
                      ]
                    },
                    {
                      "type": "rich_text_section",
                      "elements": [
                        {"type": "text", "text": "Second item"}
                      ]
                    }
                  ]
                },
                {
                  "type": "rich_text_quote",
                  "elements": [
                    {"type": "text", "text": "A compact quote", "style": {"italic": true}}
                  ]
                },
                {
                  "type": "rich_text_preformatted",
                  "language": "swift",
                  "elements": [
                    {"type": "text", "text": "let value = 42\\n"},
                    {"type": "link", "url": "https://example.com", "text": "docs"}
                  ]
                }
              ]
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
        let richText = try #require(message.richText)

        #expect(richText.blocks.count == 4)
        #expect(
            richText.plainText
                == "Ship @Maya Chen to #shipping using the runbook👍🏼\n"
                    + "  3. First item\n  4. Second item\n"
                    + "A compact quote\nlet value = 42\ndocs"
        )
        #expect(message.copyText == richText.plainText)

        guard case let .section(sectionRuns) = richText.blocks[0] else {
            Issue.record("Expected a rich text section")
            return
        }
        #expect(sectionRuns[0].style.isBold)
        #expect(sectionRuns[0].style.isItalic)
        #expect(sectionRuns[4].style.isStruck)
        #expect(sectionRuns[5].displayText == "👍🏼")

        guard case let .list(style, indent, offset, items) = richText.blocks[1] else {
            Issue.record("Expected an ordered list")
            return
        }
        #expect(style == .ordered)
        #expect(indent == 1)
        #expect(offset == 2)
        #expect(items[0][0].style.isCode)

        guard case let .preformatted(_, language) = richText.blocks[3] else {
            Issue.record("Expected preformatted content")
            return
        }
        #expect(language == "swift")
    }

    @Test
    @MainActor
    func buildsStyledAndLinkedAttributedRuns() {
        let runs = [
            MessageRichText.Run(
                content: .text(raw: "Important", display: "Important"),
                style: .init(isBold: true, isItalic: true, isStruck: true)
            ),
            MessageRichText.Run(
                content: .link(url: "https://example.com", label: " docs"),
                style: .init(isCode: true)
            ),
        ]

        let attributed = MessageRichTextAttributedString.make(from: runs)
        let attributedRuns = Array(attributed.runs)

        #expect(String(attributed.characters) == "Important docs")
        #expect(
            attributedRuns.contains {
                $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                    && $0.inlinePresentationIntent?.contains(.emphasized) == true
                    && $0.inlinePresentationIntent?.contains(.strikethrough) == true
            }
        )
        #expect(
            attributedRuns.contains {
                $0.inlinePresentationIntent?.contains(.code) == true
                    && $0.link == URL(string: "https://example.com")
            }
        )
    }

    @Test
    func fallsBackToRawTextWhenRichTextContainsUnsupportedElements() throws {
        let json = """
        {
          "ts": "1700000100.000000",
          "text": "Ask <!subteam^S1|@design> for help",
          "blocks": [
            {
              "type": "rich_text",
              "elements": [
                {
                  "type": "rich_text_section",
                  "elements": [
                    {"type": "text", "text": "Ask "},
                    {"type": "usergroup", "usergroup_id": "S1"}
                  ]
                }
              ]
            }
          ]
        }
        """
        let dto = try JSONDecoder().decode(SlackMessageDTO.self, from: Data(json.utf8))

        let message = dto.message(users: [:], currentUserID: "")

        #expect(message.richText == nil)
        #expect(message.displayBody == "Ask @design for help")
        #expect(message.copyText == "Ask @design for help")
    }

    @Test
    func rendersAppMessagesBuiltFromStandardBlockKitSections() throws {
        let json = """
        {
          "ts": "1785187716.000000",
          "subtype": "bot_message",
          "bot_id": "B123",
          "username": "Amazon Q",
          "text": "",
          "blocks": [
            {
              "type": "section",
              "text": {
                "type": "mrkdwn",
                "text": ":mega: <https://example.com/event|AWS Health Event | us-east-2 | Account: 045753643074 | open>"
              }
            },
            {
              "type": "section",
              "text": {
                "type": "mrkdwn",
                "text": "Event type code: AWS_VPN_REDUNDANCY_LOSS\\n\\nYou are receiving this message because your VPN Connection had a momentary lapse of redundancy."
              }
            },
            {
              "type": "section",
              "fields": [
                {
                  "type": "mrkdwn",
                  "text": "*Affected resources (showing 1 of 1)*"
                },
                {
                  "type": "mrkdwn",
                  "text": "`vpn-0af49cea81c258ab8`"
                }
              ]
            },
            {
              "type": "context",
              "elements": [
                {
                  "type": "mrkdwn",
                  "text": "Start time: Mon, 27 Jul 2026 21:28:36 GMT"
                }
              ]
            }
          ]
        }
        """
        let dto = try JSONDecoder().decode(SlackMessageDTO.self, from: Data(json.utf8))

        let message = dto.message(users: [:], currentUserID: "")
        let richText = try #require(message.richText)

        #expect(richText.blocks.count == 4)
        #expect(
            richText.plainText
                == "📣 AWS Health Event | us-east-2 | Account: 045753643074 | open\n"
                    + "Event type code: AWS_VPN_REDUNDANCY_LOSS\n\n"
                    + "You are receiving this message because your VPN Connection "
                    + "had a momentary lapse of redundancy.\n"
                    + "Affected resources (showing 1 of 1)\n"
                    + "vpn-0af49cea81c258ab8"
        )
        #expect(
            message.context?.plainText
                == "Start time: Mon, 27 Jul 2026 21:28:36 GMT"
        )
        #expect(message.copyText == richText.plainText)
    }

    @Test
    func preservesPerElementSkinTonesWhenNamesRepeat() throws {
        let json = """
        {
          "ts": "1700000100.000000",
          "text": ":+1:skin-tone-3: :+1:skin-tone-6:",
          "blocks": [
            {
              "type": "rich_text",
              "elements": [
                {
                  "type": "rich_text_section",
                  "elements": [
                    {"type": "emoji", "name": "+1", "unicode": "1f44d", "skin_tone": 3},
                    {"type": "text", "text": " "},
                    {"type": "emoji", "name": "+1", "unicode": "1f44d", "skin_tone": 6}
                  ]
                }
              ]
            }
          ]
        }
        """
        let dto = try JSONDecoder().decode(SlackMessageDTO.self, from: Data(json.utf8))
        let message = dto.message(users: [:], currentUserID: "")

        let prepared = message.preparingForDisplay(context: .empty)

        #expect(message.richText?.plainText == "👍🏼 👍🏿")
        #expect(prepared.richText?.plainText == "👍🏼 👍🏿")
    }

    @Test
    func cachedRichTextRoundTripsAndReresolvesEntities() throws {
        let document = MessageRichText(
            blocks: [
                .section([
                    .init(
                        content: .user(id: "U2", displayName: "Old Name"),
                        style: .init(isBold: true)
                    ),
                    .init(
                        content: .text(raw: " in ", display: " in "),
                        style: .init()
                    ),
                    .init(
                        content: .channel(id: "C9", displayName: "old-channel"),
                        style: .init()
                    ),
                ])
            ]
        )
        let message = Message(
            author: "Maya",
            body: "<@U2> in <#C9>",
            timestamp: .now,
            richText: document
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        let prepared = decoded.preparingForDisplay(
            context: .init(
                userNames: ["U2": "New Name"],
                channelNames: ["C9": "new-channel"]
            )
        )

        #expect(decoded.richText == document)
        #expect(prepared.richText?.plainText == "@New Name in #new-channel")
    }
}
