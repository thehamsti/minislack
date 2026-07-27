import SwiftUI

struct SlackAppSetupView: View {
    let store: AppStore
    let onSaved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var appToken = ""
    @State private var errorMessage: String?
    @State private var copiedManifest = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect your own Slack app")
                        .font(.title.bold())
                    Text(
                        "Mini Slack connects directly from this Mac. "
                            + "Your Client ID and app-level token stay in Keychain."
                    )
                    .foregroundStyle(.secondary)
                }

                setupStep(number: 1, title: "Create the app") {
                    Text(
                        "Open Slack’s app dashboard and choose Create New App → From a manifest."
                    )
                    .foregroundStyle(.secondary)
                    Link(
                        "Open Slack app dashboard",
                        destination: URL(string: "https://api.slack.com/apps")!
                    )
                    .buttonStyle(.borderedProminent)
                }

                setupStep(number: 2, title: "Import the manifest") {
                    Text(
                        "The included manifest enables PKCE, Socket Mode, "
                            + "message events, and every scope Mini Slack uses."
                    )
                    .foregroundStyle(.secondary)
                    HStack {
                        Button(copiedManifest ? "Copied" : "Copy manifest") {
                            SlackAppManifest.copyToPasteboard()
                            copiedManifest = true
                        }
                        Button("Save manifest…") {
                            do {
                                try SlackAppManifest.export()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                }

                setupStep(number: 3, title: "Generate an app-level token") {
                    Text(
                        "In Basic Information → App-Level Tokens, generate a token "
                            + "with the connections:write scope."
                    )
                    .foregroundStyle(.secondary)
                }

                setupStep(number: 4, title: "Paste the app credentials") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Client ID (for example, 123.456)", text: $clientID)
                            .textFieldStyle(.roundedBorder)
                        SecureField("App-level token (xapp-…)", text: $appToken)
                            .textFieldStyle(.roundedBorder)
                        Text(
                            "No client secret is needed. Slack login uses PKCE; "
                                + "the app-level token opens the direct Socket Mode connection."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("Save app setup") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || appToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .padding(30)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 520, minHeight: 580)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            let configuration = store.savedSlackAppConfiguration()
            clientID = configuration.clientID
            appToken = configuration.appToken
        }
    }

    @ViewBuilder
    private func setupStep<Content: View>(
        number: Int,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.orange.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func save() {
        do {
            try store.configureSlackApp(clientID: clientID, appToken: appToken)
            errorMessage = nil
            onSaved?()
            if onSaved != nil {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
