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
                ConversationAvatar(conversation: conversation, size: 28)
            } else {
                Image(systemName: conversation.systemImage)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.title)
                    .font(.headline)
                if let subtitle = conversation.subtitle {
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
                        MessageRow(message: message)
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
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            UserAvatar(
                imageURL: message.authorAvatarURL,
                initials: message.initials,
                accessibilityName: message.author,
                isCurrentUser: message.isCurrentUser
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(message.author)
                        .font(.callout.weight(.semibold))
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }

                Text(message.body)
                    .font(.callout)
                    .textSelection(.enabled)

                if !message.reactions.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(message.reactions, id: \.self) { reaction in
                            Text("\(reaction.emoji) \(reaction.count)")
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
    }
}

private struct ComposerView: View {
    let store: AppStore
    let conversation: Conversation

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(conversation.kind == .channel ? "#" : "")\(conversation.title)", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 5)
                    .onSubmit {
                        store.sendDraft()
                    }

                Button {
                    store.sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
                .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send message")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.separator, lineWidth: 0.5)
            }
            .padding(10)
        }
        .background(.bar)
    }
}
