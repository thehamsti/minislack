import Foundation
import Testing
@testable import MiniSlack

struct ProfileSettingsModelTests {
    @Test
    func validatesAndNormalizesCustomStatusInput() throws {
        let expiration = Date(timeIntervalSince1970: 2_000)
        let status = try UserCustomStatus.validated(
            text: "  Heads down  ",
            emoji: "HeadPhones",
            expiresAt: expiration,
            now: Date(timeIntervalSince1970: 1_000)
        )

        #expect(status?.text == "Heads down")
        #expect(status?.emoji == ":headphones:")
        #expect(status?.expiresAt == expiration)
        #expect(
            try UserCustomStatus.validated(
                text: " ",
                emoji: " ",
                expiresAt: expiration
            ) == nil
        )
        #expect(ManualPresenceSetting.automatic.slackValue == "auto")
        #expect(ManualPresenceSetting.away.slackValue == "away")
        #expect(DoNotDisturbDuration.eightHours.rawValue == 480)
    }

    @Test
    func rejectsInvalidStatusValues() {
        #expect(throws: ProfileSettingsError.statusTooLong) {
            try UserCustomStatus.validated(
                text: String(repeating: "a", count: 101),
                emoji: "",
                expiresAt: nil
            )
        }
        #expect(throws: ProfileSettingsError.invalidStatusEmoji) {
            try UserCustomStatus.validated(
                text: "Focus",
                emoji: "🎯",
                expiresAt: nil
            )
        }
        #expect(throws: ProfileSettingsError.expirationMustBeFuture) {
            try UserCustomStatus.validated(
                text: "Focus",
                emoji: ":dart:",
                expiresAt: Date(timeIntervalSince1970: 999),
                now: Date(timeIntervalSince1970: 1_000)
            )
        }
    }
}

struct ProfileSettingsAPITests {
    @Test
    func sendsOfficialSlackProfilePresenceAndDNDRequests() async throws {
        let token = "profile-api-\(UUID().uuidString)"
        let requests = ProfileRequestRecorder()
        let client = profileClient(token: token) { request in
            requests.append(request)
            switch request.url?.path {
            case "/api/users.profile.set", "/api/users.setPresence":
                return try profileResponse(for: request, json: #"{"ok":true}"#)
            case "/api/dnd.setSnooze":
                return try profileResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "snooze_enabled": true,
                      "snooze_endtime": 1900003600
                    }
                    """
                )
            case "/api/dnd.endSnooze":
                return try profileResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "dnd_enabled": false,
                      "snooze_enabled": false
                    }
                    """
                )
            default:
                throw ProfileStubError.unexpectedRequest
            }
        }
        defer { ProfileURLProtocol.unregister(token: token) }

        try await client.setProfileStatus(
            text: "Focus",
            emoji: ":dart:",
            expiration: Date(timeIntervalSince1970: 1_900_000_000),
            accessToken: token
        )
        try await client.setManualPresence(.away, accessToken: token)
        let snoozed = try await client.snoozeDoNotDisturb(
            minutes: 60,
            accessToken: token
        )
        let ended = try await client.endDoNotDisturbSnooze(accessToken: token)

        #expect(requests.values.map(\.url?.path) == [
            "/api/users.profile.set",
            "/api/users.setPresence",
            "/api/dnd.setSnooze",
            "/api/dnd.endSnooze",
        ])
        let profile = try #require(
            try profileRequestBody(requests.values[0])["profile"] as? [String: Any]
        )
        #expect(profile["status_text"] as? String == "Focus")
        #expect(profile["status_emoji"] as? String == ":dart:")
        #expect(profile["status_expiration"] as? Int == 1_900_000_000)
        #expect(
            try profileRequestBody(requests.values[1])["presence"] as? String
                == "away"
        )
        #expect(
            try profileRequestBody(requests.values[2])["num_minutes"] as? String
                == "60"
        )
        #expect(snoozed.isEnabled)
        #expect(
            snoozed.endsAt
                == Date(timeIntervalSince1970: 1_900_003_600)
        )
        #expect(!ended.isEnabled)
        #expect(ended.endsAt == nil)
    }
}

@MainActor
struct ProfileSettingsStoreTests {
    @Test
    func successfulMutationsUpdateTheAuthoritativeCurrentUser() async throws {
        let token = "profile-store-\(UUID().uuidString)"
        let client = profileClient(token: token) { request in
            switch request.url?.path {
            case "/api/users.profile.set", "/api/users.setPresence":
                return try profileResponse(for: request, json: #"{"ok":true}"#)
            case "/api/users.getPresence":
                return try profileResponse(
                    for: request,
                    json: #"{"ok":true,"presence":"active","online":true}"#
                )
            case "/api/dnd.setSnooze":
                return try profileResponse(
                    for: request,
                    json: #"{"ok":true,"snooze_enabled":true,"snooze_endtime":1900003600}"#
                )
            case "/api/dnd.endSnooze":
                return try profileResponse(
                    for: request,
                    json: #"{"ok":true,"dnd_enabled":false,"snooze_enabled":false}"#
                )
            default:
                throw ProfileStubError.unexpectedRequest
            }
        }
        defer { ProfileURLProtocol.unregister(token: token) }
        let store = profileStore(client: client, token: token)

        try await store.updateCurrentUserStatus(
            text: " Focus ",
            emoji: "dart",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        #expect(store.currentUser?.availability.customStatus?.text == "Focus")
        #expect(store.currentUser?.availability.customStatus?.emoji == ":dart:")

        try await store.setCurrentUserPresence(.away)
        #expect(store.currentUser?.availability.presence == .away)

        try await store.setCurrentUserPresence(.automatic)
        #expect(store.currentUser?.availability.presence == .active)

        try await store.snoozeCurrentUserDoNotDisturb(minutes: 60)
        #expect(
            store.currentUser?.availability.doNotDisturb?.endsAt
                == Date(timeIntervalSince1970: 1_900_003_600)
        )

        try await store.endCurrentUserDoNotDisturb()
        #expect(
            store.currentUser?.availability.isDoNotDisturbActive(at: .now)
                == false
        )
    }

    @Test
    func failedMutationDoesNotChangeCurrentUserAvailability() async throws {
        let token = "profile-failure-\(UUID().uuidString)"
        let client = profileClient(token: token) { request in
            try profileResponse(
                for: request,
                json: #"{"ok":false,"error":"missing_scope"}"#
            )
        }
        defer { ProfileURLProtocol.unregister(token: token) }
        let store = profileStore(client: client, token: token)
        let before = try #require(store.currentUser?.availability)

        await #expect(throws: ProfileSettingsError.reconnectRequired) {
            try await store.updateCurrentUserStatus(
                text: "Focus",
                emoji: ":dart:",
                expiresAt: nil
            )
        }

        #expect(store.currentUser?.availability == before)
    }

    @Test
    func previewMutationsWorkWithoutSlackCredentials() async throws {
        let user = profileUser()
        let store = AppStore(conversations: [], users: [user])

        try await store.updateCurrentUserStatus(
            text: "Preview focus",
            emoji: "dart",
            expiresAt: nil
        )
        try await store.setCurrentUserPresence(.away)
        try await store.snoozeCurrentUserDoNotDisturb(minutes: 30)

        #expect(store.currentUser?.availability.customStatus?.text == "Preview focus")
        #expect(store.currentUser?.availability.presence == .away)
        #expect(store.currentUser?.availability.isDoNotDisturbActive(at: .now) == true)

        try await store.endCurrentUserDoNotDisturb()
        #expect(store.currentUser?.availability.isDoNotDisturbActive(at: .now) == false)
    }
}

private func profileUser() -> WorkspaceUser {
    WorkspaceUser(
        id: "U0",
        displayName: "Maya",
        availability: UserAvailability(presence: .unknown)
    )
}

@MainActor
private func profileStore(
    client: SlackAPIClient,
    token: String
) -> AppStore {
    AppStore(
        conversations: [],
        users: [profileUser()],
        connectionState: .connected("Acme"),
        slackAPI: client,
        credentials: SlackCredentials(
            accessToken: token,
            refreshToken: "refresh",
            expiresAt: .distantFuture,
            teamID: "T1",
            teamName: "Acme",
            userID: "U0"
        )
    )
}

private typealias ProfileHandler =
    @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

private enum ProfileStubError: Error {
    case missingHandler
    case unexpectedRequest
}

private final class ProfileRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: ProfileHandler] = [:]

    func register(token: String, handler: @escaping ProfileHandler) {
        lock.lock()
        handlers[token] = handler
        lock.unlock()
    }

    func unregister(token: String) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    func handler(for request: URLRequest) -> ProfileHandler? {
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let token = authorization.hasPrefix("Bearer ")
            ? String(authorization.dropFirst(7))
            : ""
        lock.lock()
        let handler = handlers[token]
        lock.unlock()
        return handler
    }
}

private final class ProfileURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = ProfileRegistry()

    static func register(token: String, handler: @escaping ProfileHandler) {
        registry.register(token: token, handler: handler)
    }

    static func unregister(token: String) {
        registry.unregister(token: token)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "slack.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.registry.handler(for: request) else {
            client?.urlProtocol(self, didFailWithError: ProfileStubError.missingHandler)
            return
        }
        do {
            let request = try profileRequestWithMaterializedBody(request)
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ProfileRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var values: [URLRequest] {
        lock.lock()
        let values = requests
        lock.unlock()
        return values
    }

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}

private func profileClient(
    token: String,
    handler: @escaping ProfileHandler
) -> SlackAPIClient {
    ProfileURLProtocol.register(token: token, handler: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProfileURLProtocol.self]
    return SlackAPIClient(urlSession: URLSession(configuration: configuration))
}

private func profileResponse(
    for request: URLRequest,
    json: String
) throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    let response = try #require(
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
    )
    return (response, Data(json.utf8))
}

private func profileRequestWithMaterializedBody(
    _ request: URLRequest
) throws -> URLRequest {
    guard request.httpBody == nil, let stream = request.httpBodyStream else {
        return request
    }
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else {
            throw ProfileStubError.unexpectedRequest
        }
        guard count > 0 else {
            break
        }
        body.append(buffer, count: count)
    }
    var materialized = request
    materialized.httpBodyStream = nil
    materialized.httpBody = body
    return materialized
}

private func profileRequestBody(
    _ request: URLRequest
) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
}
