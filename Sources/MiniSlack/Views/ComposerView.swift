import EmojiText
import Foundation
import SwiftUI

struct ComposerView: View {
    let store: AppStore
    let conversation: Conversation
    var onEscape: (() -> Void)? = nil
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editorHeight: CGFloat = 24
    @State private var selectedSuggestionIndex = 0
    @State private var dismissedQuery: ComposerQuery?
    @State private var isSchedulePopoverPresented = false
    @State private var isScheduledMessagesPresented = false
    @State private var isDropTargeted = false
    @State private var isEditorFocused = false
    @State private var isFormattingHovered = false
    @State private var isSendHovered = false

    var body: some View {
        let draft = store.composerDraft
        let attachmentState = store.attachmentDraftState(for: conversation.id)
        let query = draft.query(at: selection)
        let suggestions: [ComposerSuggestion] = query.map { query in
            if query.kind == .emoji {
                ComposerSuggestionIndex.emojiMatches(
                    query: query,
                    customEmojiURLs: store.customEmojiURLs
                )
            } else {
                store.composerSuggestions(
                    for: query,
                    allowsBroadcasts: conversation.kind == .channel
                )
            }
        } ?? []
        let suggestionsVisible = query != nil
            && query != dismissedQuery
            && !suggestions.isEmpty
        let suggestionPopupHeight = CGFloat(suggestions.count) * 38 + 30

        VStack(spacing: 0) {
            Divider()
            composerCard(
                draft: draft,
                attachmentState: attachmentState,
                query: query,
                suggestions: suggestions,
                suggestionsVisible: suggestionsVisible
            )
        }
        .background(.bar)
        .overlay(alignment: .topLeading) {
            if suggestionsVisible {
                ComposerSuggestionList(
                    store: store,
                    suggestions: suggestions,
                    selectedIndex: min(
                        selectedSuggestionIndex,
                        suggestions.count - 1
                    ),
                    select: { index in
                        selectedSuggestionIndex = index
                        acceptSuggestion(from: suggestions, query: query)
                    },
                    hover: { selectedSuggestionIndex = $0 }
                )
                .padding(.horizontal, 10)
                .frame(height: suggestionPopupHeight)
                .offset(y: -suggestionPopupHeight - 8)
                .transition(.opacity)
            }
        }
        .zIndex(10)
        .onAppear {
            moveCaretToDraftEnd()
        }
        .onChange(of: conversation.id) {
            dismissedQuery = nil
            selectedSuggestionIndex = 0
            moveCaretToDraftEnd()
        }
        .onChange(of: query) {
            selectedSuggestionIndex = 0
        }
        .sheet(isPresented: $isScheduledMessagesPresented) {
            ScheduledMessagesView(store: store, conversation: conversation)
        }
    }

    private func composerCard(
        draft: ComposerDraft,
        attachmentState: ComposerAttachmentDraftState,
        query: ComposerQuery?,
        suggestions: [ComposerSuggestion],
        suggestionsVisible: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachmentState.isEmpty {
                ComposerAttachmentTray(
                    state: attachmentState,
                    remove: {
                        store.removeComposerAttachment(
                            $0,
                            from: conversation.id
                        )
                    },
                    dismissError: {
                        store.dismissComposerAttachmentError(
                            for: conversation.id
                        )
                    }
                )
            }
            composerControlRow(
                draft: draft,
                attachmentState: attachmentState,
                query: query,
                suggestions: suggestions,
                suggestionsVisible: suggestionsVisible
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isDropTargeted
                        ? Color.orange
                        : isEditorFocused
                            ? Color.primary.opacity(0.3)
                            : Color(nsColor: .separatorColor),
                    lineWidth: isDropTargeted ? 1.5 : 0.5
                )
                .animation(.easeInOut(duration: 0.15), value: isEditorFocused)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else {
                return false
            }
            store.addComposerAttachments(urls, to: conversation.id)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .padding(10)
    }

    private func composerControlRow(
        draft: ComposerDraft,
        attachmentState: ComposerAttachmentDraftState,
        query: ComposerQuery?,
        suggestions: [ComposerSuggestion],
        suggestionsVisible: Bool
    ) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            HStack(spacing: 2) {
                formattingMenu

                ComposerIconButton(
                    systemImage: "paperclip",
                    help: "Attach files",
                    isEnabled: !attachmentState.isUploading,
                    action: chooseFiles
                )
            }

            composerEditor(
                draft: draft,
                query: query,
                suggestions: suggestions,
                suggestionsVisible: suggestionsVisible
            )

            HStack(spacing: 2) {
                scheduleButton
                sendButton
            }
        }
    }

    private var formattingMenu: some View {
        Menu {
            ForEach(ComposerFormatting.allCases) { formatting in
                Button(formatting.title, systemImage: formatting.systemImage) {
                    applyFormatting(formatting)
                }
            }
        } label: {
            Image(systemName: "textformat")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Color.primary.opacity(isFormattingHovered ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isFormattingHovered = hovering
            }
        }
        .help("Format message")
        .accessibilityLabel("Format message")
    }

    private func composerEditor(
        draft: ComposerDraft,
        query: ComposerQuery?,
        suggestions: [ComposerSuggestion],
        suggestionsVisible: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if draft.text.isEmpty {
                Text(composerPlaceholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }

            ComposerTextView(
                draft: Binding(
                    get: { store.composerDraft },
                    set: { store.composerDraft = $0 }
                ),
                selection: $selection,
                height: $editorHeight,
                suggestionsVisible: suggestionsVisible,
                accessibilityLabel: "Message \(conversation.title)",
                pasteAttachments: {
                    store.addComposerPasteboardAttachments(
                        $0,
                        to: conversation.id
                    )
                },
                moveSuggestion: { offset in
                    moveSuggestion(by: offset, count: suggestions.count)
                },
                acceptSuggestion: {
                    acceptSuggestion(from: suggestions, query: query)
                },
                dismissSuggestions: {
                    dismissedQuery = query
                },
                format: applyFormatting,
                send: send,
                onEscape: onEscape,
                focusChanged: { isEditorFocused = $0 }
            )
            .frame(height: editorHeight)
        }
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(
                    canSend
                        ? AnyShapeStyle(.orange)
                        : AnyShapeStyle(.tertiary)
                )
                .frame(width: 28, height: 28)
                .opacity(isSendHovered && canSend ? 0.8 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isSendHovered = hovering
            }
        }
        .animation(.easeInOut(duration: 0.15), value: canSend)
        .help(canSend ? "Send message (↩)" : "Type a message to send")
        .accessibilityLabel("Send message")
    }

    private var scheduleButton: some View {
        ComposerIconButton(
            systemImage: "clock",
            help: "Schedule message"
        ) {
            isSchedulePopoverPresented.toggle()
        }
        .popover(isPresented: $isSchedulePopoverPresented, arrowEdge: .bottom) {
            ScheduleMessagePopover(
                store: store,
                conversationID: conversation.id,
                canSchedule: canSchedule,
                scheduled: didScheduleMessage,
                showScheduledMessages: showScheduledMessages
            )
        }
    }

    private var canSend: Bool {
        let hasText = !store.composerDraft.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let attachmentState = store.attachmentDraftState(for: conversation.id)
        return (hasText || !attachmentState.attachments.isEmpty)
            && !attachmentState.isUploading
    }

    private var composerPlaceholder: String {
        let prefix = conversation.kind == .channel ? "#" : ""
        return "Message \(prefix)\(conversation.title)"
    }

    private var canSchedule: Bool {
        !store.composerDraft.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private func moveSuggestion(by offset: Int, count: Int) {
        guard count > 0 else {
            return
        }
        selectedSuggestionIndex =
            (selectedSuggestionIndex + offset + count) % count
    }

    private func acceptSuggestion(
        from suggestions: [ComposerSuggestion],
        query: ComposerQuery?
    ) {
        guard let query, !suggestions.isEmpty else {
            return
        }
        let index = min(selectedSuggestionIndex, suggestions.count - 1)
        var draft = store.composerDraft
        selection = draft.insert(
            suggestion: suggestions[index],
            replacing: query
        )
        store.composerDraft = draft
        dismissedQuery = nil
        selectedSuggestionIndex = 0
    }

    private func send() {
        guard canSend else {
            return
        }
        let hasAttachments = !store
            .attachmentDraftState(for: conversation.id)
            .attachments
            .isEmpty
        store.sendComposerDraft()
        if !hasAttachments {
            selection = NSRange(location: 0, length: 0)
        }
        dismissedQuery = nil
        selectedSuggestionIndex = 0
    }

    private func chooseFiles() {
        Task { @MainActor in
            let urls = await ComposerAttachmentPicker.chooseFiles()
            store.addComposerAttachments(urls, to: conversation.id)
        }
    }

    private func didScheduleMessage() {
        isSchedulePopoverPresented = false
        selection = NSRange(location: 0, length: 0)
        dismissedQuery = nil
        selectedSuggestionIndex = 0
    }

    private func showScheduledMessages() {
        isSchedulePopoverPresented = false
        Task { @MainActor in
            await Task.yield()
            isScheduledMessagesPresented = true
        }
    }

    private func applyFormatting(_ formatting: ComposerFormatting) {
        var draft = store.composerDraft
        selection = draft.applyFormatting(formatting, to: selection)
        store.composerDraft = draft
    }

    private func moveCaretToDraftEnd() {
        selection = NSRange(
            location: (store.composerDraft.text as NSString).length,
            length: 0
        )
    }
}

/// Uniform 28×28 hit target shared by every secondary composer action so
/// the whole control row stays optically aligned.
private struct ComposerIconButton: View {
    let systemImage: String
    let help: String
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isEnabled ? .secondary : .tertiary)
                .frame(width: 28, height: 28)
                .background(
                    Color.primary.opacity(isHovered && isEnabled ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ComposerSuggestionList: View {
    let store: AppStore
    let suggestions: [ComposerSuggestion]
    let selectedIndex: Int
    let select: (Int) -> Void
    let hover: (Int) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                let user = suggestion.tagKind == .user
                    ? store.user(withID: suggestion.entityID)
                    : nil

                Button {
                    select(index)
                } label: {
                    HStack(spacing: 9) {
                        suggestionIcon(suggestion)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(user?.displayName ?? suggestion.title)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            if let user {
                                UserStatusLabel(
                                    user: user,
                                    customEmojiURLs: store.customEmojiURLs
                                )
                            } else if let subtitle = suggestion.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(height: 36)
                    .padding(.horizontal, 8)
                    .background(
                        index == selectedIndex
                            ? Color.accentColor.opacity(0.18)
                            : .clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        hover(index)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("↑↓ navigate")
                Text("↩ or ⇥ select")
                Text("esc close")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 16)
            .padding(.horizontal, 9)
        }
        .padding(6)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
    }

    @ViewBuilder
    private func suggestionIcon(_ suggestion: ComposerSuggestion) -> some View {
        switch suggestion.tagKind {
        case .user:
            let user = store.user(withID: suggestion.entityID)
            let displayName = user?.displayName ?? suggestion.title
            UserAvatar(
                imageURL: user?.avatarURL ?? suggestion.avatarURL,
                initials: displayName
                    .split(separator: " ")
                    .prefix(2)
                    .compactMap(\.first)
                    .map(String.init)
                    .joined()
                    .uppercased(),
                accessibilityName: displayName,
                size: 26,
                availability: user?.availability
            )
        case .channel:
            Image(systemName: "number")
                .foregroundStyle(.secondary)
                .frame(width: 26)
        case .broadcast:
            Image(systemName: "megaphone.fill")
                .foregroundStyle(.orange)
                .frame(width: 26)
        case .emoji:
            if let url = suggestion.avatarURL {
                EmojiText(
                    verbatim: suggestion.displayText,
                    emojis: [
                        RemoteEmoji(
                            shortcode: suggestion.entityID,
                            url: url
                        )
                    ]
                )
                .font(.title3)
                .lineLimit(1)
                .frame(width: 26, height: 26)
            } else {
                Text(
                    SlackEmojiCatalog.unicode(for: suggestion.entityID)
                        ?? suggestion.displayText
                )
                .font(.title3)
                .frame(width: 26, height: 26)
            }
        }
    }
}
