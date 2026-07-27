import SwiftUI

struct ProfileSettingsView: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var statusText: String
    @State private var statusEmoji: String
    @State private var expires = false
    @State private var expirationDate: Date
    @State private var dndDuration = DoNotDisturbDuration.oneHour
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmationMessage: String?

    init(store: AppStore) {
        self.store = store
        let status = store.currentUser?.availability.activeCustomStatus(at: .now)
        _statusText = State(initialValue: status?.text ?? "")
        _statusEmoji = State(initialValue: status?.emoji ?? "")
        let expiration = status?.expiresAt ?? .now.addingTimeInterval(3_600)
        _expires = State(initialValue: status?.expiresAt != nil)
        _expirationDate = State(initialValue: expiration)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Form {
                statusSection
                presenceSection
                doNotDisturbSection

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                } else if let confirmationMessage {
                    Label(confirmationMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)

            Divider()
            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 570)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let user = store.currentUser {
                UserAvatar(
                    imageURL: user.avatarURL,
                    initials: user.initials,
                    accessibilityName: user.displayName,
                    size: 42,
                    availability: user.availability,
                    isCurrentUser: true
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(user.displayName)
                        .font(.headline)
                    UserStatusLabel(
                        user: user,
                        customEmojiURLs: store.customEmojiURLs
                    )
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private var statusSection: some View {
        Section("Custom status") {
            TextField("Status text", text: $statusText)
                .onChange(of: statusText) {
                    if statusText.count > 100 {
                        statusText = String(statusText.prefix(100))
                    }
                }

            TextField("Emoji", text: $statusEmoji, prompt: Text(":headphones:"))
            Text("Use a standard or workspace emoji name.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Clear automatically", isOn: $expires)
            if expires {
                DatePicker(
                    "Clear after",
                    selection: $expirationDate,
                    in: Date.now...,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }

            HStack {
                Button("Clear Status") {
                    perform(confirmation: "Custom status cleared.") {
                        try await store.updateCurrentUserStatus(
                            text: "",
                            emoji: "",
                            expiresAt: nil
                        )
                        statusText = ""
                        statusEmoji = ""
                        expires = false
                    }
                }
                .disabled(
                    statusText.isEmpty
                        && statusEmoji.isEmpty
                        && store.currentUser?.availability.customStatus == nil
                )

                Spacer()

                Button("Save Status") {
                    perform(confirmation: "Custom status updated.") {
                        try await store.updateCurrentUserStatus(
                            text: statusText,
                            emoji: statusEmoji,
                            expiresAt: expires ? expirationDate : nil
                        )
                        statusEmoji = store.currentUser?
                            .availability.customStatus?.emoji ?? ""
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var presenceSection: some View {
        Section("Presence") {
            if let user = store.currentUser {
                LabeledContent("Current", value: user.availability.presence.displayText)
            }

            HStack {
                Button(ManualPresenceSetting.automatic.title) {
                    perform(confirmation: "Automatic presence enabled.") {
                        try await store.setCurrentUserPresence(.automatic)
                    }
                }

                Button(ManualPresenceSetting.away.title) {
                    perform(confirmation: "You are marked away.") {
                        try await store.setCurrentUserPresence(.away)
                    }
                }
            }

            Text(ManualPresenceSetting.automatic.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var doNotDisturbSection: some View {
        Section("Do Not Disturb") {
            if let user = store.currentUser,
               user.availability.isDoNotDisturbActive(at: .now)
            {
                LabeledContent("Current") {
                    Text(doNotDisturbDescription(user.availability.doNotDisturb))
                }
            } else {
                LabeledContent("Current", value: "Off")
            }

            Picker("Snooze notifications for", selection: $dndDuration) {
                ForEach(DoNotDisturbDuration.allCases) { duration in
                    Text(duration.title).tag(duration)
                }
            }

            HStack {
                if store.currentUser?.availability.isDoNotDisturbActive(at: .now) == true {
                    Button("End Snooze") {
                        perform(confirmation: "Do Not Disturb snooze ended.") {
                            try await store.endCurrentUserDoNotDisturb()
                        }
                    }
                }

                Spacer()

                Button("Snooze") {
                    perform(confirmation: "Do Not Disturb snooze started.") {
                        try await store.snoozeCurrentUserDoNotDisturb(
                            minutes: dndDuration.rawValue
                        )
                    }
                }
            }
        }
    }

    private func doNotDisturbDescription(
        _ doNotDisturb: UserDoNotDisturb?
    ) -> String {
        guard let endsAt = doNotDisturb?.endsAt else {
            return "On"
        }
        return "Until \(endsAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func perform(
        confirmation: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        isWorking = true
        errorMessage = nil
        confirmationMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await operation()
                confirmationMessage = confirmation
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
