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

    /// Already-rendered text (e.g. migrating plain-string footers from cache).
    init(raw: String, display: String) {
        self.raw = raw
        self.display = display
    }

    func resolving(
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) -> MessageFormattedText {
        MessageFormattedText(raw: raw, context: context, messageEmoji: messageEmoji)
    }
}

struct MessageAttachment: Hashable, Sendable {
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
    let footer: MessageFormattedText?
    let footerIconURL: URL?
    let timestamp: Date?

    init(
        fallback: String? = nil,
        color: String? = nil,
        pretext: MessageFormattedText? = nil,
        authorName: String? = nil,
        authorURL: URL? = nil,
        authorIconURL: URL? = nil,
        serviceName: String? = nil,
        serviceURL: URL? = nil,
        title: String? = nil,
        titleURL: URL? = nil,
        text: MessageFormattedText? = nil,
        fields: [Field] = [],
        imageSource: MessageMediaSource? = nil,
        thumbnailSource: MessageMediaSource? = nil,
        footer: MessageFormattedText? = nil,
        footerIconURL: URL? = nil,
        timestamp: Date? = nil
    ) {
        self.fallback = fallback
        self.color = color
        self.pretext = pretext
        self.authorName = authorName
        self.authorURL = authorURL
        self.authorIconURL = authorIconURL
        self.serviceName = serviceName
        self.serviceURL = serviceURL
        self.title = title
        self.titleURL = titleURL
        self.text = text
        self.fields = fields
        self.imageSource = imageSource
        self.thumbnailSource = thumbnailSource
        self.footer = footer
        self.footerIconURL = footerIconURL
        self.timestamp = timestamp
    }

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
            && footerIconURL == nil
            && timestamp == nil
    }

    var summary: String? {
        title
            ?? text?.display
            ?? fallback
            ?? serviceName
            ?? footer?.display
    }

    var hasFooter: Bool {
        footer != nil || footerIconURL != nil || timestamp != nil
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
            footer: footer?.resolving(context: context, messageEmoji: messageEmoji),
            footerIconURL: footerIconURL,
            timestamp: timestamp
        )
    }
}

extension MessageAttachment: Codable {
    private enum CodingKeys: String, CodingKey {
        case fallback
        case color
        case pretext
        case authorName
        case authorURL
        case authorIconURL
        case serviceName
        case serviceURL
        case title
        case titleURL
        case text
        case fields
        case imageSource
        case thumbnailSource
        case footer
        case footerIconURL
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fallback = try container.decodeIfPresent(String.self, forKey: .fallback)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        pretext = try container.decodeIfPresent(
            MessageFormattedText.self,
            forKey: .pretext
        )
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
        authorURL = try container.decodeIfPresent(URL.self, forKey: .authorURL)
        authorIconURL = try container.decodeIfPresent(URL.self, forKey: .authorIconURL)
        serviceName = try container.decodeIfPresent(String.self, forKey: .serviceName)
        serviceURL = try container.decodeIfPresent(URL.self, forKey: .serviceURL)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        titleURL = try container.decodeIfPresent(URL.self, forKey: .titleURL)
        text = try container.decodeIfPresent(MessageFormattedText.self, forKey: .text)
        fields = try container.decodeIfPresent([Field].self, forKey: .fields) ?? []
        imageSource = try container.decodeIfPresent(
            MessageMediaSource.self,
            forKey: .imageSource
        )
        thumbnailSource = try container.decodeIfPresent(
            MessageMediaSource.self,
            forKey: .thumbnailSource
        )
        // Cache used to store footer as a plain String; accept both shapes.
        if let formatted = try? container.decodeIfPresent(
            MessageFormattedText.self,
            forKey: .footer
        ) {
            footer = formatted
        } else if let plain = try container.decodeIfPresent(String.self, forKey: .footer) {
            footer = MessageFormattedText(
                raw: plain,
                display: SlackMessageFormatting.render(in: plain, context: .empty)
            )
        } else {
            footer = nil
        }
        footerIconURL = try container.decodeIfPresent(URL.self, forKey: .footerIconURL)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fallback, forKey: .fallback)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(pretext, forKey: .pretext)
        try container.encodeIfPresent(authorName, forKey: .authorName)
        try container.encodeIfPresent(authorURL, forKey: .authorURL)
        try container.encodeIfPresent(authorIconURL, forKey: .authorIconURL)
        try container.encodeIfPresent(serviceName, forKey: .serviceName)
        try container.encodeIfPresent(serviceURL, forKey: .serviceURL)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(titleURL, forKey: .titleURL)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encode(fields, forKey: .fields)
        try container.encodeIfPresent(imageSource, forKey: .imageSource)
        try container.encodeIfPresent(thumbnailSource, forKey: .thumbnailSource)
        try container.encodeIfPresent(footer, forKey: .footer)
        try container.encodeIfPresent(footerIconURL, forKey: .footerIconURL)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
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
