import SwiftUI

struct ThreadPane: View {
    let store: AppStore
    let windowState: WindowState
    let identifier: ThreadIdentifier
    let compact: Bool

    var body: some View {
        if let thread = store.threadState(for: identifier) {
            VStack(spacing: 0) {
                header(thread)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        MessageRow(
                            store: store,
                            conversationID: identifier.conversationID,
                            message: thread.root,
                            customEmojiURLs: store.customEmojiURLs,
                            showsThreadAction: false,
                            threadIdentifier: identifier
                        )

                        Divider()
                            .padding(.vertical, 4)

                        ForEach(thread.replies) { reply in
                            MessageRow(
                                store: store,
                                conversationID: identifier.conversationID,
                                message: reply,
                                customEmojiURLs: store.customEmojiURLs,
                                showsThreadAction: false,
                                threadIdentifier: identifier
                            )
                        }

                        if let errorMessage = thread.errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(10)
                        }

                        if thread.nextCursor != nil {
                            Button {
                                Task {
                                    await store.loadThread(identifier, loadMore: true)
                                }
                            } label: {
                                if thread.isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Load more replies")
                                }
                            }
                            .buttonStyle(.borderless)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .overlay {
                    if thread.isLoading && thread.replies.isEmpty {
                        ProgressView("Loading thread…")
                            .controlSize(.small)
                    }
                }

                ThreadComposer(
                    store: store,
                    windowState: windowState,
                    identifier: identifier
                )
            }
            .background(Color(nsColor: .textBackgroundColor))
            .task(id: identifier) {
                await store.loadThread(identifier)
            }
        } else {
            ContentUnavailableView("Thread unavailable", systemImage: "bubble.left")
        }
    }

    private func header(_ thread: ThreadState) -> some View {
        HStack(spacing: 8) {
            if compact {
                Button(action: windowState.dismissThread) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
            }
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Thread")
                    .font(.headline)
                Text(
                    thread.replies.isEmpty
                        ? "No replies yet"
                        : "\(thread.replies.count) \(thread.replies.count == 1 ? "reply" : "replies")"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if thread.isFollowing {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.orange)
                    .help("Following this thread in Slack")
            }
            Button(action: windowState.dismissThread) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close thread (Esc)")
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct ThreadComposer: View {
    let store: AppStore
    let windowState: WindowState
    let identifier: ThreadIdentifier
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editorHeight: CGFloat = 24

    var body: some View {
        let draft = store.threadDraft(for: identifier)

        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    ForEach(ComposerFormatting.allCases) { formatting in
                        Button(formatting.title, systemImage: formatting.systemImage) {
                            applyFormatting(formatting)
                        }
                    }
                } label: {
                    Image(systemName: "textformat")
                        .frame(width: 22, height: 24)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                ComposerTextView(
                    draft: Binding(
                        get: { store.threadDraft(for: identifier) },
                        set: { store.setThreadDraft($0, for: identifier) }
                    ),
                    selection: $selection,
                    height: $editorHeight,
                    suggestionsVisible: false,
                    accessibilityLabel: "Reply in thread",
                    moveSuggestion: { _ in },
                    acceptSuggestion: {},
                    dismissSuggestions: {},
                    format: applyFormatting,
                    send: send,
                    onEscape: windowState.dismissThread
                )
                .frame(height: editorHeight)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? AnyShapeStyle(.tertiary)
                        : AnyShapeStyle(.orange)
                )
                .disabled(
                    draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(10)
        }
        .background(.bar)
    }

    private func applyFormatting(_ formatting: ComposerFormatting) {
        var draft = store.threadDraft(for: identifier)
        selection = draft.applyFormatting(formatting, to: selection)
        store.setThreadDraft(draft, for: identifier)
    }

    private func send() {
        Task {
            await store.sendThreadDraft(identifier)
            selection = NSRange(location: 0, length: 0)
        }
    }
}
