import SwiftUI

struct SavedMessagesView: View {
    let store: AppStore
    let windowState: WindowState
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.savedMessages.isEmpty {
                ContentUnavailableView(
                    "No saved messages",
                    systemImage: "bookmark",
                    description: Text(
                        "Save a message from its context menu. Saved items stay on this Mac."
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.savedMessages) { savedMessage in
                            SavedMessageRow(store: store, savedMessage: savedMessage)
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 9) {
            if compact {
                Button(action: store.showUnreadInbox) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to unreads")

                CompactSidebarButton(windowState: windowState)
            }
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 0) {
                Text("Saved messages")
                    .font(.headline)
                Text("Stored locally for this workspace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !store.savedMessages.isEmpty {
                Text(store.savedMessages.count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, compact ? 12 : 16)
        .frame(height: 50)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct SavedMessageRow: View {
    let store: AppStore
    let savedMessage: SavedMessage

    var body: some View {
        let message = savedMessage.message
        let user = message.authorUserID.flatMap(store.user(withID:))
        let displayName = user?.displayName ?? message.author

        HStack(alignment: .top, spacing: 10) {
            UserAvatar(
                imageURL: user?.avatarURL ?? message.authorAvatarURL,
                initials: user?.initials ?? message.initials,
                accessibilityName: displayName,
                availability: user?.availability
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(displayName)
                        .font(.callout.weight(.semibold))
                    Text(message.timestamp, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(message.timestamp, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        store.openSavedMessage(savedMessage)
                    } label: {
                        Label(
                            savedMessage.conversationTitle,
                            systemImage: "arrow.up.right"
                        )
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }

                if let richText = message.richText {
                    MessageRichTextView(
                        document: richText,
                        customEmojiURLs: store.customEmojiURLs
                    )
                    .font(.callout)
                    .textSelection(.enabled)
                } else {
                    SlackEmojiText(
                        text: message.displayBody,
                        customEmojiURLs: store.customEmojiURLs
                    )
                    .font(.callout)
                    .textSelection(.enabled)
                }

                if !message.attachments.isEmpty
                    || !message.files.isEmpty
                    || !message.images.isEmpty
                    || !message.actions.isEmpty
                {
                    MessageMediaView(
                        message: message,
                        customEmojiURLs: store.customEmojiURLs
                    )
                }
            }

            Button {
                store.removeSavedMessage(id: savedMessage.id)
            } label: {
                Image(systemName: "bookmark.slash")
            }
            .buttonStyle(.borderless)
            .help("Remove saved message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
