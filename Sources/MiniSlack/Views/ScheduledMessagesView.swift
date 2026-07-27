import EmojiText
import SwiftUI

struct ScheduleMessagePopover: View {
    let store: AppStore
    let conversationID: String
    let canSchedule: Bool
    let scheduled: () -> Void
    let showScheduledMessages: () -> Void
    @State private var postAt = ScheduledMessagePreset.tomorrowMorning.date()
    @State private var isScheduling = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule message")
                .font(.headline)

            VStack(spacing: 2) {
                ForEach(ScheduledMessagePreset.allCases) { preset in
                    Button {
                        postAt = preset.date()
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: preset.systemImage)
                                .frame(width: 18)
                            Text(preset.title)
                            Spacer()
                            Text(
                                preset.date(),
                                format: .dateTime.weekday(.abbreviated).hour().minute()
                            )
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 7)
                    .frame(height: 30)
                }
            }

            DatePicker(
                "Send at",
                selection: $postAt,
                in: Date.now.addingTimeInterval(60)
                    ... Date.now.addingTimeInterval(120 * 86_400)
            )
            .datePickerStyle(.field)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !canSchedule {
                Text("Write a message first. You can still manage messages already scheduled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    showScheduledMessages()
                } label: {
                    let count = store.scheduledMessages(for: conversationID).count
                    Text(count == 0 ? "View scheduled" : "View scheduled (\(count))")
                }

                Spacer()

                Button("Schedule") {
                    isScheduling = true
                    errorMessage = nil
                    Task {
                        do {
                            try await store.scheduleDraft(at: postAt)
                            scheduled()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        isScheduling = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSchedule || isScheduling)
            }
        }
        .padding(14)
        .frame(width: 330)
    }
}

struct ScheduledMessagesView: View {
    let store: AppStore
    let conversation: Conversation
    @Environment(\.dismiss) private var dismiss
    @State private var deletingMessageID: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scheduled messages")
                        .font(.headline)
                    Text(
                        conversation.kind == .channel
                            ? "#\(conversation.title)"
                            : conversation.title
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        await store.refreshScheduledMessages()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.scheduledMessagesState.isLoading)
                .help("Refresh scheduled messages")
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            if store.scheduledMessagesState.isLoading,
               !store.scheduledMessagesState.hasLoaded
            {
                ProgressView("Loading scheduled messages…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                ContentUnavailableView(
                    "No Scheduled Messages",
                    systemImage: "clock",
                    description: Text("Use the clock beside Send to schedule one.")
                )
            } else {
                List(messages) { message in
                    ScheduledMessageRow(
                        text: store.scheduledMessageDisplayText(message),
                        postAt: message.postAt,
                        customEmojiURLs: store.customEmojiURLs,
                        isDeleting: deletingMessageID == message.id,
                        delete: {
                            delete(message)
                        }
                    )
                }
                .listStyle(.inset)
            }

            if let errorMessage = errorMessage ?? store.scheduledMessagesState.errorMessage {
                Divider()
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(minWidth: 360, idealWidth: 440, minHeight: 320, idealHeight: 420)
        .task {
            await store.refreshScheduledMessages()
        }
    }

    private var messages: [SlackScheduledMessage] {
        store.scheduledMessages(for: conversation.id)
    }

    private func delete(_ message: SlackScheduledMessage) {
        deletingMessageID = message.id
        errorMessage = nil
        Task {
            do {
                try await store.deleteScheduledMessage(message)
            } catch {
                errorMessage = error.localizedDescription
            }
            deletingMessageID = nil
        }
    }
}

private struct ScheduledMessageRow: View {
    let text: String
    let postAt: Date
    let customEmojiURLs: [String: URL]
    let isDeleting: Bool
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                EmojiText(
                    verbatim: text,
                    emojis: SlackEmoji.shortcodeNames(in: text).compactMap { name in
                        customEmojiURLs[name].map {
                            RemoteEmoji(shortcode: name, url: $0)
                        }
                    }
                )
                .lineLimit(3)

                Label(
                    postAt.formatted(
                        .dateTime.weekday(.wide).month().day().hour().minute()
                    ),
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isDeleting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete scheduled message")
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Delete Scheduled Message", systemImage: "trash", role: .destructive) {
                delete()
            }
        }
    }
}
