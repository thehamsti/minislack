import EmojiText
import SwiftUI

struct MessageRichTextView: View {
    let document: MessageRichText
    let customEmojiURLs: [String: URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                MessageRichTextBlockView(
                    block: block,
                    customEmojiURLs: customEmojiURLs
                )
            }
        }
    }
}

private struct MessageRichTextBlockView: View {
    let block: MessageRichText.Block
    let customEmojiURLs: [String: URL]

    @ViewBuilder
    var body: some View {
        switch block {
        case let .section(runs):
            RichInlineText(runs: runs, customEmojiURLs: customEmojiURLs)
        case let .list(style, indent, offset, items):
            Grid(alignment: .topLeading, horizontalSpacing: 6, verticalSpacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, runs in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(marker(for: style, index: index, offset: offset))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        RichInlineText(runs: runs, customEmojiURLs: customEmojiURLs)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(style == .ordered ? "Item \(offset + index + 1)" : "Bullet"): "
                            + runs.map(\.displayText).joined()
                    )
                }
            }
            .padding(.leading, CGFloat(indent) * 14)
        case let .quote(runs):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tertiary)
                    .frame(width: 3)
                    .accessibilityHidden(true)
                RichInlineText(runs: runs, customEmojiURLs: customEmojiURLs)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Quote: " + runs.map(\.displayText).joined())
        case let .preformatted(runs, language):
            ScrollView(.horizontal) {
                RichInlineText(runs: runs, customEmojiURLs: customEmojiURLs)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(
                "\(language.map { "\($0) " } ?? "")code: " + runs.map(\.displayText).joined()
            )
        }
    }

    private func marker(
        for style: MessageRichText.ListStyle,
        index: Int,
        offset: Int
    ) -> String {
        switch style {
        case .bullet:
            "•"
        case .ordered:
            "\(offset + index + 1)."
        }
    }
}

private struct RichInlineText: View {
    let runs: [MessageRichText.Run]
    let customEmojiURLs: [String: URL]

    var body: some View {
        let attributedString = MessageRichTextAttributedString.make(from: runs)
        let customEmoji = Set(
            SlackEmoji.shortcodeNames(in: String(attributedString.characters))
        )
        .compactMap { name in
            customEmojiURLs[name].map { RemoteEmoji(shortcode: name, url: $0) }
        }

        EmojiText(attributedString, emojis: customEmoji)
    }
}

enum MessageRichTextAttributedString {
    static func make(from runs: [MessageRichText.Run]) -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var value = AttributedString(run.displayText)
            var intent = InlinePresentationIntent()
            if run.style.isBold {
                intent.insert(.stronglyEmphasized)
            }
            if run.style.isItalic {
                intent.insert(.emphasized)
            }
            if run.style.isStruck {
                intent.insert(.strikethrough)
            }
            if run.style.isCode {
                intent.insert(.code)
            }
            if !intent.isEmpty {
                value.inlinePresentationIntent = intent
            }
            if case let .link(url, _) = run.content {
                value.link = URL(string: url)
            }
            result += value
        }
    }
}
