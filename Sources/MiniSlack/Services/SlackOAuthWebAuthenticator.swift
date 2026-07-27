import AppKit
import AuthenticationServices

enum SlackOAuthWebAuthenticationError: Error, Equatable {
    case cancelled
    case couldNotStart
    case missingCallback
}

@MainActor
protocol SlackOAuthWebAuthenticating: AnyObject {
    func authenticate(at url: URL) async throws -> URL
    func cancel()
}

@MainActor
final class SlackOAuthWebAuthenticator:
    NSObject,
    SlackOAuthWebAuthenticating,
    ASWebAuthenticationPresentationContextProviding
{
    private var session: ASWebAuthenticationSession?

    func authenticate(at url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "minislack"
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.session = nil
                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else if let authenticationError = error as? ASWebAuthenticationSessionError,
                              authenticationError.code == .canceledLogin
                    {
                        continuation.resume(
                            throwing: SlackOAuthWebAuthenticationError.cancelled
                        )
                    } else {
                        continuation.resume(
                            throwing: SlackOAuthWebAuthenticationError.missingCallback
                        )
                    }
                }
            }
            session.presentationContextProvider = self
            self.session = session
            guard session.start() else {
                self.session = nil
                continuation.resume(
                    throwing: SlackOAuthWebAuthenticationError.couldNotStart
                )
                return
            }
        }
    }

    func cancel() {
        session?.cancel()
    }

    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            preconditionFailure("Slack OAuth requires a visible Mini Slack window")
        }
        return window
    }
}
