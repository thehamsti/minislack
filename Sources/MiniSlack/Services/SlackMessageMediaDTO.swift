import Foundation

struct SlackAttachmentDTO: Decodable {
    struct FieldDTO: Decodable {
        let title: String?
        let value: String?
        let isShort: Bool?

        enum CodingKeys: String, CodingKey {
            case title
            case value
            case isShort = "short"
        }
    }

    let fallback: String?
    let color: String?
    let pretext: String?
    let authorName: String?
    let authorLink: String?
    let authorIcon: String?
    let serviceName: String?
    let serviceURL: String?
    let title: String?
    let titleLink: String?
    let text: String?
    let fields: [FieldDTO]?
    let imageURL: String?
    let thumbnailURL: String?
    let footer: String?
    let footerIcon: String?
    let timestamp: Double?
    let blocks: [SlackRichTextNode]?

    enum CodingKeys: String, CodingKey {
        case fallback
        case color
        case pretext
        case authorName = "author_name"
        case authorLink = "author_link"
        case authorIcon = "author_icon"
        case serviceName = "service_name"
        case serviceURL = "service_url"
        case title
        case titleLink = "title_link"
        case text
        case fields
        case imageURL = "image_url"
        case thumbnailURL = "thumb_url"
        case footer
        case footerIcon = "footer_icon"
        case timestamp = "ts"
        case blocks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fallback = try container.decodeIfPresent(String.self, forKey: .fallback)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        pretext = try container.decodeIfPresent(String.self, forKey: .pretext)
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
        authorLink = try container.decodeIfPresent(String.self, forKey: .authorLink)
        authorIcon = try container.decodeIfPresent(String.self, forKey: .authorIcon)
        serviceName = try container.decodeIfPresent(String.self, forKey: .serviceName)
        serviceURL = try container.decodeIfPresent(String.self, forKey: .serviceURL)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        titleLink = try container.decodeIfPresent(String.self, forKey: .titleLink)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        fields = try container.decodeIfPresent([FieldDTO].self, forKey: .fields)
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL)
        thumbnailURL = try container.decodeIfPresent(String.self, forKey: .thumbnailURL)
        // Footer is almost always a string; tolerate odd payloads without failing the
        // whole attachment (which would drop title/body too).
        if let stringFooter = try? container.decodeIfPresent(String.self, forKey: .footer) {
            footer = stringFooter
        } else if let textObject = try? container.decodeIfPresent(
            SlackTextObjectDTO.self,
            forKey: .footer
        ) {
            footer = textObject.text
        } else {
            footer = nil
        }
        footerIcon = try container.decodeIfPresent(String.self, forKey: .footerIcon)
        let numericTimestamp = try? container.decode(Double.self, forKey: .timestamp)
        let stringTimestamp = try? container.decode(String.self, forKey: .timestamp)
        let intTimestamp = try? container.decode(Int.self, forKey: .timestamp)
        timestamp = numericTimestamp
            ?? stringTimestamp.flatMap(Double.init)
            ?? intTimestamp.map(Double.init)
        // Block Kit inside attachments is best-effort — never fail the attachment.
        blocks = (try? container.decodeIfPresent(
            [SlackRichTextNode].self,
            forKey: .blocks
        )) ?? nil
    }

    func attachment(
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) -> MessageAttachment? {
        let contextFooter = Self.contextFooter(from: blocks)
        let resolvedFooter = footer ?? contextFooter.text
        let resolvedFooterIcon = footerIcon ?? contextFooter.iconURL
        let resolvedTitle = Self.resolvedTitle(title)
        let resolvedTitleURL = titleLink.flatMap(URL.init(string:))
            ?? resolvedTitle.linkURL
        let attachment = MessageAttachment(
            fallback: fallback,
            color: color,
            pretext: pretext.map {
                MessageFormattedText(
                    raw: $0,
                    context: context,
                    messageEmoji: messageEmoji
                )
            },
            authorName: authorName,
            authorURL: authorLink.flatMap(URL.init(string:)),
            authorIconURL: authorIcon.flatMap(URL.init(string:)),
            serviceName: serviceName,
            serviceURL: serviceURL.flatMap(URL.init(string:)),
            title: resolvedTitle.display,
            titleURL: resolvedTitleURL,
            text: text.map {
                MessageFormattedText(
                    raw: $0,
                    context: context,
                    messageEmoji: messageEmoji
                )
            },
            fields: (fields ?? []).compactMap { field in
                field.value.map {
                    MessageAttachment.Field(
                        title: field.title,
                        value: MessageFormattedText(
                            raw: $0,
                            context: context,
                            messageEmoji: messageEmoji
                        ),
                        isShort: field.isShort == true
                    )
                }
            },
            imageSource: imageURL
                .flatMap(URL.init(string:))
                .map { MessageMediaSource(url: $0, requiresSlackAuthorization: false) },
            thumbnailSource: thumbnailURL
                .flatMap(URL.init(string:))
                .map { MessageMediaSource(url: $0, requiresSlackAuthorization: false) },
            footer: resolvedFooter.map {
                MessageFormattedText(
                    raw: $0,
                    context: context,
                    messageEmoji: messageEmoji
                )
            },
            footerIconURL: resolvedFooterIcon.flatMap(URL.init(string:)),
            timestamp: timestamp.map(Date.init(timeIntervalSince1970:))
        )
        return attachment.isEmpty ? nil : attachment
    }

    /// Pull footer text/icon from Block Kit `context` blocks when classic fields are absent.
    private static func contextFooter(
        from blocks: [SlackRichTextNode]?
    ) -> (text: String?, iconURL: String?) {
        guard let blocks else {
            return (nil, nil)
        }
        var texts: [String] = []
        var iconURL: String?
        for block in blocks where block.type == "context" {
            for element in block.elements ?? [] {
                switch element.type {
                case "image":
                    if iconURL == nil {
                        iconURL = element.imageURL
                    }
                case "mrkdwn", "plain_text":
                    if let text = element.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty
                    {
                        texts.append(text)
                    }
                default:
                    continue
                }
            }
        }
        let text = texts.isEmpty ? nil : texts.joined(separator: "  ")
        return (text, iconURL)
    }

    /// Titles often arrive as Slack mrkdwn links: `<url|label>`.
    private static func resolvedTitle(
        _ title: String?
    ) -> (display: String?, linkURL: URL?) {
        guard let title, !title.isEmpty else {
            return (nil, nil)
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"),
              trimmed.hasSuffix(">"),
              !trimmed.hasPrefix("<@"),
              !trimmed.hasPrefix("<#"),
              !trimmed.hasPrefix("<!")
        else {
            return (title, nil)
        }
        let inner = String(trimmed.dropFirst().dropLast())
        let parts = inner.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let target = parts.first.map(String.init),
              let url = URL(string: target),
              url.scheme != nil
        else {
            return (title, nil)
        }
        let label = parts.count == 2 ? String(parts[1]) : target
        return (label.isEmpty ? target : label, url)
    }
}

struct SlackFileDTO: Decodable {
    let id: String
    let name: String?
    let title: String?
    let mimeType: String?
    let prettyType: String?
    let size: Int?
    let mode: String?
    let isExternal: Bool?
    let privateURL: String?
    let privateDownloadURL: String?
    let externalURL: String?
    let permalink: String?
    let thumbnail64: String?
    let thumbnail80: String?
    let thumbnail160: String?
    let thumbnail360: String?
    let preview: String?
    let altText: String?
    let originalWidth: Int?
    let originalHeight: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case mimeType = "mimetype"
        case prettyType = "pretty_type"
        case size
        case mode
        case isExternal = "is_external"
        case privateURL = "url_private"
        case privateDownloadURL = "url_private_download"
        case externalURL = "external_url"
        case permalink
        case thumbnail64 = "thumb_64"
        case thumbnail80 = "thumb_80"
        case thumbnail160 = "thumb_160"
        case thumbnail360 = "thumb_360"
        case preview
        case altText = "alt_txt"
        case originalWidth = "original_w"
        case originalHeight = "original_h"
    }

    var file: MessageFile {
        let fallbackName = name ?? title ?? "Slack file"
        let privateContentURL = (privateDownloadURL ?? privateURL).flatMap(URL.init(string:))
        let externalContentURL = externalURL.flatMap(URL.init(string:))
        let contentSource: MessageMediaSource? = if isExternal == true,
                                                   let externalContentURL
        {
            MessageMediaSource(
                url: externalContentURL,
                requiresSlackAuthorization: false
            )
        } else {
            privateContentURL.map {
                MessageMediaSource(url: $0, requiresSlackAuthorization: true)
            } ?? externalContentURL.map {
                MessageMediaSource(url: $0, requiresSlackAuthorization: false)
            }
        }
        let thumbnailSource = (thumbnail360 ?? thumbnail160 ?? thumbnail80 ?? thumbnail64)
            .flatMap(URL.init(string:))
            .map { MessageMediaSource(url: $0, requiresSlackAuthorization: true) }

        return MessageFile(
            id: id,
            name: fallbackName,
            title: title ?? fallbackName,
            mimeType: mimeType,
            prettyType: prettyType,
            size: size,
            mode: mode,
            contentSource: contentSource,
            thumbnailSource: thumbnailSource,
            permalink: permalink.flatMap(URL.init(string:)),
            previewText: preview,
            altText: altText,
            originalWidth: originalWidth,
            originalHeight: originalHeight
        )
    }
}

struct SlackMessageIconsDTO: Decodable, Sendable {
    let image36: String?
    let image48: String?
    let image72: String?

    enum CodingKeys: String, CodingKey {
        case image36 = "image_36"
        case image48 = "image_48"
        case image72 = "image_72"
    }

    var avatarURL: URL? {
        (image72 ?? image48 ?? image36).flatMap(URL.init(string:))
    }
}

struct SlackBotProfileDTO: Decodable, Sendable {
    let id: String?
    let name: String?
    let appID: String?
    let icons: SlackMessageIconsDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case appID = "app_id"
        case icons
    }

    var hasCompleteIdentity: Bool {
        name?.isEmpty == false && icons?.avatarURL != nil
    }

    func mergingMissingFields(from fallback: SlackBotProfileDTO?) -> SlackBotProfileDTO {
        guard let fallback else {
            return self
        }
        return SlackBotProfileDTO(
            id: id ?? fallback.id,
            name: name?.isEmpty == false ? name : fallback.name,
            appID: appID ?? fallback.appID,
            icons: icons?.avatarURL == nil ? fallback.icons : icons
        )
    }
}

struct SlackTextObjectDTO: Decodable {
    let text: String?
}

struct SlackImageBlockFileDTO: Decodable {
    let id: String?
    let url: String?
}

extension SlackRichTextNode {
    var messageImage: MessageImage? {
        guard type == "image" else {
            return nil
        }
        let slackURL = slackFile?.url.flatMap(URL.init(string:))
        let externalURL = imageURL.flatMap(URL.init(string:))
        let source = slackURL.map {
            MessageMediaSource(url: $0, requiresSlackAuthorization: true)
        } ?? externalURL.map {
            MessageMediaSource(url: $0, requiresSlackAuthorization: false)
        }
        guard source != nil || slackFile?.id != nil else {
            return nil
        }
        return MessageImage(
            title: titleObject?.text,
            altText: altText ?? titleObject?.text ?? "Shared image",
            source: source,
            slackFileID: slackFile?.id
        )
    }
}
