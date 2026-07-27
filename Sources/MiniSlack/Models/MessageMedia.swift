import Foundation

struct MessageMediaSource: Codable, Hashable, Sendable {
    let url: URL
    let requiresSlackAuthorization: Bool
}

struct MessageFormattedText: Codable, Hashable, Sendable {
    let raw: String
    let display: String

    init(
        raw: String,
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) {
        self.raw = raw
        display = SlackEmoji.replacingUnicodeShortcodes(
            in: SlackMessageFormatting.render(in: raw, context: context),
            messageEmoji: messageEmoji
        )
    }

    func resolving(
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) -> MessageFormattedText {
        MessageFormattedText(raw: raw, context: context, messageEmoji: messageEmoji)
    }
}

struct MessageAttachment: Codable, Hashable, Sendable {
    struct Field: Codable, Hashable, Sendable {
        let title: String?
        let value: MessageFormattedText
        let isShort: Bool

        func resolving(
            context: SlackMessageFormatting.Context,
            messageEmoji: [String: String]
        ) -> Field {
            Field(
                title: title,
                value: value.resolving(context: context, messageEmoji: messageEmoji),
                isShort: isShort
            )
        }
    }

    let fallback: String?
    let color: String?
    let pretext: MessageFormattedText?
    let authorName: String?
    let authorURL: URL?
    let authorIconURL: URL?
    let serviceName: String?
    let serviceURL: URL?
    let title: String?
    let titleURL: URL?
    let text: MessageFormattedText?
    let fields: [Field]
    let imageSource: MessageMediaSource?
    let thumbnailSource: MessageMediaSource?
    let footer: String?
    let footerIconURL: URL?
    let timestamp: Date?

    var isEmpty: Bool {
        pretext == nil
            && authorName == nil
            && serviceName == nil
            && title == nil
            && text == nil
            && fields.isEmpty
            && imageSource == nil
            && thumbnailSource == nil
            && footer == nil
    }

    var summary: String? {
        title
            ?? text?.display
            ?? fallback
            ?? serviceName
    }

    func resolving(
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) -> MessageAttachment {
        MessageAttachment(
            fallback: fallback,
            color: color,
            pretext: pretext?.resolving(context: context, messageEmoji: messageEmoji),
            authorName: authorName,
            authorURL: authorURL,
            authorIconURL: authorIconURL,
            serviceName: serviceName,
            serviceURL: serviceURL,
            title: title,
            titleURL: titleURL,
            text: text?.resolving(context: context, messageEmoji: messageEmoji),
            fields: fields.map {
                $0.resolving(context: context, messageEmoji: messageEmoji)
            },
            imageSource: imageSource,
            thumbnailSource: thumbnailSource,
            footer: footer,
            footerIconURL: footerIconURL,
            timestamp: timestamp
        )
    }
}

struct MessageFile: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let title: String
    let mimeType: String?
    let prettyType: String?
    let size: Int?
    let mode: String?
    let contentSource: MessageMediaSource?
    let thumbnailSource: MessageMediaSource?
    let permalink: URL?
    let previewText: String?
    let altText: String?
    let originalWidth: Int?
    let originalHeight: Int?

    var isImage: Bool {
        mimeType?.hasPrefix("image/") == true
    }

    var displayName: String {
        title.isEmpty ? name : title
    }

    var detail: String? {
        let sizeText = size.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
        return [prettyType ?? mimeType, sizeText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            .nilIfEmpty
    }
}

struct MessageImage: Codable, Hashable, Sendable {
    let title: String?
    let altText: String
    let source: MessageMediaSource?
    let slackFileID: String?
}

struct MessageIntegration: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case app
        case bot
    }

    let kind: Kind
    let botID: String?
    let appID: String?
    let name: String
    let avatarURL: URL?

    var badgeLabel: String {
        switch kind {
        case .app:
            "APP"
        case .bot:
            "BOT"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
