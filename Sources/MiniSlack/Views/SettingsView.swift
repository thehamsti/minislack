import SwiftUI

struct SettingsView: View {
    let store: AppStore
    @State private var isProfileEditorPresented = false
    @State private var isSlackAppSetupPresented = false
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("showUnreadCounts") private var showUnreadCounts = true
    @AppStorage(HistoryBackfillSpeed.defaultsKey)
    private var historyBackfillSpeed = HistoryBackfillSpeed.slow
    @AppStorage(IncrementalSyncMode.defaultsKey)
    private var incrementalSyncMode = IncrementalSyncMode.conservative

    var body: some View {
        Form {
            Section("Unread behavior") {
                Toggle("Mark conversations read when opened", isOn: $markReadOnOpen)
                Toggle("Show unread count badges", isOn: $showUnreadCounts)
            }

            Section("Keyboard") {
                LabeledContent("Quick switcher", value: "⌘K")
                LabeledContent("Unread inbox", value: "⌘⇧U")
                LabeledContent("Next / previous unread", value: "⌃↓ / ⌃↑")
                LabeledContent("Move selection", value: "J / K or ↓ / ↑")
                LabeledContent("Open / back", value: "L / H or → / ←")
            }

            Section("History backfill") {
                Picker("Background download", selection: $historyBackfillSpeed) {
                    ForEach(HistoryBackfillSpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                Text(historyBackfillSpeed.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates & notifications") {
                LabeledContent("Socket Mode", value: store.socketModeState.title)
                Picker("Message polling", selection: $incrementalSyncMode) {
                    ForEach(IncrementalSyncMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(incrementalSyncMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    "Socket Mode delivers events immediately. Polling remains enabled "
                        + "as a rate-aware recovery path."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Slack app") {
                Button("Change app setup…") {
                    isSlackAppSetupPresented = true
                }
                Text("The Client ID and app-level token are stored in macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let user = store.currentUser {
                Section("Your Slack profile") {
                    HStack(spacing: 10) {
                        UserAvatar(
                            imageURL: user.avatarURL,
                            initials: user.initials,
                            accessibilityName: user.displayName,
                            availability: user.availability,
                            isCurrentUser: true
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName)
                                .font(.headline)
                            UserStatusLabel(
                                user: user,
                                customEmojiURLs: store.customEmojiURLs
                            )
                        }
                        Spacer()
                        Button("Edit…") {
                            isProfileEditorPresented = true
                        }
                    }
                }
            }

            if !store.workspaceAccounts.isEmpty || store.credentials != nil {
                Section("Slack workspaces") {
                    WorkspaceAccountList(
                        store: store,
                        showsAddWorkspace: true
                    )
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 570)
        .navigationTitle("Mini Slack Settings")
        .onChange(of: incrementalSyncMode) {
            store.restartIncrementalSync()
        }
        .sheet(isPresented: $isProfileEditorPresented) {
            ProfileSettingsView(store: store)
        }
        .sheet(isPresented: $isSlackAppSetupPresented) {
            SlackAppSetupView(
                store: store,
                onSaved: { isSlackAppSetupPresented = false }
            )
        }
    }
}
