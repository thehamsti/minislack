import Foundation

enum SlackRichTextParser {
    static func parse(
        blocks: [SlackRichTextNode],
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) -> MessageRichText? {
        let roots = blocks.filter { $0.type == "rich_text" }
        guard !roots.isEmpty else {
            return nil
        }

        do {
            let parsed = try roots.flatMap { root in
                try (root.elements ?? []).map {
                    try parseBlock($0, context: context, messageEmoji: messageEmoji)
                }
            }
            let document = MessageRichText(blocks: parsed)
            return document.plainText.isEmpty ? nil : document
        } catch {
            return nil
        }
    }

    private static func parseBlock(
        _ node: SlackRichTextNode,
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) throws -> MessageRichText.Block {
        switch node.type {
        case "rich_text_section":
            return .section(
                try parseRuns(node.elements, context: context, messageEmoji: messageEmoji)
            )
        case "rich_text_list":
            guard let style = node.listStyle.flatMap(MessageRichText.ListStyle.init(rawValue:))
            else {
                throw ParseError.unsupportedNode
            }
            let items = try (node.elements ?? []).map { item in
                guard item.type == "rich_text_section" else {
                    throw ParseError.unsupportedNode
                }
                return try parseRuns(
                    item.elements,
                    context: context,
                    messageEmoji: messageEmoji
                )
            }
            return .list(
                style: style,
                indent: max(0, node.indent ?? 0),
                offset: max(0, node.offset ?? 0),
                items: items
            )
        case "rich_text_quote":
            return .quote(
                try parseRuns(node.elements, context: context, messageEmoji: messageEmoji)
            )
        case "rich_text_preformatted":
            return .preformatted(
                runs: try parseRuns(
                    node.elements,
                    context: context,
                    messageEmoji: messageEmoji
                ),
                language: node.language
            )
        default:
            throw ParseError.unsupportedNode
        }
    }

    private static func parseRuns(
        _ nodes: [SlackRichTextNode]?,
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) throws -> [MessageRichText.Run] {
        try (nodes ?? []).map { node in
            let style = MessageRichText.Style(
                isBold: node.inlineStyle?.bold == true,
                isItalic: node.inlineStyle?.italic == true,
                isStruck: node.inlineStyle?.strike == true,
                isCode: node.inlineStyle?.code == true
            )
            let content: MessageRichText.Run.Content

            switch node.type {
            case "text":
                guard let raw = node.text else {
                    throw ParseError.unsupportedNode
                }
                content = .text(
                    raw: raw,
                    display: SlackEmoji.replacingUnicodeShortcodes(
                        in: SlackMessageFormatting.render(in: raw, context: context),
                        messageEmoji: messageEmoji
                    )
                )
            case "emoji":
                guard let name = node.name else {
                    throw ParseError.unsupportedNode
                }
                let display = node.unicode.flatMap {
                    SlackEmoji.string(fromSlackUnicode: $0, skinTone: node.skinTone)
                } ?? SlackEmoji.replacingUnicodeShortcodes(
                    in: ":\(name):",
                    messageEmoji: messageEmoji
                )
                content = .emoji(name: name, display: display)
            case "link":
                guard let url = node.url else {
                    throw ParseError.unsupportedNode
                }
                content = .link(
                    url: url,
                    label: SlackMessageFormatting.render(
                        in: node.text ?? url,
                        context: context
                    )
                )
            case "user":
                guard let id = node.userID else {
                    throw ParseError.unsupportedNode
                }
                content = .user(id: id, displayName: context.userNames[id])
            case "channel":
                guard let id = node.channelID else {
                    throw ParseError.unsupportedNode
                }
                content = .channel(id: id, displayName: context.channelNames[id])
            case "broadcast":
                guard let range = node.range else {
                    throw ParseError.unsupportedNode
                }
                content = .broadcast(range: range)
            default:
                throw ParseError.unsupportedNode
            }

            return MessageRichText.Run(content: content, style: style)
        }
    }

    private enum ParseError: Error {
        case unsupportedNode
    }
}
