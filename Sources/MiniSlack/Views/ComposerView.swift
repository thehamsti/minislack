import Foundation
import SwiftUI

struct ComposerView: View {
    let store: AppStore
    let conversation: Conversation
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editorHeight: CGFloat = 24
    @State private var selectedSuggestionIndex = 0
    @State private var dismissedQuery: ComposerQuery?

    var body: some View {
        let draft = store.composerDraft
        let query = draft.query(at: selection)
        let suggestions = query.map {
            store.composerSuggestions(
                for: $0,
                allowsBroadcasts: conversation.kind == .channel
            )
        } ?? []
        let suggestionsVisible = query != nil
            && query != dismissedQuery
            && !suggestions.isEmpty
        let suggestionPopupHeight = CGFloat(suggestions.count) * 38 + 30

        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if draft.text.isEmpty {
                        Text(
                            "Message \(conversation.kind == .channel ? "#" : "")\(conversation.title)"
                        )
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
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
                        moveSuggestion: { offset in
                            moveSuggestion(by: offset, count: suggestions.count)
                        },
                        acceptSuggestion: {
                            acceptSuggestion(from: suggestions, query: query)
                        },
                        dismissSuggestions: {
                            dismissedQuery = query
                        },
                        send: send
                    )
                    .frame(height: editorHeight)
                }

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    canSend
                        ? AnyShapeStyle(.orange)
                        : AnyShapeStyle(.tertiary)
                )
                .disabled(!canSend)
                .help("Send message")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.separator, lineWidth: 0.5)
            }
            .padding(10)
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
    }

    private var canSend: Bool {
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
        store.sendDraft()
        selection = NSRange(location: 0, length: 0)
        dismissedQuery = nil
        selectedSuggestionIndex = 0
    }

    private func moveCaretToDraftEnd() {
        selection = NSRange(
            location: (store.composerDraft.text as NSString).length,
            length: 0
        )
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
        }
    }
}
