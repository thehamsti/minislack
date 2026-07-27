import SwiftUI

struct SlackSignInView: View {
    let store: AppStore

    var body: some View {
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

            Text("Login opens Slack in your browser. Mini Slack never sees your password.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var stateContent: some View {
        switch store.connectionState {
        case .needsConfiguration:
            VStack(spacing: 8) {
                Label("Slack app setup required", systemImage: "wrench.and.screwdriver")
                    .font(.headline)
                Text("Add SlackClientID to Config/MiniSlack-Info.plist, then rebuild the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

        case .authorizing:
            VStack(spacing: 10) {
                ProgressView()
                Text("Finish signing in with Slack in your browser")
                    .font(.headline)
                HStack {
                    Button("Cancel") {
                        Task {
                            await store.cancelSlackSignIn()
                        }
                    }
                    Button("Open Slack again") {
                        Task {
                            await store.signInWithSlack()
                        }
                    }
                    .buttonStyle(.link)
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

        default:
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
        }
    }
}
