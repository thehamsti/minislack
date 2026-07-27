import SwiftUI

struct ComposerAttachmentTray: View {
    let state: ComposerAttachmentDraftState
    let remove: (UUID) -> Void
    let dismissError: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !state.attachments.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 7) {
                        ForEach(state.attachments) { attachment in
                            ComposerAttachmentChip(
                                attachment: attachment,
                                remove: { remove(attachment.id) }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
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
    }
}

private struct ComposerAttachmentChip: View {
    let attachment: ComposerPendingAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            if attachment.kind == .image {
                ComposerAttachmentThumbnail(url: attachment.fileURL)
            } else {
                Image(systemName: "doc.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if !attachment.detail.isEmpty {
                    Text(attachment.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 128, alignment: .leading)

            attachmentAction
        }
        .padding(5)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            if case .failed = attachment.uploadState {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.orange.opacity(0.8), lineWidth: 1)
            }
        }
        .help(attachmentHelp)
    }

    @ViewBuilder
    private var attachmentAction: some View {
        switch attachment.uploadState {
        case .uploading:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 18, height: 18)
        case .ready, .failed:
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove \(attachment.filename)")
        }
    }

    private var attachmentHelp: String {
        if case let .failed(message) = attachment.uploadState {
            return "\(attachment.filename): \(message)"
        }
        return attachment.filename
    }
}

private struct ComposerAttachmentThumbnail: View {
    let url: URL
    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle()
                        .fill(.quaternary)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
                .task(id: url) {
                    thumbnail = try? await ComposerAttachmentFileService.shared
                        .thumbnail(for: url)
                }
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
    }
}
