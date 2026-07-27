import SwiftUI

struct QuickSwitcherView: View {
    let store: AppStore
    let windowState: WindowState
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = store
        let showsUnreads = store.quickSwitcherShowsUnreads
        let users = store.quickSwitcherUsers
        let groupMessages = store.quickSwitcherGroupMessages
        let channels = store.quickSwitcherChannels
        let hasResults = showsUnreads
            || !users.isEmpty
            || !groupMessages.isEmpty
            || !channels.isEmpty

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Go to a page, channel, or person", text: $store.quickSwitcherQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        openSelection()
                    }
                    .onKeyPress(.downArrow) {
                        store.moveQuickSwitcherSelection(offset: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        store.moveQuickSwitcherSelection(offset: -1)
                        return .handled
                    }
            }
            .padding(14)

            Divider()

            if hasResults {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                            if showsUnreads {
                                quickSwitcherSection("Go to") {
                                    let item = AppStore.QuickSwitcherItem.unreads
                                    resultButton(item: item) {
                                        HStack(spacing: 10) {
                                            Image(systemName: "tray.full.fill")
                                                .foregroundStyle(.orange)
                                                .frame(width: 24)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Unreads")
                                                    .fontWeight(.semibold)
                                                Text("\(store.unreadConversations.count) conversations need attention")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer()
                                            if !store.unreadConversations.isEmpty {
                                                CountBadge(
                                                    count: store.unreadConversations.reduce(0) {
                                                        $0 + $1.unreadCount
                                                    }
                                                )
                                            }
                                        }
                                    }
                                }
                            }

                            if !users.isEmpty {
                                quickSwitcherSection("Direct message") {
                                    ForEach(users) { user in
                                        resultButton(item: .user(user.id)) {
                                            UserQuickSwitcherRow(user: user)
                                        }
                                    }
                                }
                            }

                            if !groupMessages.isEmpty {
                                quickSwitcherSection("Group messages") {
                                    ForEach(groupMessages) { conversation in
                                        resultButton(item: .channel(conversation.id)) {
                                            ChannelQuickSwitcherRow(conversation: conversation)
                                        }
                                    }
                                }
                            }

                            if !channels.isEmpty {
                                quickSwitcherSection("Channels") {
                                    ForEach(channels) { conversation in
                                        resultButton(item: .channel(conversation.id)) {
                                            ChannelQuickSwitcherRow(conversation: conversation)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .onChange(of: store.quickSwitcherSelection) {
                        if let selection = store.quickSwitcherSelection {
                            withAnimation(.snappy(duration: 0.12)) {
                                proxy.scrollTo(selection.id, anchor: .center)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView.search(text: store.quickSwitcherQuery)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            store.ensureQuickSwitcherSelection()
        }
        .onChange(of: store.quickSwitcherQuery) {
            store.ensureQuickSwitcherSelection()
        }
        .onChange(of: windowState.isQuickSwitcherPresented) {
            searchFocused = windowState.isQuickSwitcherPresented
            if !windowState.isQuickSwitcherPresented {
                store.dismissQuickSwitcher()
            }
        }
        .onExitCommand {
            windowState.dismissQuickSwitcher()
        }
    }

    private func openSelection() {
        store.openQuickSwitcherSelection()
        windowState.dismissQuickSwitcher()
    }

    @ViewBuilder
    private func quickSwitcherSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
        } header: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.regularMaterial)
        }
    }

    private func resultButton<Label: View>(
        item: AppStore.QuickSwitcherItem,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            store.quickSwitcherSelection = item
            openSelection()
        } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    store.quickSwitcherSelection == item
                        ? Color.accentColor.opacity(0.18)
                        : .clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(Rectangle())
        }
        .onHover { hovering in
            if hovering {
                store.quickSwitcherSelection = item
            }
        }
        .buttonStyle(.plain)
        .id(item.id)
        .accessibilityAddTraits(store.quickSwitcherSelection == item ? .isSelected : [])
    }
}

private struct UserQuickSwitcherRow: View {
    let user: WorkspaceUser

    var body: some View {
        HStack(spacing: 10) {
            UserAvatar(
                imageURL: user.avatarURL,
                initials: user.initials,
                accessibilityName: user.displayName,
                size: 28,
                isActive: user.isActive
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .fontWeight(.medium)
                Text(user.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Text("Message")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct ChannelQuickSwitcherRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 10) {
            if conversation.isDirectMessage {
                ConversationAvatar(conversation: conversation, size: 28)
            } else {
                Image(systemName: "number")
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .fontWeight(conversation.isUnread ? .semibold : .regular)
                if let subtitle = conversation.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            if conversation.isUnread {
                CountBadge(count: conversation.unreadCount)
            }
        }
        .contentShape(Rectangle())
    }
}
