import Foundation

struct MessageRichText: Codable, Hashable, Sendable {
    enum ListStyle: String, Codable, Hashable, Sendable {
        case bullet
        case ordered
    }

    enum Block: Codable, Hashable, Sendable {
        case section([Run])
        case list(style: ListStyle, indent: Int, offset: Int, items: [[Run]])
        case quote([Run])
        case preformatted(runs: [Run], language: String?)

        var plainText: String {
            switch self {
            case let .section(runs), let .quote(runs), let .preformatted(runs, _):
                return runs.map(\.displayText).joined()
            case let .list(style, indent, offset, items):
                return items.enumerated().map { index, runs in
                    let marker = switch style {
                    case .bullet:
                        "•"
                    case .ordered:
                        "\(offset + index + 1)."
                    }
                    return "\(String(repeating: "  ", count: indent))\(marker) "
                        + runs.map(\.displayText).joined()
                }
                .joined(separator: "\n")
            }
        }
    }

    struct Run: Codable, Hashable, Sendable {
        enum Content: Codable, Hashable, Sendable {
            case text(raw: String, display: String)
            case emoji(name: String, display: String)
            case link(url: String, label: String)
            case user(id: String, displayName: String?)
            case channel(id: String, displayName: String?)
            case broadcast(range: String)

            var displayText: String {
                switch self {
                case let .text(_, display), let .emoji(_, display):
                    display
                case let .link(_, label):
                    label
                case let .user(id, displayName):
                    displayName.map { "@\($0)" } ?? "<@\(id)>"
                case let .channel(id, displayName):
                    displayName.map { "#\($0)" } ?? "<#\(id)>"
                case let .broadcast(range):
                    "@\(range)"
                }
            }
        }

        let content: Content
        let style: Style

        var displayText: String {
            content.displayText
        }
    }

    struct Style: Codable, Hashable, Sendable {
        var isBold = false
        var isItalic = false
        var isStruck = false
        var isCode = false
    }

    let blocks: [Block]

    var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }

    func resolving(
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) -> MessageRichText {
        MessageRichText(
            blocks: blocks.map { block in
                switch block {
                case let .section(runs):
                    .section(resolve(runs, context: context, messageEmoji: messageEmoji))
                case let .list(style, indent, offset, items):
                    .list(
                        style: style,
                        indent: indent,
                        offset: offset,
                        items: items.map {
                            resolve($0, context: context, messageEmoji: messageEmoji)
                        }
                    )
                case let .quote(runs):
                    .quote(resolve(runs, context: context, messageEmoji: messageEmoji))
                case let .preformatted(runs, language):
                    .preformatted(
                        runs: resolve(runs, context: context, messageEmoji: messageEmoji),
                        language: language
                    )
                }
            }
        )
    }

    private func resolve(
        _ runs: [Run],
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) -> [Run] {
        runs.map { run in
            let content = switch run.content {
            case let .text(raw, _):
                Run.Content.text(
                    raw: raw,
                    display: SlackEmoji.replacingUnicodeShortcodes(
                        in: SlackMessageFormatting.render(in: raw, context: context),
                        messageEmoji: messageEmoji
                    )
                )
            case let .emoji(name, display):
                Run.Content.emoji(name: name, display: display)
            case let .link(url, label):
                Run.Content.link(
                    url: url,
                    label: SlackMessageFormatting.render(in: label, context: context)
                )
            case let .user(id, _):
                Run.Content.user(id: id, displayName: context.userNames[id])
            case let .channel(id, _):
                Run.Content.channel(id: id, displayName: context.channelNames[id])
            case let .broadcast(range):
                Run.Content.broadcast(range: range)
            }
            return Run(content: content, style: run.style)
        }
    }
}
