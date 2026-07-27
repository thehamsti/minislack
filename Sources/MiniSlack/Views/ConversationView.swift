import AppKit
import EmojiText
import SwiftUI

struct ConversationView: View {
    let store: AppStore
    let windowState: WindowState
    let compact: Bool
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true

    var body: some View {
        if let conversation = store.selectedConversation {
            VStack(spacing: 0) {
                ConversationHeader(
                    store: store,
                    windowState: windowState,
                    conversation: conversation,
                    compact: compact
                )
                MessageList(store: store, conversation: conversation)
                    .id(conversation.id)
                ComposerView(store: store, conversation: conversation)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear {
                if markReadOnOpen {
                    store.markSelectedConversationRead()
                }
            }
            .task(id: conversation.id) {
                await store.loadInitialHistory(for: conversation.id)
            }
        } else {
            ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right")
        }
    }
}

private struct ConversationHeader: View {
    let store: AppStore
    let windowState: WindowState
    let conversation: Conversation
    let compact: Bool

    var body: some View {
        HStack(spacing: 9) {
            if compact {
                Button {
                    store.showUnreadInbox()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to unreads (⌘⇧U)")
            }

            if conversation.isDirectMessage {
                ConversationAvatar(store: store, conversation: conversation, size: 28)
            } else {
                Image(systemName: conversation.systemImage)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.title)
                    .font(.headline)
                if let userID = conversation.participantUserID,
                   let user = store.user(withID: userID)
                {
                    UserStatusLabel(
                        user: user,
                        customEmojiURLs: store.customEmojiURLs
                    )
                } else if let subtitle = conversation.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                windowState.presentQuickSwitcher()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Quick switcher (⌘K)")
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct MessageList: View {
    let store: AppStore
    let conversation: Conversation
    @State private var positionedAtBottom = false

    var body: some View {
        let historyState = store.historyState(for: conversation.id)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if historyState.canLoadOlder || historyState.isLoadingOlder {
                        OlderHistoryBoundary(
                            isLoading: historyState.isLoadingOlder,
                            positionedAtBottom: positionedAtBottom
                        ) {
                            store.loadOlderMessages(for: conversation.id)
                        }
                    }

                    if let errorMessage = historyState.errorMessage {
                        HistoryErrorRow(message: errorMessage) {
                            store.retryHistory(for: conversation.id)
                        }
                    }

                    ForEach(conversation.messages) { message in
                        MessageRow(
                            store: store,
                            message: message,
                            customEmojiURLs: store.customEmojiURLs
                        )
                            .id(message.id)
                    }

                    if conversation.messages.isEmpty,
                       historyState.hasLoadedInitial,
                       historyState.errorMessage == nil
                    {
                        ContentUnavailableView(
                            "No messages yet",
                            systemImage: "bubble.left"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
                .padding(.vertical, 10)
            }
            .overlay {
                if historyState.isLoadingInitial && conversation.messages.isEmpty {
                    ProgressView("Loading recent messages…")
                        .controlSize(.small)
                }
            }
            .onAppear {
                if let lastID = conversation.messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
                Task { @MainActor in
                    positionedAtBottom = true
                }
            }
            .onChange(of: conversation.messages.last?.id) {
                if let lastID = conversation.messages.last?.id {
                    if positionedAtBottom {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct OlderHistoryBoundary: View {
    let isLoading: Bool
    let positionedAtBottom: Bool
    let load: () -> Void

    var body: some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("Scroll up for older messages")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(height: 30)
        .task(id: positionedAtBottom) {
            if positionedAtBottom {
                load()
            }
        }
    }
}

private struct HistoryErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .lineLimit(2)
            Spacer()
            Button("Retry", action: retry)
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }
}

private struct MessageRow: View {
    let store: AppStore
    let message: Message
    let customEmojiURLs: [String: URL]

    var body: some View {
        let user = message.authorUserID.flatMap(store.user(withID:))
        let displayName = user?.displayName ?? message.author

        HStack(alignment: .top, spacing: 10) {
            UserAvatar(
                imageURL: user?.avatarURL ?? message.authorAvatarURL,
                initials: user?.initials ?? message.initials,
                accessibilityName: displayName,
                availability: user?.availability
                    ?? message.authorUserID.map { _ in UserAvailability() },
                isCurrentUser: message.isCurrentUser
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(displayName)
                        .font(.callout.weight(.semibold))
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }

                SlackEmojiText(
                    text: message.displayBody,
                    customEmojiURLs: customEmojiURLs
                )
                    .font(.callout)
                    .textSelection(.enabled)

                if !message.reactions.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(message.reactions, id: \.self) { reaction in
                            SlackEmojiText(
                                text: "\(reaction.emoji) \(reaction.count)",
                                customEmojiURLs: customEmojiURLs
                            )
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Text", systemImage: "doc.on.doc") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(message.displayBody, forType: .string)
            }
        }
    }
}

private struct SlackEmojiText: View {
    let text: String
    let customEmojiURLs: [String: URL]

    var body: some View {
        let customEmoji = Set(SlackEmoji.shortcodeNames(in: text)).compactMap { name in
            customEmojiURLs[name].map { RemoteEmoji(shortcode: name, url: $0) }
        }
        EmojiText(verbatim: text, emojis: customEmoji)
    }
}
