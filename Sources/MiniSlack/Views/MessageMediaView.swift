import AppKit
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
    var continueInSlack: (() -> Void)?

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
            if !message.actions.isEmpty {
                SlackMessageActionRow(
                    actions: message.actions,
                    continueInSlack: continueInSlack
                )
            }
        }
    }
}

private struct SlackMessageActionRow: View {
    let actions: [SlackMessageAction]
    let continueInSlack: (() -> Void)?
    @Environment(\.openURL) private var openURL
    @State private var pendingAction: SlackMessageAction?

    var body: some View {
        SlackActionFlowLayout(spacing: 6) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                actionButton(action)
            }
        }
        .alert(
            pendingAction?.confirmation?.title ?? "Confirm action",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            let confirmation = action.confirmation
            Button(
                confirmation?.confirmLabel ?? "Continue",
                role: confirmation?.isDestructive == true ? .destructive : nil
            ) {
                perform(action)
                pendingAction = nil
            }
            Button(confirmation?.cancelLabel ?? "Cancel", role: .cancel) {
                pendingAction = nil
            }
        } message: { action in
            Text(action.confirmation?.message ?? "")
        }
    }

    @ViewBuilder
    private func actionButton(_ action: SlackMessageAction) -> some View {
        let button = Button {
            if action.confirmation == nil {
                perform(action)
            } else {
                pendingAction = action
            }
        } label: {
            Text(action.label)
                .lineLimit(1)
        }
        .controlSize(.small)
        .disabled(action.destination == nil && continueInSlack == nil)
        .accessibilityLabel(action.accessibilityLabel ?? action.label)
        .help(action.destination == nil ? "Continue this action in Slack" : action.label)

        switch action.style {
        case .standard:
            button.buttonStyle(.bordered)
        case .primary:
            button
                .buttonStyle(.borderedProminent)
                .tint(.green)
        case .danger:
            button
                .buttonStyle(.bordered)
                .tint(.red)
        }
    }

    private func perform(_ action: SlackMessageAction) {
        if let destination = action.destination {
            openURL(destination)
        } else {
            continueInSlack?()
        }
    }
}

private struct SlackActionFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(subviews: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(subviews: subviews, width: bounds.width)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(
        subviews: Subviews,
        width: CGFloat
    ) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin.x = 0
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(origin)
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            contentWidth = max(contentWidth, min(width, origin.x - spacing))
        }

        return (
            CGSize(
                width: contentWidth,
                height: subviews.isEmpty ? 0 : origin.y + rowHeight
            ),
            points
        )
    }
}

private struct MessageAttachmentCard: View {
    let attachment: MessageAttachment
    let customEmojiURLs: [String: URL]
    @Environment(\.openURL) private var openURL
    @State private var isTextExpanded = false

    /// Prefer the unfurl target, then author/service URLs when present.
    private var primaryDestination: URL? {
        attachment.titleURL
            ?? attachment.authorURL
            ?? attachment.serviceURL
    }

    var body: some View {
        // Do not wrap the whole card in `Link` — on macOS that clips multi-line
        // attachment content (fields, images, footers). Keep explicit links on
        // title/author and open the primary URL on card click instead.
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(accentColor)
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                if let pretext = attachment.pretext {
                    MediaEmojiText(
                        text: pretext,
                        customEmojiURLs: customEmojiURLs
                    )
                    .foregroundStyle(.secondary)
                }

                if attachment.authorName != nil || attachment.serviceName != nil {
                    HStack(spacing: 5) {
                        if let iconURL = attachment.authorIconURL {
                            attachmentIcon(url: iconURL, size: 16)
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
                        text: text,
                        customEmojiURLs: customEmojiURLs
                    )
                    .font(.callout)
                    .lineLimit(isTextExpanded ? nil : 8)

                    if text.display.count > 500 {
                        Button(isTextExpanded ? "Show less" : "Show more") {
                            isTextExpanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }

                ForEach(Array(attachment.fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 1) {
                        if let title = field.title {
                            Text(title)
                                .font(.caption.weight(.semibold))
                        }
                        MediaEmojiText(
                            text: field.value,
                            customEmojiURLs: customEmojiURLs
                        )
                        .font(.caption)
                    }
                }

                if let source = attachment.thumbnailSource ?? attachment.imageSource {
                    let previewSource = attachment.imageSource ?? source
                    MessageRemoteImage(
                        source: source,
                        accessibilityLabel: attachment.title
                            ?? attachment.fallback
                            ?? "Attachment image",
                        compact: attachment.thumbnailSource != nil
                            && attachment.imageSource == nil,
                        preview: MessageImagePreviewRequest(
                            source: previewSource,
                            suggestedName: attachment.title ?? "Slack image",
                            cacheKey: "attachment-\(previewSource.url.absoluteString)"
                        )
                    )
                }

                if attachment.hasFooter {
                    attachmentFooter
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        // Card chrome is tappable; nested Links on title/author still win hit-testing.
        .onTapGesture {
            guard let primaryDestination else { return }
            openURL(primaryDestination)
        }
        .help(primaryDestination.map(\.absoluteString) ?? "")
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open attachment") {
            guard let primaryDestination else { return }
            openURL(primaryDestination)
        }
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

    /// Classic Slack attachment footer: icon · label · timestamp.
    /// Spec: https://docs.slack.dev/legacy/legacy-messaging/legacy-secondary-message-attachments
    /// - `footer_icon` only renders when `footer` is present (16×16)
    /// - `ts` is shown as part of the footer row
    private var attachmentFooter: some View {
        HStack(alignment: .center, spacing: 5) {
            // Slack only draws footer_icon when footer text is present.
            if attachment.footer != nil, let iconURL = attachment.footerIconURL {
                attachmentIcon(url: iconURL, size: 16)
            }

            if let footer = attachment.footer {
                MediaEmojiText(
                    text: footer,
                    customEmojiURLs: customEmojiURLs
                )
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }

            if attachment.footer != nil, attachment.timestamp != nil {
                Text("·")
            }

            if let timestamp = attachment.timestamp {
                Text(Self.footerTimestampText(timestamp))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(footerAccessibilityLabel)
    }

    private var footerAccessibilityLabel: String {
        var parts: [String] = []
        if let footer = attachment.footer?.display, !footer.isEmpty {
            parts.append(footer)
        }
        if let timestamp = attachment.timestamp {
            parts.append(Self.footerTimestampText(timestamp))
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func attachmentIcon(url: URL, size: CGFloat) -> some View {
        AsyncImage(url: url) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size <= 14 ? 2 : 3))
        .accessibilityHidden(true)
    }

    /// Slack varies footer time by recency ("Today at 12:17 PM", etc.).
    private static func footerTimestampText(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return "Today at \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday at \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
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
    @State private var previewURL: URL?
    @State private var previewErrorMessage: String?
    @State private var isPreparingPreview = false

    private var displayImageSource: MessageMediaSource? {
        guard file.isImage else { return nil }
        return file.thumbnailSource ?? file.contentSource
    }

    private var imagePreview: MessageImagePreviewRequest? {
        guard let source = file.contentSource ?? file.thumbnailSource else {
            return nil
        }
        return MessageImagePreviewRequest(
            source: source,
            suggestedName: file.name,
            cacheKey: file.id
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = displayImageSource {
                MessageRemoteImage(
                    source: source,
                    accessibilityLabel: file.altText ?? file.displayName,
                    compact: false,
                    preview: imagePreview
                )
            }

            HStack(spacing: 8) {
                Image(systemName: fileIcon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    if file.inlinePreviewSource != nil {
                        Button(file.displayName) {
                            previewVideo()
                        }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .disabled(isPreparingPreview)
                        .help("Preview \(file.displayName)")
                        .accessibilityHint("Opens the video preview")
                    } else if let permalink = file.permalink {
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
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            .quaternary.opacity(file.isImage ? 0.22 : 0.35),
            in: RoundedRectangle(cornerRadius: file.isImage ? 8 : 6, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .quickLookPreview($previewURL)
        .alert(
            "Preview failed",
            isPresented: Binding(
                get: { previewErrorMessage != nil },
                set: { if !$0 { previewErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(previewErrorMessage ?? "")
        }
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

    private func previewVideo() {
        guard let source = file.inlinePreviewSource, !isPreparingPreview else {
            return
        }
        isPreparingPreview = true
        Task {
            do {
                previewURL = try await SlackFileTransferService.shared.localURL(
                    for: source,
                    suggestedName: file.name,
                    cacheKey: file.id
                )
            } catch {
                previewErrorMessage = error.localizedDescription
            }
            isPreparingPreview = false
        }
    }
}

private struct MessageImageCard: View {
    let image: MessageImage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = image.title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let source = image.source {
                let cacheKey = image.slackFileID
                    ?? "image-\(source.url.host ?? "")-\(source.url.lastPathComponent)"
                ZStack(alignment: .topTrailing) {
                    MessageRemoteImage(
                        source: source,
                        accessibilityLabel: image.altText,
                        compact: false,
                        preview: MessageImagePreviewRequest(
                            source: source,
                            suggestedName: suggestedName,
                            cacheKey: cacheKey
                        )
                    )

                    MessageMediaActions(
                        source: source,
                        suggestedName: suggestedName,
                        cacheKey: cacheKey
                    )
                    .padding(4)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(6)
                }
            } else {
                Label(image.altText, systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private var suggestedName: String {
        if let title = image.title, !title.isEmpty {
            return title
        }
        return "Slack image"
    }
}

/// Full-resolution source used when the user double-clicks a thumbnail.
private struct MessageImagePreviewRequest: Equatable {
    let source: MessageMediaSource
    let suggestedName: String
    let cacheKey: String
}

private struct MessageRemoteImage: View {
    let source: MessageMediaSource
    let accessibilityLabel: String
    let compact: Bool
    var preview: MessageImagePreviewRequest? = nil

    @State private var authenticatedImage: CGImage?
    @State private var isHovered = false
    @State private var previewURL: URL?
    @State private var isPreparingPreview = false
    @State private var errorMessage: String?

    private var cornerRadius: CGFloat { compact ? 5 : 8 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            imageContent
                .frame(
                    maxWidth: compact ? 96 : 360,
                    maxHeight: compact ? 96 : 280,
                    alignment: .leading
                )
                .clipShape(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )

            if isPreparingPreview {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(6)
            } else if showsExpandHint {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 5))
                    .padding(6)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(isHovered && preview != nil ? 0.24 : 0.1),
                    lineWidth: 1
                )
        }
        .shadow(
            color: .black.opacity(compact ? 0 : (isHovered ? 0.14 : 0.07)),
            radius: compact ? 0 : (isHovered ? 10 : 4),
            y: compact ? 0 : 1
        )
        .contentShape(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .onHover(perform: handleHover)
        .onDisappear(perform: clearHoverCursor)
        .highPriorityGesture(
            TapGesture(count: 2).onEnded { openPreview() }
        )
        .help(previewHelp)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(preview == nil ? "" : "Double-click to open a larger preview")
        .accessibilityAction(named: "Quick Look") { openPreview() }
        .quickLookPreview($previewURL)
        .alert(
            "Preview failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isPreparingPreview)
    }

    @ViewBuilder
    private var imageContent: some View {
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

    private var imagePlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary)
            ProgressView()
                .controlSize(.small)
        }
        .frame(width: compact ? 76 : 240, height: compact ? 76 : 140)
    }

    private var showsExpandHint: Bool {
        preview != nil && isHovered && !compact
    }

    private var previewHelp: String {
        if preview == nil {
            return accessibilityLabel
        }
        return "\(accessibilityLabel) — double-click to preview"
    }

    private func handleHover(_ hovering: Bool) {
        if isHovered, !hovering, preview != nil {
            NSCursor.pop()
        } else if !isHovered, hovering, preview != nil {
            NSCursor.pointingHand.push()
        }
        isHovered = hovering
    }

    private func clearHoverCursor() {
        guard isHovered, preview != nil else {
            isHovered = false
            return
        }
        NSCursor.pop()
        isHovered = false
    }

    private func openPreview() {
        guard let preview, !isPreparingPreview else { return }
        isPreparingPreview = true
        Task {
            do {
                let url = try await SlackFileTransferService.shared.localURL(
                    for: preview.source,
                    suggestedName: preview.suggestedName,
                    cacheKey: preview.cacheKey
                )
                previewURL = url
            } catch {
                errorMessage = error.localizedDescription
            }
            isPreparingPreview = false
        }
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
    let text: MessageFormattedText
    let customEmojiURLs: [String: URL]

    var body: some View {
        let attributedString = MessageRichTextAttributedString.make(from: text.runs)
        let customEmoji = Set(
            SlackEmoji.shortcodeNames(in: String(attributedString.characters))
        )
        .compactMap { name in
            customEmojiURLs[name].map { RemoteEmoji(shortcode: name, url: $0) }
        }
        EmojiText(attributedString, emojis: customEmoji)
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
