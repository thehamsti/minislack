import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ComposerAttachmentTray: View {
    let state: ComposerAttachmentDraftState
    let remove: (UUID) -> Void
    let dismissError: () -> Void
    @State private var previewURL: URL?
    @State private var codePreview: CodePreviewSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !state.attachments.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 8) {
                        ForEach(state.attachments) { attachment in
                            ComposerAttachmentPreview(
                                attachment: attachment,
                                openPreview: { preview(attachment) },
                                openInQuickLook: {
                                    previewURL = attachment.fileURL
                                },
                                remove: { remove(attachment.id) }
                            )
                        }
                    }
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let progress = state.progress {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(progress.displayText)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let errorMessage = state.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button(action: dismissError) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss attachment error")
                }
                .font(.caption)
            }
        }
        .quickLookPreview($previewURL)
        .sheet(item: $codePreview) { selection in
            CodePreviewSheet(
                filename: selection.filename,
                detail: selection.detail,
                document: selection.document,
                openInQuickLook: { previewURL = selection.fileURL }
            )
        }
    }

    /// Quick Look has no reliable renderer for many source formats, so text
    /// and code open in the syntax-highlighted sheet instead.
    private func preview(_ attachment: ComposerPendingAttachment) {
        Task {
            guard let document = await ComposerAttachmentFileService.shared
                .codePreview(
                    for: attachment.fileURL,
                    filename: attachment.filename
                )
            else {
                previewURL = attachment.fileURL
                return
            }
            codePreview = CodePreviewSelection(
                fileURL: attachment.fileURL,
                filename: attachment.filename,
                detail: attachment.detail,
                document: document
            )
        }
    }
}

private struct CodePreviewSelection: Identifiable {
    let fileURL: URL
    let filename: String
    let detail: String
    let document: CodePreviewDocument

    var id: URL { fileURL }
}

private struct ComposerAttachmentPreview: View {
    static let previewSize: CGFloat = 68

    let attachment: ComposerPendingAttachment
    let openPreview: () -> Void
    let openInQuickLook: () -> Void
    let remove: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            preview
                .frame(width: Self.previewSize, height: Self.previewSize)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(borderStyle, lineWidth: hasFailed ? 1 : 0.5)
                }
                .overlay(alignment: .center) {
                    if attachment.uploadState == .uploading {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.black.opacity(0.25))
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if attachment.uploadState != .uploading {
                        removeButton
                            .offset(x: 6, y: -6)
                    }
                }

            Text(attachment.filename)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(attachment.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: Self.previewSize)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: openPreview)
        .contextMenu {
            Button("Preview", systemImage: "eye", action: openPreview)
            Button(
                "Quick Look",
                systemImage: "rectangle.and.text.magnifyingglass",
                action: openInQuickLook
            )
            Button("Open", systemImage: "arrow.up.forward.app") {
                MessageFileSystemActions.open(attachment.fileURL)
            }
            Button("Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    attachment.fileURL,
                ])
            }
            if attachment.uploadState != .uploading {
                Divider()
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
            }
        }
        .help(attachmentHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryText)
        .accessibilityHint("Double-click to preview")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var preview: some View {
        ComposerAttachmentThumbnail(
            url: attachment.fileURL,
            pointSize: Self.previewSize,
            placeholder: symbolName
        )
    }

    private var removeButton: some View {
        Button(action: remove) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    Color(nsColor: .controlBackgroundColor),
                    Color.primary.opacity(0.75)
                )
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0.001)
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .help("Remove \(attachment.filename)")
        .accessibilityLabel("Remove \(attachment.filename)")
    }

    private var hasFailed: Bool {
        if case .failed = attachment.uploadState {
            return true
        }
        return false
    }

    private var borderStyle: AnyShapeStyle {
        hasFailed
            ? AnyShapeStyle(.orange.opacity(0.8))
            : AnyShapeStyle(Color(nsColor: .separatorColor))
    }

    private var symbolName: String {
        guard let type = attachment.contentTypeIdentifier
            .flatMap(UTType.init)
        else {
            return "doc.fill"
        }
        if type.conforms(to: .movie) {
            return "film.fill"
        }
        if type.conforms(to: .audio) {
            return "waveform"
        }
        if type.conforms(to: .archive) {
            return "doc.zipper"
        }
        if type.conforms(to: .text) {
            return "doc.text.fill"
        }
        return "doc.fill"
    }

    private var summaryText: String {
        attachment.detail.isEmpty
            ? attachment.filename
            : "\(attachment.filename) · \(attachment.detail)"
    }

    private var attachmentHelp: String {
        if case let .failed(message) = attachment.uploadState {
            return "\(attachment.filename): \(message)"
        }
        return "\(summaryText) — double-click to preview"
    }
}

private struct ComposerAttachmentThumbnail: View {
    let url: URL
    let pointSize: CGFloat
    let placeholder: String
    @State private var thumbnail: CGImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle()
                        .fill(.quaternary.opacity(0.5))
                    Image(systemName: placeholder)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: url) {
            thumbnail = await ComposerAttachmentFileService.shared.previewImage(
                for: url,
                pointSize: pointSize,
                scale: displayScale
            )
        }
        .accessibilityHidden(true)
    }
}
