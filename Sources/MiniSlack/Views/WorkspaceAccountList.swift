import SwiftUI

struct WorkspaceAccountList: View {
    let store: AppStore
    var showsAddWorkspace = false
    var showsRemoveActions = true
    @State private var switchingWorkspaceID: String?
    @State private var pendingRemoval: SlackWorkspaceAccountSummary?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 6) {
            ForEach(store.workspaceAccounts) { account in
                HStack(spacing: 9) {
                    Image(systemName: "building.2.crop.circle")
                        .font(.title3)
                        .foregroundStyle(
                            account.teamID == store.credentials?.teamID
                                ? AnyShapeStyle(.orange)
                                : AnyShapeStyle(.secondary)
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.teamName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(
                            account.teamID == store.credentials?.teamID
                                ? "Current workspace"
                                : "Saved workspace"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if switchingWorkspaceID == account.teamID {
                        ProgressView()
                            .controlSize(.small)
                    } else if account.teamID == store.credentials?.teamID {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Current workspace")
                    } else {
                        Button("Switch") {
                            switchWorkspace(account)
                        }
                        .controlSize(.small)
                    }

                    if showsRemoveActions {
                        Menu {
                            Button(
                                account.teamID == store.credentials?.teamID
                                    ? "Sign Out of This Workspace"
                                    : "Remove Saved Workspace",
                                systemImage: "trash",
                                role: .destructive
                            ) {
                                pendingRemoval = account
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Workspace actions")
                    }
                }
                .padding(.vertical, 4)
            }

            if showsAddWorkspace {
                Button {
                    Task {
                        await store.signInWithSlack()
                    }
                } label: {
                    Label("Add workspace", systemImage: "plus")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.teamName ?? "workspace")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: {
                    if !$0 {
                        pendingRemoval = nil
                    }
                }
            )
        ) {
            Button("Remove Workspace", role: .destructive) {
                removePendingWorkspace()
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text("Local history and queued messages remain available if you add this workspace again.")
        }
        .alert(
            "Workspace Account Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: {
                    if !$0 {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func switchWorkspace(_ account: SlackWorkspaceAccountSummary) {
        switchingWorkspaceID = account.teamID
        Task {
            do {
                try await store.switchWorkspace(to: account.teamID)
            } catch {
                errorMessage = error.localizedDescription
            }
            switchingWorkspaceID = nil
        }
    }

    private func removePendingWorkspace() {
        guard let account = pendingRemoval else {
            return
        }
        pendingRemoval = nil
        do {
            try store.removeWorkspace(teamID: account.teamID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
