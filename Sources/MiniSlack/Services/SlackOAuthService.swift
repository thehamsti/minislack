import CryptoKit
import Foundation
import Security

actor SlackOAuthService {
    struct Session: Equatable, Sendable {
        let state: String
        let verifier: String
    }

    enum OAuthError: LocalizedError, Equatable {
        case invalidCallback
        case invalidState
        case missingAuthorizationCode
        case noPendingSession
        case rejected(String)
        case slack(String)
        case invalidTokenResponse

        var errorDescription: String? {
            switch self {
            case .invalidCallback:
                "Slack returned an invalid login callback."
            case .invalidState:
                "Slack login could not be verified. Please try again."
            case .missingAuthorizationCode:
                "Slack did not return an authorization code."
            case .noPendingSession:
                "This Slack login session has expired. Please start again."
            case let .rejected(reason):
                "Slack login was not completed: \(reason)."
            case let .slack(error):
                "Slack authentication failed: \(error)."
            case .invalidTokenResponse:
                "Slack returned an incomplete login response."
            }
        }
    }

    static let userScopes = [
        "channels:history",
        "channels:read",
        "channels:write",
        "chat:write",
        "dnd:read",
        "dnd:write",
        "emoji:read",
        "files:read",
        "files:write",
        "groups:history",
        "groups:read",
        "groups:write",
        "im:history",
        "im:read",
        "im:write",
        "mpim:history",
        "mpim:read",
        "mpim:write",
        "reactions:read",
        "reactions:write",
        "pins:write",
        "reminders:write",
        "search:read",
        "users:read",
        "users:write",
        "users.profile:write",
    ]

    private let configuration: SlackConfiguration
    private let urlSession: URLSession
    private var pendingSession: Session?

    init(configuration: SlackConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    func beginAuthorization() throws -> URL {
        let session = Session(
            state: Self.randomURLSafeString(byteCount: 24),
            verifier: Self.randomURLSafeString(byteCount: 64)
        )
        pendingSession = session
        return try authorizationURL(for: session)
    }

    func cancelAuthorization() {
        pendingSession = nil
    }

    func authorizationURL(for session: Session) throws -> URL {
        let challenge = Self.codeChallenge(for: session.verifier)
        var components = URLComponents(string: "https://slack.com/oauth/v2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "user_scope", value: Self.userScopes.joined(separator: ",")),
            URLQueryItem(name: "redirect_uri", value: SlackConfiguration.redirectURI),
            URLQueryItem(name: "state", value: session.state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components?.url else {
            throw OAuthError.invalidCallback
        }
        return url
    }

    func handleCallback(_ url: URL) async throws -> SlackCredentials {
        guard url.scheme == "minislack", url.host == "oauth", url.path == "/slack" else {
            throw OAuthError.invalidCallback
        }
        guard let pendingSession else {
            throw OAuthError.noPendingSession
        }

        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        if let error = values["error"], !error.isEmpty {
            self.pendingSession = nil
            throw OAuthError.rejected(error)
        }
        guard values["state"] == pendingSession.state else {
            self.pendingSession = nil
            throw OAuthError.invalidState
        }
        guard let code = values["code"], !code.isEmpty else {
            self.pendingSession = nil
            throw OAuthError.missingAuthorizationCode
        }

        self.pendingSession = nil
        return try await exchange(code: code, verifier: pendingSession.verifier)
    }

    func refresh(_ credentials: SlackCredentials) async throws -> SlackCredentials {
        let response: SlackOAuthResponse = try await postTokenRequest([
            "client_id": configuration.clientID,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
        ])
        return try response.credentials(fallback: credentials)
    }

    private func exchange(code: String, verifier: String) async throws -> SlackCredentials {
        let response: SlackOAuthResponse = try await postTokenRequest([
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": SlackConfiguration.redirectURI,
        ])
        return try response.credentials()
    }

    private func postTokenRequest(_ parameters: [String: String]) async throws -> SlackOAuthResponse {
        var request = URLRequest(url: URL(string: "https://slack.com/api/oauth.v2.access")!)
        request.timeoutInterval = 20
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(Self.formEncode(key))=\(Self.formEncode(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            throw OAuthError.slack("HTTP request failed")
        }

        let decoded = try JSONDecoder().decode(SlackOAuthResponse.self, from: data)
        guard decoded.ok else {
            throw OAuthError.slack(decoded.error ?? "unknown_error")
        }
        return decoded
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct SlackOAuthResponse: Decodable {
    struct Team: Decodable {
        let id: String
        let name: String?
    }

    struct UserToken: Decodable {
        let id: String?
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case id
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    let ok: Bool
    let error: String?
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: TimeInterval?
    let team: Team?
    let authedUser: UserToken?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case team
        case authedUser = "authed_user"
    }

    func credentials(fallback: SlackCredentials? = nil) throws -> SlackCredentials {
        let accessToken = authedUser?.accessToken ?? accessToken
        let refreshToken = authedUser?.refreshToken ?? refreshToken
        let expiresIn = authedUser?.expiresIn ?? expiresIn
        let userID = authedUser?.id ?? fallback?.userID
        let teamID = team?.id ?? fallback?.teamID
        let teamName = team?.name ?? fallback?.teamName

        guard let accessToken,
              let refreshToken,
              let expiresIn,
              let userID,
              let teamID,
              let teamName
        else {
            throw SlackOAuthService.OAuthError.invalidTokenResponse
        }

        return SlackCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: .now.addingTimeInterval(expiresIn),
            teamID: teamID,
            teamName: teamName,
            userID: userID
        )
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
