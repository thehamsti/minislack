import Testing
@testable import MiniSlack

struct SlackRenderingRegressionTests {
    @Test
    func rendersStandardEmojiAndSkinToneModifiers() {
        let rendered = SlackEmoji.replacingUnicodeShortcodes(
            in: ":moneybag: :+1:skin-tone-3: :+1::skin-tone-3: :thumbsup::skin-tone-6:"
        )

        #expect(rendered == "💰 👍🏼 👍🏼 👍🏿")
    }

    @Test
    func preservesUnknownAndRendersAdjacentEmoji() {
        let rendered = SlackEmoji.replacingUnicodeShortcodes(
            in: ":moneybag::rocket: :+1:skin-tone-3::moneybag: :not-a-workspace-emoji:"
        )

        #expect(rendered == "💰🚀 👍🏼💰 :not-a-workspace-emoji:")
    }

    @Test
    func resolvesUserAndChannelReferences() {
        let rendered = SlackMessageFormatting.render(
            in: "<@U02465XB8CD> asked in <#C123|old-channel> and <#C404|archive>",
            userNames: ["U02465XB8CD": "Sam Yaghoubi"],
            channelNames: ["C123": "clientcredentials"]
        )

        #expect(rendered == "@Sam Yaghoubi asked in #clientcredentials and #archive")
    }

    @Test
    func preservesUnknownReferencesWithoutFallbacks() {
        let rendered = SlackMessageFormatting.render(
            in: "Ask <@U404> in <#C404>",
            userNames: [:],
            channelNames: [:]
        )

        #expect(rendered == "Ask <@U404> in <#C404>")
    }

    @Test
    func resolvesBroadcastsLinksAndSlackEntities() {
        let rendered = SlackMessageFormatting.render(
            in: "<!here> visit <https://example.com/docs?a=1&amp;b=2|the docs> or <https://example.com/plain> &lt;today&gt;",
            userNames: [:],
            channelNames: [:]
        )

        #expect(rendered == "@here visit the docs or https://example.com/plain <today>")
    }

    @Test
    func resolvesAllBroadcastReferenceTypes() {
        let rendered = SlackMessageFormatting.render(
            in: "<!channel> <!everyone>",
            userNames: [:],
            channelNames: [:]
        )

        #expect(rendered == "@channel @everyone")
    }
}
