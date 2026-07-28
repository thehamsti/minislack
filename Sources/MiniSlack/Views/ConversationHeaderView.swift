import SwiftUI

/// Toolbar above a conversation: identity on the left, a fixed-width action
/// cluster on the right. The row keeps one height in both window sizes so it
/// lines up with the thread pane header beside it.
struct ConversationHeader: View {
    static let height: CGFloat = 46

    let store: AppStore
    let windowState: WindowState
    let conversation: Conversation
    let compact: Bool
    let presentFind: () -> Void
    @Environment(KeyboardShortcutStore.self) private var shortcuts

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            if compact {
                Button {
                    store.showUnreadInbox()
                } label: {
                    Image(systemName: "chevron.left")
                        .headerControlChrome()
                }
                .buttonStyle(.plain)
                .help("Back to unreads (Esc)")
                .accessibilityLabel("Back to unreads")

                CompactSidebarButton(windowState: windowState)
            }

            identity

            Spacer(minLength: 8)

            actions
        }
        .padding(.horizontal, compact ? 10 : 14)
        .frame(height: Self.height)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var identity: some View {
        HStack(spacing: 8) {
            avatar

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(conversation.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if conversation.kind == .channel, conversation.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .help("Private channel")
                    }

                    if store.isConversationMuted(conversation.id) {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .help("Notifications muted")
                    }
                }

                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .layoutPriority(1)
    }

    private var avatar: some View {
        Group {
            if conversation.isDirectMessage {
                ConversationAvatar(store: store, conversation: conversation, size: 26)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    Image(systemName: conversation.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 26, height: 26)
            }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let userID = conversation.participantUserID,
           let user = store.user(withID: userID)
        {
            UserStatusLabel(
                user: user,
                customEmojiURLs: store.customEmojiURLs
            )
        } else if let detail = subtitleText {
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(detail)
        }
    }

    private var subtitleText: String? {
        for candidate in [conversation.subtitle, conversation.topic, conversation.purpose] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private var actions: some View {
        HStack(spacing: 2) {
            UnreadNotificationBell(
                store: store,
                compact: compact,
                isPresented: Binding(
                    get: { windowState.isUnreadNotificationsPresented },
                    set: { windowState.isUnreadNotificationsPresented = $0 }
                )
            )

            if compact {
                ConversationManagementMenu(store: store)
                    .menuIndicator(.hidden)
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(width: 26, height: 26)
            } else {
                Button(action: presentFind) {
                    Image(systemName: "text.magnifyingglass")
                        .headerControlChrome()
                }
                .buttonStyle(.plain)
                .help("Find in conversation\(shortcutHint(.findInConversation))")
                .accessibilityLabel("Find in conversation")

                Button {
                    windowState.presentQuickSwitcher()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .headerControlChrome()
                }
                .buttonStyle(.plain)
                .help("Quick switcher\(shortcutHint(.quickSwitcher))")
                .accessibilityLabel("Quick switcher")
            }

            overflowMenu
        }
        .fixedSize()
    }

    /// " (⇧⌘N)" for a bound command, empty when the user cleared it.
    private func shortcutHint(_ command: KeyboardCommand) -> String {
        guard let binding = shortcuts.binding(for: command) else {
            return ""
        }
        return " (\(binding.displayString))"
    }

    private var overflowMenu: some View {
        Menu {
            if compact {
                Button("Find in Conversation…", systemImage: "text.magnifyingglass") {
                    presentFind()
                }
                Button("Quick Switcher…", systemImage: "magnifyingglass") {
                    windowState.presentQuickSwitcher()
                }
            }
            Button("Search Workspace…", systemImage: "sparkle.magnifyingglass") {
                windowState.presentWorkspaceSearch()
            }

            Divider()

            Button("Mark as Read", systemImage: "checkmark.circle") {
                store.markConversationRead(conversation.id)
            }
            .disabled(!conversation.isUnread)

            Button(
                store.isConversationMuted(conversation.id)
                    ? "Unmute Notifications"
                    : "Mute Notifications",
                systemImage: store.isConversationMuted(conversation.id)
                    ? "speaker.wave.2"
                    : "speaker.slash"
            ) {
                store.toggleConversationMute(conversation.id)
            }

            Divider()

            Button("Unread Inbox", systemImage: "tray.full") {
                store.showUnreadInbox()
            }
        } label: {
            Image(systemName: "ellipsis")
                .headerControlChrome()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More conversation actions")
        .accessibilityLabel("More conversation actions")
    }
}

/// Bell with an unread badge; opens a dropdown of unread messages that jump
/// straight to their conversation.
private struct UnreadNotificationBell: View {
    let store: AppStore
    let compact: Bool
    @Binding var isPresented: Bool
    @Environment(KeyboardShortcutStore.self) private var shortcuts

    var body: some View {
        let counts = store.unreadNotificationCounts
        let hint = shortcuts.binding(for: .unreadNotifications)
            .map { " (\($0.displayString))" } ?? ""

        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: bellSystemImage(for: counts))
                .headerControlChrome(isActive: counts.messageCount > 0)
                .overlay(alignment: .topTrailing) {
                    if let badgeLabel = counts.badgeLabel {
                        Text(badgeLabel)
                            .font(.system(size: 9, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1)
                            .frame(minWidth: 14)
                            .background(.orange, in: Capsule())
                            .overlay {
                                Capsule()
                                    .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
                            }
                            .offset(x: 6, y: -3)
                            .allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("\(counts.summary)\(hint)")
        .accessibilityLabel(counts.accessibilityLabel)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            UnreadNotificationList(store: store, compact: compact) {
                isPresented = false
            }
        }
    }

    /// The numeric badge already carries the count, so the symbol stays solid
    /// instead of doubling up with `bell.badge.fill`.
    private func bellSystemImage(for counts: UnreadNotificationDigest) -> String {
        counts.messageCount > 0 ? "bell.fill" : "bell"
    }
}

private struct UnreadNotificationList: View {
    let store: AppStore
    let compact: Bool
    let dismiss: () -> Void
    @Environment(KeyboardShortcutStore.self) private var shortcuts
    @State private var isMarkAllConfirmationPresented = false

    var body: some View {
        let digest = store.makeUnreadNotificationDigest()

        VStack(spacing: 0) {
            header(digest)
            Divider()
            if digest.entries.isEmpty {
                emptyState(digest)
            } else {
                entryList(digest)
            }
            Divider()
            footer(digest)
        }
        .frame(width: compact ? 300 : 364)
    }

    private func header(_ digest: UnreadNotificationDigest) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Unread messages")
                    .font(.subheadline.weight(.semibold))
                Text(digest.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button("Mark all read") {
                isMarkAllConfirmationPresented = true
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(digest.messageCount > 0 ? Color.orange : Color.secondary)
            .disabled(digest.messageCount == 0)
            .help("Mark every unread conversation as read")
            .confirmationDialog(
                "Mark \(digest.conversationCount) \(digest.conversationCount == 1 ? "conversation" : "conversations") as read?",
                isPresented: $isMarkAllConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Mark as Read") {
                    store.markAllUnreadsRead()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every unread conversation is marked as read and synced to Slack. You can’t undo this.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func emptyState(_ digest: UnreadNotificationDigest) -> some View {
        VStack(spacing: 6) {
            Image(systemName: digest.messageCount > 0 ? "clock.arrow.circlepath" : "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(digest.messageCount > 0 ? Color.secondary : Color.orange)
            Text(digest.messageCount > 0 ? "Unread messages aren’t loaded yet" : "You’re all caught up")
                .font(.callout.weight(.medium))
            Text(
                digest.messageCount > 0
                    ? "Open the conversation to load them."
                    : "New unread messages will show up here."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 26)
    }

    private func entryList(_ digest: UnreadNotificationDigest) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(digest.entries) { entry in
                    UnreadNotificationRow(
                        entry: entry,
                        open: {
                            store.openUnreadNotification(entry)
                            dismiss()
                        },
                        markRead: {
                            store.markUnreadNotificationRead(entry)
                        }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: compact ? 280 : 340)
    }

    private func footer(_ digest: UnreadNotificationDigest) -> some View {
        HStack(spacing: 8) {
            Button {
                store.showUnreadInbox()
                dismiss()
            } label: {
                Label("Open Unread Inbox", systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.orange)
            .help(
                shortcuts.binding(for: .unreadInbox)
                    .map { "Show the unread inbox (\($0.displayString))" }
                    ?? "Show the unread inbox"
            )

            Spacer(minLength: 4)

            if digest.hiddenMessageCount > 0 {
                Text("+\(digest.hiddenMessageCount) more")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct UnreadNotificationRow: View {
    let entry: UnreadNotificationEntry
    let open: () -> Void
    let markRead: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 9) {
                UserAvatar(
                    imageURL: entry.authorAvatarURL,
                    initials: entry.authorInitials,
                    accessibilityName: entry.authorDisplayName,
                    size: 26
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(entry.authorDisplayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)

                        HStack(spacing: 3) {
                            Image(systemName: entry.conversationSystemImage)
                                .font(.system(size: 8, weight: .semibold))
                            Text(entry.conversationTitle)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)

                        Spacer(minLength: 4)

                        if entry.isMention {
                            Image(systemName: "at")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.orange)
                                .help("Mentions you")
                                .opacity(isHovering ? 0 : 1)
                        }

                        Text(UnreadNotificationDigest.shortRelativeLabel(for: entry.timestamp))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                            .help(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .opacity(isHovering ? 0 : 1)
                    }

                    Text(entry.preview)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: markRead) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.orange)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .disabled(!isHovering)
            .help("Mark as read through this message")
            .accessibilityLabel("Mark as read")
            .accessibilityHint("Marks this conversation read through this message")
            .padding(.top, 4)
            .padding(.trailing, 5)
            .animation(.snappy(duration: 0.15), value: isHovering)
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open", action: open)
            Button("Mark as Read", action: markRead)
        }
        .accessibilityLabel(
            "\(entry.authorDisplayName) in \(entry.conversationTitle): \(entry.preview)"
        )
        .accessibilityHint("Opens this message")
    }
}

private struct HeaderControlChrome: ViewModifier {
    let isActive: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(isActive ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.09 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

extension View {
    /// Uniform 26×26 hit target and hover treatment for header controls.
    func headerControlChrome(isActive: Bool = false) -> some View {
        modifier(HeaderControlChrome(isActive: isActive))
    }
}
