import EmojiText
import QuickLook
import SwiftUI

struct MessageIntegrationBadge: View {
    let integration: MessageIntegration

    var body: some View {
        Text(integration.badgeLabel)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            .accessibilityLabel(
                integration.kind == .app ? "Slack app" : "Slack bot"
            )
    }
}

struct MessageMediaView: View {
    let message: Message
    let customEmojiURLs: [String: URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                MessageAttachmentCard(
                    attachment: attachment,
                    customEmojiURLs: customEmojiURLs
                )
            }
            ForEach(message.files) { file in
                MessageFileCard(file: file)
            }
            ForEach(Array(message.images.enumerated()), id: \.offset) { _, image in
                MessageImageCard(image: image)
            }
        }
    }
}

private struct MessageAttachmentCard: View {
    let attachment: MessageAttachment
    let customEmojiURLs: [String: URL]

    /// Prefer the unfurl target, then author/service URLs when present.
    private var primaryDestination: URL? {
        attachment.titleURL
            ?? attachment.authorURL
            ?? attachment.serviceURL
    }

    var body: some View {
        Group {
            if let destination = primaryDestination {
                Link(destination: destination) {
                    cardContent
                }
                .buttonStyle(.plain)
                .help(destination.absoluteString)
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(accentColor)
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                if let pretext = attachment.pretext {
                    MediaEmojiText(
                        text: pretext.display,
                        customEmojiURLs: customEmojiURLs
                    )
                    .foregroundStyle(.secondary)
                }

                if attachment.authorName != nil || attachment.serviceName != nil {
                    HStack(spacing: 5) {
                        if let iconURL = attachment.authorIconURL
                            ?? attachment.footerIconURL
                        {
                            AsyncImage(url: iconURL) { phase in
                                if case let .success(image) = phase {
                                    image.resizable().scaledToFill()
                                } else {
                                    Image(systemName: "app.dashed")
                                }
                            }
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        linkedText(
                            attachment.authorName ?? attachment.serviceName ?? "",
                            destination: attachment.authorURL ?? attachment.serviceURL
                        )
                        .font(.caption.weight(.semibold))
                    }
                }

                if let title = attachment.title {
                    linkedText(title, destination: attachment.titleURL)
                        .font(.callout.weight(.semibold))
                }

                if let text = attachment.text {
                    MediaEmojiText(
                        text: text.display,
                        customEmojiURLs: customEmojiURLs
                    )
                    .font(.callout)
                }

                ForEach(Array(attachment.fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 1) {
                        if let title = field.title {
                            Text(title)
                                .font(.caption.weight(.semibold))
                        }
                        MediaEmojiText(
                            text: field.value.display,
                            customEmojiURLs: customEmojiURLs
                        )
                        .font(.caption)
                    }
                }

                if let source = attachment.thumbnailSource ?? attachment.imageSource {
                    MessageRemoteImage(
                        source: source,
                        accessibilityLabel: attachment.title
                            ?? attachment.fallback
                            ?? "Attachment image",
                        compact: attachment.thumbnailSource != nil
                    )
                }

                if let footer = attachment.footer {
                    HStack(spacing: 4) {
                        Text(footer)
                        if let timestamp = attachment.timestamp {
                            Text("·")
                            Text(timestamp, style: .relative)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    private var accentColor: Color {
        switch attachment.color?.lowercased() {
        case "good":
            .green
        case "warning":
            .orange
        case "danger":
            .red
        case let color?:
            Color(slackHex: color) ?? .secondary
        case nil:
            .secondary
        }
    }

    @ViewBuilder
    private func linkedText(_ text: String, destination: URL?) -> some View {
        if let destination {
            Link(text, destination: destination)
        } else {
            Text(text)
        }
    }
}

private struct MessageFileCard: View {
    let file: MessageFile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if file.isImage, let source = file.thumbnailSource {
                MessageRemoteImage(
                    source: source,
                    accessibilityLabel: file.altText ?? file.displayName,
                    compact: false
                )
            }

            HStack(spacing: 8) {
                Image(systemName: fileIcon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    if let permalink = file.permalink {
                        Link(file.displayName, destination: permalink)
                            .font(.callout.weight(.semibold))
                    } else {
                        Text(file.displayName)
                            .font(.callout.weight(.semibold))
                    }
                    if let detail = file.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)

                if let source = file.contentSource {
                    MessageMediaActions(
                        source: source,
                        suggestedName: file.name,
                        cacheKey: file.id
                    )
                }
            }

            if let preview = file.previewText, !preview.isEmpty {
                Text(preview)
                    .font(.caption.monospaced())
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    private var fileIcon: String {
        guard let mimeType = file.mimeType else {
            return "doc"
        }
        if mimeType.hasPrefix("image/") {
            return "photo"
        }
        if mimeType.hasPrefix("video/") {
            return "film"
        }
        if mimeType.hasPrefix("audio/") {
            return "waveform"
        }
        if mimeType.contains("zip") || mimeType.contains("archive") {
            return "archivebox"
        }
        if mimeType.hasPrefix("text/") || mimeType.contains("pdf") {
            return "doc.text"
        }
        return "doc"
    }
}

private struct MessageImageCard: View {
    let image: MessageImage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = image.title {
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            if let source = image.source {
                MessageRemoteImage(
                    source: source,
                    accessibilityLabel: image.altText,
                    compact: false
                )
                MessageMediaActions(
                    source: source,
                    suggestedName: suggestedName,
                    cacheKey: image.slackFileID
                        ?? "image-\(source.url.host ?? "")-\(source.url.lastPathComponent)"
                )
            } else {
                Label(image.altText, systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private var suggestedName: String {
        if let title = image.title, !title.isEmpty {
            return title
        }
        return "Slack image"
    }
}

private struct MessageRemoteImage: View {
    let source: MessageMediaSource
    let accessibilityLabel: String
    let compact: Bool
    @State private var authenticatedImage: CGImage?

    var body: some View {
        Group {
            if source.requiresSlackAuthorization {
                if let authenticatedImage {
                    Image(decorative: authenticatedImage, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    imagePlaceholder
                        .task(id: source) {
                            authenticatedImage = try? await SlackFileTransferService.shared
                                .thumbnail(from: source)
                        }
                }
            } else {
                AsyncImage(
                    url: source.url,
                    transaction: Transaction(animation: .easeOut(duration: 0.15))
                ) { phase in
                    if case let .success(image) = phase {
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        imagePlaceholder
                    }
                }
            }
        }
        .frame(
            maxWidth: compact ? 96 : 300,
            maxHeight: compact ? 96 : 180,
            alignment: .leading
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel(accessibilityLabel)
    }

    private var imagePlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(.quaternary)
            ProgressView()
                .controlSize(.small)
        }
        .frame(width: compact ? 76 : 220, height: compact ? 76 : 110)
    }
}

private struct MessageMediaActions: View {
    let source: MessageMediaSource
    let suggestedName: String
    let cacheKey: String
    @State private var previewURL: URL?
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        Group {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            } else {
                Menu {
                    Button("Quick Look", systemImage: "eye") {
                        perform { previewURL = $0 }
                    }
                    Button("Open", systemImage: "arrow.up.forward.app") {
                        perform { MessageFileSystemActions.open($0) }
                    }
                    Button("Download…", systemImage: "arrow.down.to.line") {
                        download()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("File actions")
            }
        }
        .quickLookPreview($previewURL)
        .alert(
            "File action failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func perform(_ completion: @escaping @MainActor (URL) -> Void) {
        isWorking = true
        Task {
            do {
                let url = try await SlackFileTransferService.shared.localURL(
                    for: source,
                    suggestedName: suggestedName,
                    cacheKey: cacheKey
                )
                completion(url)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func download() {
        guard let destination = MessageFileSystemActions.chooseDestination(
            suggestedName: suggestedName
        ) else {
            return
        }
        isWorking = true
        Task {
            do {
                try await SlackFileTransferService.shared.download(
                    source,
                    suggestedName: suggestedName,
                    cacheKey: cacheKey,
                    to: destination
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

private struct MediaEmojiText: View {
    let text: String
    let customEmojiURLs: [String: URL]

    var body: some View {
        let customEmoji = Set(SlackEmoji.shortcodeNames(in: text)).compactMap { name in
            customEmojiURLs[name].map { RemoteEmoji(shortcode: name, url: $0) }
        }
        EmojiText(verbatim: text, emojis: customEmoji)
    }
}

private extension Color {
    init?(slackHex value: String) {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let number = UInt64(hex, radix: 16) else {
            return nil
        }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}
