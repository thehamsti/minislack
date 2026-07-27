import SwiftUI

struct UnreadInboxView: View {
    let store: AppStore
    let windowState: WindowState
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            UnreadHeader(store: store, windowState: windowState, compact: compact)

            if !store.unreadConversations.isEmpty {
                UnreadFilterBar(store: store, compact: compact)
            }

            if store.unreadConversations.isEmpty {
                ContentUnavailableView(
                    "You’re all caught up",
                    systemImage: "checkmark.circle.fill",
                    description: Text("New unread conversations will appear here.")
                )
            } else if store.filteredUnreadConversations.isEmpty {
                UnreadNoMatchesView {
                    store.unreadFilters.clearActiveFilters()
                }
            } else {
                conversationList
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var conversationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: compact ? 8 : 12) {
                    ForEach(store.filteredUnreadConversations) { conversation in
                        UnreadCardRow(
                            store: store,
                            conversation: conversation,
                            compact: compact,
                            isKeyboardSelected: store.keyboardConversationID == conversation.id
                        )
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

private struct UnreadHeader: View {
    let store: AppStore
    let windowState: WindowState
    let compact: Bool
    @State private var isMarkAllConfirmationPresented = false

    private var visibleCount: Int {
        store.filteredUnreadConversations.count
    }

    private var summaryText: String {
        let unread = store.unreadConversations
        let messageCount = unread.reduce(0) { $0 + $1.unreadCount }
        let mentionCount = unread.reduce(0) { $0 + $1.mentionCount }
        var parts: [String] = []
        if store.unreadFilters.isFiltering {
            parts.append("Showing \(visibleCount) of \(unread.count)")
        } else {
            parts.append(
                "\(unread.count) \(unread.count == 1 ? "conversation" : "conversations")"
            )
        }
        parts.append("\(messageCount) unread")
        if mentionCount > 0 {
            parts.append("\(mentionCount) \(mentionCount == 1 ? "mention" : "mentions")")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Unreads")
                    .font(.title2.bold())
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !store.unreadConversations.isEmpty {
                Button {
                    isMarkAllConfirmationPresented = true
                } label: {
                    if compact {
                        Image(systemName: "checkmark.circle")
                    } else {
                        Label(
                            store.unreadFilters.isFiltering
                                ? "Mark Visible Read" : "Mark All Read",
                            systemImage: "checkmark.circle"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .small : .regular)
                .disabled(visibleCount == 0)
                .help(
                    "Mark \(visibleCount) \(visibleCount == 1 ? "conversation" : "conversations") as read"
                )
                .confirmationDialog(
                    "Mark \(visibleCount) \(visibleCount == 1 ? "conversation" : "conversations") as read?",
                    isPresented: $isMarkAllConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("Mark as Read") {
                        store.markVisibleUnreadsRead()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "Every \(store.unreadFilters.isFiltering ? "visible " : "")unread conversation will be marked as read and synced to Slack. You can’t undo this."
                    )
                }
            }

            if compact {
                ConversationManagementMenu(store: store)

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

private struct UnreadFilterBar: View {
    let store: AppStore
    let compact: Bool
    @State private var isWhenPopoverPresented = false
    @State private var customRangeStart = Date.now.addingTimeInterval(-86_400)
    @State private var customRangeEnd = Date.now

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                searchField
                kindMenu
                conversationMenu
                authorMenu
                whenControl
                mentionsToggle
                sortMenu
                if store.unreadFilters.isFiltering {
                    clearButton
                }
            }
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, 7)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var searchField: some View {
        TextField(
            "Filter text…",
            text: Binding(
                get: { store.unreadFilters.query },
                set: { store.unreadFilters.query = $0 }
            )
        )
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .frame(width: compact ? 104 : 136)
    }

    private var kindMenu: some View {
        Menu {
            ForEach(UnreadConversationKindFilter.allCases) { kind in
                Button {
                    store.unreadFilters.kind = kind
                } label: {
                    if store.unreadFilters.kind == kind {
                        Label(kind.title, systemImage: "checkmark")
                    } else {
                        Label(kind.title, systemImage: kind.systemImage)
                    }
                }
            }
        } label: {
            capsuleLabel(
                store.unreadFilters.kind == .all ? "Type" : store.unreadFilters.kind.title,
                systemImage: "bubble.left.and.bubble.right",
                isActive: store.unreadFilters.kind != .all
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var conversationMenu: some View {
        Menu {
            Button {
                store.unreadFilters.conversationIDs.removeAll()
            } label: {
                if store.unreadFilters.conversationIDs.isEmpty {
                    Label("All conversations", systemImage: "checkmark")
                } else {
                    Text("All conversations")
                }
            }
            Divider()
            ForEach(store.unreadConversations) { conversation in
                Toggle(
                    conversation.title,
                    isOn: selectionBinding(
                        for: conversation.id,
                        in: \.conversationIDs
                    )
                )
            }
        } label: {
            capsuleLabel(
                conversationMenuTitle,
                systemImage: "number",
                isActive: !store.unreadFilters.conversationIDs.isEmpty
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var conversationMenuTitle: String {
        let ids = store.unreadFilters.conversationIDs
        if ids.isEmpty {
            return "Conversation"
        }
        if ids.count == 1,
           let id = ids.first,
           let conversation = store.conversations.first(where: { $0.id == id })
        {
            return conversation.title
        }
        return "\(ids.count) conversations"
    }

    private var authorMenu: some View {
        Menu {
            Button {
                store.unreadFilters.authorIDs.removeAll()
            } label: {
                if store.unreadFilters.authorIDs.isEmpty {
                    Label("Everyone", systemImage: "checkmark")
                } else {
                    Text("Everyone")
                }
            }
            Divider()
            ForEach(store.unreadAuthors) { author in
                Toggle(
                    author.displayName,
                    isOn: selectionBinding(for: author.id, in: \.authorIDs)
                )
            }
        } label: {
            capsuleLabel(
                authorMenuTitle,
                systemImage: "person",
                isActive: !store.unreadFilters.authorIDs.isEmpty
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var authorMenuTitle: String {
        let ids = store.unreadFilters.authorIDs
        if ids.isEmpty {
            return "From"
        }
        if ids.count == 1,
           let id = ids.first,
           let author = store.unreadAuthors.first(where: { $0.id == id })
        {
            return author.displayName
        }
        return "\(ids.count) people"
    }

    private var whenControl: some View {
        Button {
            isWhenPopoverPresented.toggle()
        } label: {
            capsuleLabel(
                store.unreadFilters.timeRange.isActive
                    ? store.unreadFilters.timeRange.title : "When",
                systemImage: "clock",
                isActive: store.unreadFilters.timeRange.isActive
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isWhenPopoverPresented, arrowEdge: .bottom) {
            whenPopoverContent
        }
    }

    private var whenPopoverContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(UnreadTimeRange.presets, id: \.title) { preset in
                Button {
                    store.unreadFilters.timeRange = preset
                    isWhenPopoverPresented = false
                } label: {
                    HStack(spacing: 6) {
                        Image(
                            systemName: store.unreadFilters.timeRange == preset
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .foregroundStyle(
                            store.unreadFilters.timeRange == preset
                                ? Color.orange : Color.secondary
                        )
                        Text(preset.title)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()

            Text("Custom range")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            DatePicker(
                "From",
                selection: $customRangeStart,
                displayedComponents: [.date, .hourAndMinute]
            )
            DatePicker(
                "To",
                selection: $customRangeEnd,
                displayedComponents: [.date, .hourAndMinute]
            )
            HStack {
                if case .custom = store.unreadFilters.timeRange {
                    Button("Clear") {
                        store.unreadFilters.timeRange = .anyTime
                        isWhenPopoverPresented = false
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Apply") {
                    store.unreadFilters.timeRange = .custom(
                        start: min(customRangeStart, customRangeEnd),
                        end: max(customRangeStart, customRangeEnd)
                    )
                    isWhenPopoverPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private var mentionsToggle: some View {
        Button {
            store.unreadFilters.mentionsOnly.toggle()
        } label: {
            capsuleLabel(
                "Mentions",
                systemImage: "at",
                isActive: store.unreadFilters.mentionsOnly,
                showsChevron: false
            )
        }
        .buttonStyle(.plain)
        .help("Show only conversations with unread mentions")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(UnreadSortOrder.allCases) { order in
                Button {
                    store.unreadFilters.sortOrder = order
                } label: {
                    if store.unreadFilters.sortOrder == order {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } label: {
            capsuleLabel(
                store.unreadFilters.sortOrder.title,
                systemImage: "arrow.up.arrow.down",
                isActive: store.unreadFilters.sortOrder != .mentionsFirst
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort unread conversations")
    }

    private var clearButton: some View {
        Button {
            store.unreadFilters.clearActiveFilters()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear all filters")
    }

    private func selectionBinding(
        for id: String,
        in keyPath: WritableKeyPath<UnreadInboxFilters, Set<String>>
    ) -> Binding<Bool> {
        Binding(
            get: { store.unreadFilters[keyPath: keyPath].contains(id) },
            set: { isSelected in
                if isSelected {
                    store.unreadFilters[keyPath: keyPath].insert(id)
                } else {
                    store.unreadFilters[keyPath: keyPath].remove(id)
                }
            }
        )
    }

    private func capsuleLabel(
        _ title: String,
        systemImage: String,
        isActive: Bool,
        showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.7)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
        .foregroundStyle(isActive ? Color.orange : Color.secondary)
        .background(
            isActive
                ? AnyShapeStyle(Color.orange.opacity(0.15))
                : AnyShapeStyle(Color.primary.opacity(0.05)),
            in: Capsule()
        )
    }
}

private struct UnreadNoMatchesView: View {
    let clearFilters: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No unreads match these filters")
                .font(.headline)
            Text("Try a wider time range or different people.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Clear Filters", action: clearFilters)
                .buttonStyle(.bordered)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct UnreadCardRow: View {
    let store: AppStore
    let conversation: Conversation
    let compact: Bool
    let isKeyboardSelected: Bool
    @State private var isHovered = false

    private var showsActions: Bool {
        isHovered || isKeyboardSelected
    }

    var body: some View {
        Button {
            store.select(conversation.id)
        } label: {
            UnreadCard(
                store: store,
                conversation: conversation,
                compact: compact,
                isKeyboardSelected: isKeyboardSelected,
                showsActions: showsActions
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button {
                store.markConversationRead(conversation.id)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.orange)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(showsActions ? 1 : 0)
            .disabled(!showsActions)
            .help("Mark as read (R)")
            .accessibilityLabel("Mark \(conversation.title) as read")
            .padding(compact ? 7 : 10)
            .animation(.snappy(duration: 0.2), value: showsActions)
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open") {
                store.select(conversation.id)
            }
            Button("Mark as Read") {
                store.markConversationRead(conversation.id)
            }
        }
        .accessibilityHint("Return opens the conversation. Press R to mark it as read.")
    }
}

private struct UnreadCard: View {
    let store: AppStore
    let conversation: Conversation
    let compact: Bool
    let isKeyboardSelected: Bool
    let showsActions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(spacing: 8) {
                if conversation.isDirectMessage {
                    ConversationAvatar(store: store, conversation: conversation, size: 22)
                } else {
                    Image(systemName: conversation.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text(conversation.title)
                    .font(.headline)
                    .lineLimit(1)
                if conversation.mentionCount > 0 {
                    CountBadge(count: conversation.mentionCount, emphasized: true)
                }
                if conversation.unreadCount > 1 {
                    CountBadge(count: conversation.unreadCount)
                }
                Spacer()
                Text(conversation.latestActivity, style: .relative)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .opacity(showsActions ? 0 : 1)
                    .animation(.snappy(duration: 0.2), value: showsActions)
            }

            if let message = conversation.latestMessage {
                let user = message.authorUserID.flatMap(store.user(withID:))
                let displayName = user?.displayName ?? message.author

                HStack(alignment: .top, spacing: 8) {
                    UserAvatar(
                        imageURL: user?.avatarURL ?? message.authorAvatarURL,
                        initials: user?.initials ?? message.initials,
                        accessibilityName: displayName,
                        size: 24,
                        availability: user?.availability
                            ?? message.authorUserID.map { _ in UserAvailability() }
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if let integration = message.integration {
                                MessageIntegrationBadge(integration: integration)
                            }
                        }
                        Group {
                            if let richText = message.richText {
                                MessageRichTextView(
                                    document: richText,
                                    customEmojiURLs: store.customEmojiURLs
                                )
                            } else {
                                Text(message.compactPreviewText)
                            }
                        }
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
