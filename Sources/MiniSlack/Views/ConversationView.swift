import AppKit
import EmojiText
import SwiftUI

struct ConversationView: View {
    let store: AppStore
    let windowState: WindowState
    let compact: Bool
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @State private var findState = ConversationFindState()
    @State private var isFindPresented = false
    @FocusState private var isFindFieldFocused: Bool

    var body: some View {
        if let conversation = store.selectedConversation {
            Group {
                if compact,
                   let thread = windowState.selectedThread,
                   thread.conversationID == conversation.id
                {
                    ThreadPane(
                        store: store,
                        windowState: windowState,
                        identifier: thread,
                        compact: true
                    )
                } else {
                    HStack(spacing: 0) {
                        conversationContent(conversation)
                        if let thread = windowState.selectedThread,
                           thread.conversationID == conversation.id
                        {
                            Divider()
                            ThreadPane(
                                store: store,
                                windowState: windowState,
                                identifier: thread,
                                compact: false
                            )
                            .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .focusedSceneValue(
                \.conversationFindActions,
                ConversationFindActions(present: presentFind)
            )
            .onAppear {
                if markReadOnOpen {
                    store.markSelectedConversationRead()
                }
            }
            .task(id: conversation.id) {
                await store.loadInitialHistory(for: conversation.id)
            }
            .onChange(of: conversation.id) {
                dismissFind()
                windowState.dismissThread()
            }
            .onChange(of: conversation.messages.count) {
                findState.refresh(messages: conversation.messages)
            }
        } else {
            ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right")
        }
    }

    private func conversationContent(_ conversation: Conversation) -> some View {
        VStack(spacing: 0) {
            ConversationHeader(
                store: store,
                windowState: windowState,
                conversation: conversation,
                compact: compact
            )
            if isFindPresented {
                ConversationFindBar(
                    state: $findState,
                    messages: conversation.messages,
                    isFocused: $isFindFieldFocused,
                    dismiss: dismissFind
                )
            }
            MessageList(
                store: store,
                windowState: windowState,
                conversation: conversation,
                findState: findState,
                focusedMessageID: store.workspaceSearchFocus.flatMap {
                    $0.conversationID == conversation.id ? $0.messageID : nil
                }
            )
            .id(conversation.id)
            ComposerView(
                store: store,
                conversation: conversation,
                onEscape: handleEscape
            )
        }
    }

    private func presentFind() {
        isFindPresented = true
        Task { @MainActor in
            isFindFieldFocused = true
        }
    }

    private func dismissFind() {
        isFindFieldFocused = false
        isFindPresented = false
        findState.reset()
    }

    private func handleEscape() {
        if isFindPresented {
            dismissFind()
            return
        }
        if windowState.selectedThread != nil {
            windowState.dismissThread()
            return
        }
        store.showUnreadInbox()
    }
}

private struct ConversationFindBar: View {
    @Binding var state: ConversationFindState
    let messages: [Message]
    @FocusState.Binding var isFocused: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(
                "Find in conversation",
                text: Binding(
                    get: { state.query },
                    set: { state.update(query: $0, messages: messages) }
                )
            )
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit {
                state.moveSelection(offset: 1)
            }
            .onKeyPress(.downArrow) {
                state.moveSelection(offset: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                state.moveSelection(offset: -1)
                return .handled
            }
            .onKeyPress(.escape) {
                dismiss()
                return .handled
            }

            if state.isSearching {
                Text(resultLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }

            Button {
                state.moveSelection(offset: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(state.matchIDs.isEmpty)
            .help("Previous result (↑)")
            .accessibilityLabel("Previous find result")

            Button {
                state.moveSelection(offset: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(state.matchIDs.isEmpty)
            .help("Next result (↓ or Return)")
            .accessibilityLabel("Next find result")

            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close find (Esc)")
            .accessibilityLabel("Close conversation find")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var resultLabel: String {
        guard let selectedResultNumber = state.selectedResultNumber else {
            return "No matches"
        }
        return "\(selectedResultNumber) of \(state.matchIDs.count)"
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
                .help("Back to unreads (Esc)")
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

            if compact {
                ConversationManagementMenu(store: store)
            }

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
    let windowState: WindowState
    let conversation: Conversation
    let findState: ConversationFindState
    let focusedMessageID: UUID?
    @State private var scrollState = ConversationScrollState()

    private static let bottomAnchorID = "conversation-bottom"
    private static let scrollCoordinateSpace = "conversation-message-list"

    var body: some View {
        let historyState = store.historyState(for: conversation.id)
        let matchingIDs = Set(findState.matchIDs)
        let displayedMessages = findState.isSearching
            ? conversation.messages.filter { matchingIDs.contains($0.id) }
            : conversation.messages

        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !findState.isSearching,
                           historyState.canLoadOlder || historyState.isLoadingOlder
                        {
                            OlderHistoryBoundary(
                                isLoading: historyState.isLoadingOlder,
                                positionedAtBottom: scrollState.hasPositionedInitially
                            ) {
                                store.loadOlderMessages(for: conversation.id)
                            }
                        }

                        if !findState.isSearching,
                           let errorMessage = historyState.errorMessage
                        {
                            HistoryErrorRow(message: errorMessage) {
                                store.retryHistory(for: conversation.id)
                            }
                        }

                        ForEach(displayedMessages) { message in
                            MessageRow(
                                store: store,
                                conversationID: conversation.id,
                                message: message,
                                customEmojiURLs: store.customEmojiURLs,
                                openThread: {
                                    if let identifier = try? store.prepareThread(
                                        conversationID: conversation.id,
                                        messageID: message.id
                                    ) {
                                        windowState.presentThread(identifier)
                                    }
                                }
                            )
                            .background {
                                if findState.isSearching || message.id == focusedMessageID {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(
                                            Color.accentColor.opacity(
                                                message.id == findState.selectedMessageID
                                                    || message.id == focusedMessageID
                                                    ? 0.18 : 0.07
                                            )
                                        )
                                        .padding(.horizontal, 6)
                                }
                            }
                            .overlay {
                                if message.id == findState.selectedMessageID
                                    || message.id == focusedMessageID
                                {
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(Color.accentColor.opacity(0.45))
                                        .padding(.horizontal, 6)
                                }
                            }
                            .id(message.id)
                        }

                        if findState.isSearching, displayedMessages.isEmpty {
                            ContentUnavailableView(
                                "No matches",
                                systemImage: "magnifyingglass",
                                description: Text("Only loaded messages are searched.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else if conversation.messages.isEmpty,
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

                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: MessageListBottomOffsetKey.self,
                                        value: geometry.frame(
                                            in: .named(Self.scrollCoordinateSpace)
                                        ).minY
                                    )
                                }
                            }
                    }
                    .padding(.vertical, 10)
                }
                .coordinateSpace(name: Self.scrollCoordinateSpace)
                .overlay {
                    if historyState.isLoadingInitial && conversation.messages.isEmpty {
                        ProgressView("Loading recent messages…")
                            .controlSize(.small)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if scrollState.showsJumpToBottom(
                        hasMessages: !conversation.messages.isEmpty,
                        isSearching: findState.isSearching
                    ) {
                        Button {
                            scrollState.didJumpToBottom()
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.callout.weight(.semibold))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .background(.regularMaterial, in: Circle())
                        .overlay {
                            Circle()
                                .stroke(.separator.opacity(0.8), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                        .padding(12)
                        .help("Jump to latest message")
                        .accessibilityLabel("Jump to latest message")
                    }
                }
                .onPreferenceChange(MessageListBottomOffsetKey.self) { offset in
                    scrollState.updateBottomVisibility(
                        offset <= viewport.size.height + 8
                    )
                }
                .onAppear {
                    scrollOnConversationFocus(proxy: proxy)
                }
                .onDisappear {
                    if store.workspaceSearchFocus?.conversationID == conversation.id {
                        store.workspaceSearchFocus = nil
                    }
                }
                .onChange(of: conversation.id) {
                    scrollOnConversationFocus(proxy: proxy)
                }
                .onChange(of: historyState.hasLoadedInitial) {
                    if !scrollState.hasPositionedInitially {
                        scrollOnConversationFocus(proxy: proxy)
                    } else {
                        followLatestIfNeeded(proxy: proxy)
                    }
                }
                .onChange(of: conversation.messages.last?.id) {
                    if !scrollState.hasPositionedInitially {
                        scrollOnConversationFocus(proxy: proxy)
                    } else {
                        followLatestIfNeeded(proxy: proxy)
                    }
                }
                .onChange(of: conversation.messages.count) {
                    // Older history prepends change the count without changing the
                    // latest message id; re-anchor so focus stays on the bottom.
                    followLatestIfNeeded(proxy: proxy)
                }
                .onChange(of: findState.selectedMessageID) {
                    if let selectedMessageID = findState.selectedMessageID {
                        proxy.scrollTo(selectedMessageID, anchor: .center)
                    }
                }
                .onChange(of: focusedMessageID) {
                    if focusedMessageID != nil {
                        scrollOnConversationFocus(proxy: proxy)
                    }
                }
            }
        }
    }

    private func scrollOnConversationFocus(proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            applyFocusScroll(proxy: proxy)
            // LazyVStack often needs a second layout pass before scrollTo sticks.
            await Task.yield()
            applyFocusScroll(proxy: proxy)
        }
    }

    private func applyFocusScroll(proxy: ScrollViewProxy) {
        switch scrollState.focusTarget(
            lastMessageID: conversation.messages.last?.id,
            focusedMessageID: focusedMessageID
        ) {
        case let .message(messageID):
            proxy.scrollTo(messageID, anchor: .center)
        case .bottom:
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        case nil:
            break
        }
    }

    private func followLatestIfNeeded(proxy: ScrollViewProxy) {
        guard scrollState.shouldFollowLatest(isSearching: findState.isSearching) else {
            return
        }
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    }
}

private struct MessageListBottomOffsetKey: PreferenceKey {
    static let defaultValue = CGFloat.infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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

struct MessageRow: View {
    let store: AppStore
    let conversationID: String
    let message: Message
    let customEmojiURLs: [String: URL]
    var showsThreadAction = true
    var threadIdentifier: ThreadIdentifier?
    var openThread: (() -> Void)?
    @State private var actionError: String?

    var body: some View {
        let user = message.authorUserID.flatMap(store.user(withID:))
        let displayName = user?.displayName ?? message.author
        let mutationState = store.messageMutationDisplayState(
            conversationID: conversationID,
            message: message,
            threadIdentifier: threadIdentifier
        )

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
                    if let integration = message.integration {
                        MessageIntegrationBadge(integration: integration)
                    }
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    if message.editedAt != nil {
                        Text("(edited)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if message.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Pinned")
                    }
                    if store.isMessageSaved(
                        conversationID: conversationID,
                        message: message
                    ) {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Saved on this Mac")
                    }
                    deliveryIndicator
                }

                if let mutationState {
                    messageMutationIndicator(mutationState)
                }

                if message.richText != nil || !message.displayBody.isEmpty {
                    Group {
                        if let richText = message.richText {
                            MessageRichTextView(
                                document: richText,
                                customEmojiURLs: customEmojiURLs
                            )
                        } else {
                            SlackEmojiText(
                                text: message.displayBody,
                                customEmojiURLs: customEmojiURLs
                            )
                        }
                    }
                        .font(.callout)
                        .foregroundStyle(message.isDeleted ? .secondary : .primary)
                        .italic(message.isDeleted)
                        .textSelection(.enabled)
                }

                if !message.isDeleted, let context = message.context {
                    MessageRichTextView(
                        document: context,
                        customEmojiURLs: customEmojiURLs
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }

                if !message.isDeleted,
                   (
                       !message.attachments.isEmpty
                           || !message.files.isEmpty
                           || !message.images.isEmpty
                   )
                {
                    MessageMediaView(
                        message: message,
                        customEmojiURLs: customEmojiURLs
                    )
                }

                if !message.reactions.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(message.reactions, id: \.self) { reaction in
                            MessageReactionChip(
                                store: store,
                                reaction: reaction,
                                customEmojiURLs: customEmojiURLs,
                                isDisabled: reaction.name.isEmpty || message.remoteID == nil
                            ) {
                                perform {
                                    try await store.toggleReaction(
                                        named: reaction.name,
                                        conversationID: conversationID,
                                        messageID: message.id,
                                        threadIdentifier: threadIdentifier
                                    )
                                }
                            }
                        }
                    }
                }

                if showsThreadAction,
                   let thread = message.thread,
                   thread.replyCount > 0
                {
                    Button(action: { openThread?() }) {
                        MessageThreadSummary(store: store, thread: thread)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            if showsThreadAction, !message.isDeleted, message.remoteID != nil {
                Button("Reply in Thread", systemImage: "bubble.left.and.bubble.right") {
                    openThread?()
                }
            }

            if !message.isDeleted, message.remoteID != nil {
                Menu("Add Reaction", systemImage: "face.smiling") {
                    ForEach(Self.quickReactions, id: \.name) { reaction in
                        Button("\(reaction.emoji)  \(reaction.name)") {
                            perform {
                                try await store.toggleReaction(
                                    named: reaction.name,
                                    conversationID: conversationID,
                                    messageID: message.id,
                                    threadIdentifier: threadIdentifier
                                )
                            }
                        }
                    }
                }
            }

            Button("Copy Text", systemImage: "doc.on.doc") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(message.copyText, forType: .string)
            }

            Button(
                store.isMessageSaved(
                    conversationID: conversationID,
                    message: message
                )
                    ? "Remove from Saved"
                    : "Save on This Mac",
                systemImage: store.isMessageSaved(
                    conversationID: conversationID,
                    message: message
                )
                    ? "bookmark.slash"
                    : "bookmark"
            ) {
                perform {
                    try store.toggleSavedMessage(
                        conversationID: conversationID,
                        messageID: message.id,
                        threadIdentifier: threadIdentifier
                    )
                }
            }

            if message.remoteID != nil {
                Button("Copy Slack Link", systemImage: "link") {
                    perform {
                        guard let url = try await store.messagePermalink(
                            conversationID: conversationID,
                            messageID: message.id,
                            threadIdentifier: threadIdentifier
                        ) else {
                            return
                        }
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(url.absoluteString, forType: .string)
                    }
                }

                Button(
                    message.isPinned ? "Unpin Message" : "Pin Message",
                    systemImage: message.isPinned ? "pin.slash" : "pin"
                ) {
                    perform {
                        try await store.setMessagePinned(
                            !message.isPinned,
                            conversationID: conversationID,
                            messageID: message.id,
                            threadIdentifier: threadIdentifier
                        )
                    }
                }

                Menu("Remind Me", systemImage: "clock") {
                    Button("In 20 minutes") {
                        remind(after: 20 * 60)
                    }
                    Button("In 1 hour") {
                        remind(after: 60 * 60)
                    }
                    Button("Tomorrow morning") {
                        remindTomorrow()
                    }
                }
            }

            if message.isCurrentUser, !message.isDeleted {
                Divider()
                Button("Edit Message", systemImage: "pencil") {
                    edit()
                }
                .disabled(mutationState != nil)
                Button("Delete Message", systemImage: "trash", role: .destructive) {
                    delete()
                }
                .disabled(mutationState != nil)
            }

            if let mutationState {
                Button(
                    retryMutationLabel(for: mutationState),
                    systemImage: "arrow.clockwise"
                ) {
                    perform {
                        try await store.retryMessageMutation(
                            conversationID: conversationID,
                            messageID: message.id
                        )
                    }
                }
            }

            if case .failed = message.deliveryState {
                Button("Retry Sending", systemImage: "arrow.clockwise") {
                    perform {
                        try await store.retryMessage(
                            conversationID: conversationID,
                            messageID: message.id,
                            threadIdentifier: threadIdentifier
                        )
                    }
                }
            }
        }
        .alert(
            "Slack action failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private var deliveryIndicator: some View {
        switch message.deliveryState {
        case .sending:
            ProgressView()
                .controlSize(.mini)
                .help("Sending")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help("Message failed to send")
        case .received, .sent:
            EmptyView()
        }
    }

    private func messageMutationIndicator(
        _ state: MessageMutationDisplayState
    ) -> some View {
        Label(
            state.label,
            systemImage: mutationIcon(for: state)
        )
        .font(.caption2)
        .foregroundStyle(mutationColor(for: state))
        .help(state.detail)
    }

    private func mutationIcon(
        for state: MessageMutationDisplayState
    ) -> String {
        switch state {
        case .pending:
            "clock.arrow.circlepath"
        case .failed:
            "exclamationmark.circle.fill"
        case .conflict:
            "arrow.triangle.branch"
        }
    }

    private func mutationColor(
        for state: MessageMutationDisplayState
    ) -> Color {
        switch state {
        case .pending:
            .secondary
        case .failed:
            .red
        case .conflict:
            .orange
        }
    }

    private func retryMutationLabel(
        for state: MessageMutationDisplayState
    ) -> String {
        switch state {
        case let .conflict(action, _):
            "Retry \(action) Using Current Version"
        case let .pending(action), let .failed(action, _):
            "Retry \(action) Now"
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func edit() {
        guard let text = MessageActionPrompts.editedText(current: message.body) else {
            return
        }
        perform {
            try await store.editMessage(
                conversationID: conversationID,
                messageID: message.id,
                text: text,
                threadIdentifier: threadIdentifier
            )
        }
    }

    private func delete() {
        guard MessageActionPrompts.confirmsDelete() else {
            return
        }
        perform {
            try await store.deleteMessage(
                conversationID: conversationID,
                messageID: message.id,
                threadIdentifier: threadIdentifier
            )
        }
    }

    private func remind(after seconds: TimeInterval) {
        perform {
            try await store.addMessageReminder(
                conversationID: conversationID,
                messageID: message.id,
                at: Date().addingTimeInterval(seconds),
                threadIdentifier: threadIdentifier
            )
        }
    }

    private func remindTomorrow() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        let date = calendar.date(
            bySettingHour: 9,
            minute: 0,
            second: 0,
            of: tomorrow
        ) ?? tomorrow
        perform {
            try await store.addMessageReminder(
                conversationID: conversationID,
                messageID: message.id,
                at: date,
                threadIdentifier: threadIdentifier
            )
        }
    }

    private static let quickReactions = [
        (name: "thumbsup", emoji: "👍"),
        (name: "heart", emoji: "❤️"),
        (name: "joy", emoji: "😂"),
        (name: "tada", emoji: "🎉"),
        (name: "eyes", emoji: "👀"),
        (name: "white_check_mark", emoji: "✅"),
    ]
}

private struct MessageThreadSummary: View {
    let store: AppStore
    let thread: MessageThreadMetadata

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -5) {
                ForEach(Array(thread.replyUserIDs.prefix(3)), id: \.self) { userID in
                    let user = store.user(withID: userID)
                    UserAvatar(
                        imageURL: user?.avatarURL,
                        initials: user?.initials ?? "?",
                        accessibilityName: user?.displayName ?? "Thread participant",
                        size: 18,
                        availability: user?.availability
                    )
                    .overlay {
                        Circle().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 1)
                    }
                }
            }
            Text("\(thread.replyCount) \(thread.replyCount == 1 ? "reply" : "replies")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if let latestReplyAt = thread.latestReplyAt {
                Text(latestReplyAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if thread.isFollowing {
                Image(systemName: "bell.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct MessageReactionChip: View {
    let store: AppStore
    let reaction: Reaction
    let customEmojiURLs: [String: URL]
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHoveringChip = false
    @State private var isHoveringPopover = false

    private var isPopoverPresented: Binding<Bool> {
        Binding(
            get: { isHoveringChip || isHoveringPopover },
            set: { presented in
                if !presented {
                    isHoveringChip = false
                    isHoveringPopover = false
                }
            }
        )
    }

    private var summary: String {
        reaction.hoverSummary { userID in
            store.user(withID: userID)?.displayName
        }
    }

    var body: some View {
        // Avoid `.disabled` so hover still presents the reactors list.
        Button {
            guard !isDisabled else { return }
            action()
        } label: {
            SlackEmojiText(
                text: "\(reaction.emoji) \(reaction.count)",
                customEmojiURLs: customEmojiURLs
            )
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                reaction.isCurrentUserIncluded
                    ? Color.orange.opacity(0.18)
                    : Color(nsColor: .quaternaryLabelColor)
                        .opacity(0.12),
                in: Capsule()
            )
            .overlay {
                if reaction.isCurrentUserIncluded {
                    Capsule()
                        .stroke(.orange.opacity(0.55), lineWidth: 0.5)
                }
            }
            .opacity(isDisabled ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHoveringChip = hovering
        }
        .popover(isPresented: isPopoverPresented, arrowEdge: .bottom) {
            MessageReactionReactorsPopover(
                store: store,
                reaction: reaction,
                customEmojiURLs: customEmojiURLs
            )
            .onHover { hovering in
                isHoveringPopover = hovering
            }
        }
        .help(summary)
        .accessibilityLabel(summary)
        .accessibilityHint(isDisabled ? "" : "Toggle this reaction")
    }
}

private struct MessageReactionReactorsPopover: View {
    let store: AppStore
    let reaction: Reaction
    let customEmojiURLs: [String: URL]

    private var reactors: [(id: String, user: WorkspaceUser?)] {
        if reaction.userIDs.isEmpty {
            return []
        }
        return reaction.userIDs.map { userID in
            (id: userID, user: store.user(withID: userID))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SlackEmojiText(
                    text: reaction.emoji,
                    customEmojiURLs: customEmojiURLs
                )
                .font(.title3)
                Text(headerText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if reactors.isEmpty {
                Text(emptyStateText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(reactors, id: \.id) { reactor in
                            HStack(spacing: 8) {
                                UserAvatar(
                                    imageURL: reactor.user?.avatarURL,
                                    initials: reactor.user?.initials ?? "?",
                                    accessibilityName: displayName(for: reactor),
                                    size: 22,
                                    availability: reactor.user?.availability
                                )
                                Text(displayName(for: reactor))
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: scrollMaxHeight)
            }
        }
        .padding(10)
        .frame(minWidth: 160, idealWidth: 200, maxWidth: 260, alignment: .leading)
    }

    private var headerText: String {
        if reaction.count == 1 {
            return "reacted"
        }
        return "\(reaction.count) reactions"
    }

    private var emptyStateText: String {
        if reaction.count <= 1 {
            return "1 person reacted"
        }
        return "\(reaction.count) people reacted"
    }

    private var scrollMaxHeight: CGFloat {
        // Roughly 6 rows before scrolling.
        min(CGFloat(reactors.count) * 28, 168)
    }

    private func displayName(
        for reactor: (id: String, user: WorkspaceUser?)
    ) -> String {
        let resolved = reactor.user?.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolved, !resolved.isEmpty {
            return resolved
        }
        return reactor.id
    }
}

@MainActor
private enum MessageActionPrompts {
    static func editedText(current: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = current
        field.selectText(nil)

        let alert = NSAlert()
        alert.messageText = "Edit message"
        alert.informativeText = "Update the message text."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
            ? field.stringValue
            : nil
    }

    static func confirmsDelete() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete this message?"
        alert.informativeText = "This removes the message for everyone in Slack."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct SlackEmojiText: View {
    let text: String
    let customEmojiURLs: [String: URL]

    var body: some View {
        let customEmoji = Set(SlackEmoji.shortcodeNames(in: text)).compactMap { name in
            customEmojiURLs[name].map { RemoteEmoji(shortcode: name, url: $0) }
        }
        EmojiText(verbatim: text, emojis: customEmoji)
    }
}
