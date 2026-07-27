import SwiftUI

struct SlackSignInView: View {
    let store: AppStore

    @ViewBuilder
    var body: some View {
        if store.connectionState == .needsConfiguration {
            SlackAppSetupView(store: store, onSaved: nil)
        } else {
            signInContent
        }
    }

    private var signInContent: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.orange.gradient)
                    .frame(width: 74, height: 74)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 7) {
                Text("Your Slack, built for focus")
                    .font(.title.bold())
                Text("Sign in once to bring your channels, DMs, and unread messages into Mini Slack.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 410)
            }

            stateContent

            if showsSavedWorkspaces {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved workspaces")
                        .font(.headline)
                    WorkspaceAccountList(
                        store: store,
                        showsRemoveActions: true
                    )
                }
                .padding(12)
                .frame(maxWidth: 380)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }

            Text("Login opens Slack securely. Mini Slack never sees your password.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var showsSavedWorkspaces: Bool {
        guard !store.workspaceAccounts.isEmpty else {
            return false
        }
        return switch store.connectionState {
        case .disconnected, .failed:
            true
        default:
            false
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch store.connectionState {
        case .authorizing:
            VStack(spacing: 10) {
                ProgressView()
                Text("Finish signing in with Slack in the login window")
                    .font(.headline)
                HStack {
                    Button("Cancel") {
                        Task {
                            await store.cancelSlackSignIn()
                        }
                    }
                }
            }

        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading your Slack workspace…")
                    .font(.headline)
            }

        case let .failed(message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack {
                    Button("Try again") {
                        Task {
                            await store.retrySlackConnection()
                        }
                    }
                    Button("Sign in again") {
                        Task {
                            await store.signInWithSlack()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

        case .needsConfiguration, .preview, .disconnected, .connected:
            VStack(spacing: 10) {
                Button {
                    Task {
                        await store.signInWithSlack()
                    }
                } label: {
                    Label("Continue with Slack", systemImage: "arrow.up.right.square")
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Slack opens to authorize the user scopes from the manifest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
