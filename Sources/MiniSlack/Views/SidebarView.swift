import SwiftUI

struct SidebarView: View {
    let store: AppStore
    let windowState: WindowState
    @AppStorage("sidebarSort.unread") private var unreadSort = ConversationSortOption.activity
    @AppStorage("sidebarSort.favorites") private var favoritesSort = ConversationSortOption.activity
    @AppStorage("sidebarSort.channels") private var channelsSort = ConversationSortOption.activity
    @AppStorage("sidebarSort.directMessages") private var directMessagesSort = ConversationSortOption.activity
    @AppStorage("sidebarSort.groupMessages") private var groupMessagesSort = ConversationSortOption.activity

    var body: some View {
        @Bindable var store = store

        List(selection: $store.destination) {
            Section {
                Label {
                    HStack {
                        Text("Unreads")
                        Spacer()
                        if !store.unreadConversations.isEmpty {
                            CountBadge(count: store.unreadConversations.reduce(0) { $0 + $1.unreadCount })
                        }
                    }
                } icon: {
                    Image(systemName: "tray.full.fill")
                        .foregroundStyle(.orange)
                }
                .tag(AppStore.Destination.unreadInbox)
            }

            if !store.unreadConversations.isEmpty {
                Section {
                    ForEach(store.sortedUnreadConversations(by: unreadSort)) { conversation in
                        ConversationSidebarRow(
                            store: store,
                            conversation: conversation,
                            highlightsUnread: true
                        )
                            .tag(AppStore.Destination.conversation(conversation.id))
                    }
                } header: {
                    SortableSectionHeader(title: "Unread now", selection: $unreadSort)
                }
            }

            Section {
                ForEach(store.sortedFavoriteConversations(by: favoritesSort)) { conversation in
                    ConversationSidebarRow(store: store, conversation: conversation)
                        .tag(AppStore.Destination.conversation(conversation.id))
                }
            } header: {
                SortableSectionHeader(title: "Favorites", selection: $favoritesSort)
            }

            Section {
                ForEach(store.sortedChannelConversations(by: channelsSort)) { conversation in
                    ConversationSidebarRow(store: store, conversation: conversation)
                        .tag(AppStore.Destination.conversation(conversation.id))
                }
            } header: {
                SortableSectionHeader(title: "Channels", selection: $channelsSort)
            }

            Section {
                ForEach(store.sortedDirectConversations(by: directMessagesSort)) { conversation in
                    ConversationSidebarRow(store: store, conversation: conversation)
                        .tag(AppStore.Destination.conversation(conversation.id))
                }
            } header: {
                SortableSectionHeader(title: "Direct messages", selection: $directMessagesSort)
            }

            Section {
                ForEach(store.sortedGroupDirectConversations(by: groupMessagesSort)) { conversation in
                    ConversationSidebarRow(store: store, conversation: conversation)
                        .tag(AppStore.Destination.conversation(conversation.id))
                }
            } header: {
                SortableSectionHeader(title: "Group messages", selection: $groupMessagesSort)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Acme Studio")
        .safeAreaInset(edge: .bottom) {
            KeyboardHint()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    windowState.presentQuickSwitcher()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Quick switcher (⌘K)")
            }
        }
    }
}

private struct SortableSectionHeader: View {
    let title: String
    @Binding var selection: ConversationSortOption

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Spacer()
            Menu {
                Picker("Sort \(title)", selection: $selection) {
                    ForEach(ConversationSortOption.allCases) { option in
                        Label(option.title, systemImage: option.systemImage)
                            .tag(option)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .imageScale(.small)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort \(title.lowercased()) by \(selection.title.lowercased())")
        }
    }
}

private struct ConversationSidebarRow: View {
    let store: AppStore
    let conversation: Conversation
    var highlightsUnread = false

    var body: some View {
        HStack(spacing: 8) {
            if conversation.isDirectMessage {
                ConversationAvatar(store: store, conversation: conversation, size: 18)
            } else {
                Image(systemName: conversation.systemImage)
                    .font(.system(size: 12, weight: highlightsUnread ? .semibold : .regular))
                    .foregroundStyle(highlightsUnread ? .primary : .secondary)
                    .frame(width: 18)
            }

            Text(conversation.title)
                .fontWeight(highlightsUnread ? .semibold : .regular)
                .lineLimit(1)

            Spacer(minLength: 4)

            if conversation.mentionCount > 0 {
                CountBadge(count: conversation.mentionCount, emphasized: true)
            } else if highlightsUnread {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

private struct KeyboardHint: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "keyboard")
            Text("J/K navigate")
            Spacer()
            Text("L open")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

struct CountBadge: View {
    let count: Int
    var emphasized = false
    @AppStorage("showUnreadCounts") private var showUnreadCounts = true

    var body: some View {
        if showUnreadCounts {
            Text(count, format: .number)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(emphasized ? .white : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(emphasized ? AnyShapeStyle(.orange) : AnyShapeStyle(.quaternary), in: Capsule())
        }
    }
}
