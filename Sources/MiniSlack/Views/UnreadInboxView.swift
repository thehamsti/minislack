import SwiftUI

struct UnreadInboxView: View {
    let store: AppStore
    let windowState: WindowState
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            UnreadHeader(store: store, windowState: windowState, compact: compact)

            if store.unreadConversations.isEmpty {
                ContentUnavailableView(
                    "You’re all caught up",
                    systemImage: "checkmark.circle.fill",
                    description: Text("New unread conversations will appear here.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: compact ? 8 : 12) {
                            ForEach(store.unreadConversations) { conversation in
                                Button {
                                    store.select(conversation.id)
                                } label: {
                                    UnreadCard(
                                        conversation: conversation,
                                        compact: compact,
                                        isKeyboardSelected: store.keyboardConversationID == conversation.id
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(conversation.id)
                            }
                        }
                        .padding(compact ? 10 : 18)
                    }
                    .onAppear {
                        store.ensureKeyboardSelection()
                    }
                    .onChange(of: store.keyboardConversationID) {
                        if let id = store.keyboardConversationID {
                            withAnimation(.snappy) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct UnreadHeader: View {
    let store: AppStore
    let windowState: WindowState
    let compact: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Unreads")
                    .font(.title2.bold())
                Text("\(store.unreadConversations.count) conversations need attention")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if compact {
                Button {
                    windowState.presentQuickSwitcher()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Quick switcher (⌘K)")
            }
        }
        .padding(.horizontal, compact ? 14 : 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct UnreadCard: View {
    let conversation: Conversation
    let compact: Bool
    let isKeyboardSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(spacing: 8) {
                if conversation.isDirectMessage {
                    ConversationAvatar(conversation: conversation, size: 22)
                } else {
                    Image(systemName: conversation.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text(conversation.title)
                    .font(.headline)
                if conversation.mentionCount > 0 {
                    CountBadge(count: conversation.mentionCount, emphasized: true)
                }
                Spacer()
                Text(conversation.latestActivity, style: .time)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            if let message = conversation.latestMessage {
                HStack(alignment: .top, spacing: 8) {
                    UserAvatar(
                        imageURL: message.authorAvatarURL,
                        initials: message.initials,
                        accessibilityName: message.author,
                        size: 24
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.author)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(message.body)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(compact ? 2 : 3)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
        .padding(compact ? 12 : 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    isKeyboardSelected ? AnyShapeStyle(.orange) : AnyShapeStyle(.separator.opacity(0.55)),
                    lineWidth: isKeyboardSelected ? 2 : 0.5
                )
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isKeyboardSelected ? .isSelected : [])
    }
}
