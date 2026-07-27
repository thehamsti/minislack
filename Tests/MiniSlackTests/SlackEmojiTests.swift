import Foundation
import Testing
@testable import MiniSlack

struct SlackEmojiTests {
    @Test
    func replacesCommonAndMessageUnicodeShortcodes() {
        let rendered = SlackEmoji.replacingUnicodeShortcodes(
            in: "Ship it :rocket: :party_parrot:",
            messageEmoji: ["party_parrot": "🦜"]
        )

        #expect(rendered == "Ship it 🚀 🦜")
    }

    @Test
    func convertsSlackCodePointsAndSkinTone() {
        #expect(
            SlackEmoji.string(fromSlackUnicode: "1f44d", skinTone: 3) == "👍🏼"
        )
        #expect(
            SlackEmoji.string(fromSlackUnicode: "2764-fe0f") == "❤️"
        )
    }

    @Test
    func resolvesCustomEmojiAliases() {
        let values = [
            "party_parrot": "https://emoji.slack-edge.com/T1/party_parrot.png",
            "parrot": "alias:party_parrot",
        ]

        let resolved = SlackEmoji.resolveCustomEmoji(values)

        #expect(resolved["party_parrot"] == resolved["parrot"])
        #expect(
            resolved["parrot"]?.absoluteString
                == "https://emoji.slack-edge.com/T1/party_parrot.png"
        )
    }
}
