import SwiftUI

struct SettingsView: View {
    let store: AppStore
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("showUnreadCounts") private var showUnreadCounts = true
    @AppStorage(HistoryBackfillSpeed.defaultsKey)
    private var historyBackfillSpeed = HistoryBackfillSpeed.slow

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

            if case let .connected(teamName) = store.connectionState {
                Section("Slack") {
                    LabeledContent("Workspace", value: teamName)
                    Button("Sign out", role: .destructive) {
                        store.signOut()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 390)
        .navigationTitle("Mini Slack Settings")
    }
}
