import Foundation

enum SlackSocketModeState: Equatable, Sendable {
    case notConfigured
    case connecting
    case connected
    case reconnecting(String)

    var title: String {
        switch self {
        case .notConfigured:
            "Not configured"
        case .connecting:
            "Connecting…"
        case .connected:
            "Connected"
        case .reconnecting:
            "Reconnecting…"
        }
    }
}

enum SlackSocketModeEvent: @unchecked Sendable {
    case connected
    case message(teamID: String, channelID: String, message: SlackMessageDTO)
    case messageDeleted(teamID: String, channelID: String, timestamp: String)
}

protocol SlackSocketModeEventStreaming: Sendable {
    func events(appToken: String) -> AsyncThrowingStream<SlackSocketModeEvent, Error>
}

struct SlackSocketModeClient: SlackSocketModeEventStreaming, Sendable {
    enum ClientError: LocalizedError {
        case invalidAppToken
        case invalidResponse
        case slack(String)
        case disconnected(String)

        var errorDescription: String? {
            switch self {
            case .invalidAppToken:
                "Enter an app-level token beginning with xapp-."
            case .invalidResponse:
                "Slack returned an invalid Socket Mode response."
            case let .slack(message):
                "Slack Socket Mode failed: \(message)."
            case let .disconnected(reason):
                "Slack requested a Socket Mode reconnect (\(reason))."
            }
        }
    }

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func events(appToken: String) -> AsyncThrowingStream<SlackSocketModeEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(100)) { continuation in
            let task = Task {
                do {
                    let socketURL = try await openConnection(appToken: appToken)
                    let socket = urlSession.webSocketTask(with: socketURL)
                    socket.resume()
                    defer {
                        socket.cancel(with: .goingAway, reason: nil)
                    }

                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case let .data(value):
                            data = value
                        case let .string(value):
                            data = Data(value.utf8)
                        @unknown default:
                            throw ClientError.invalidResponse
                        }
                        let envelope = try JSONDecoder().decode(
                            SlackSocketModeEnvelope.self,
                            from: data
                        )
                        if let envelopeID = envelope.envelopeID {
                            let acknowledgement = try JSONEncoder().encode(
                                SlackSocketModeAcknowledgement(envelopeID: envelopeID)
                            )
                            try await socket.send(.data(acknowledgement))
                        }
                        if envelope.type == "disconnect" {
                            throw ClientError.disconnected(envelope.reason ?? "unknown")
                        }
                        if envelope.type == "hello" {
                            continuation.yield(.connected)
                        }
                        if let event = envelope.event {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func openConnection(appToken: String) async throws -> URL {
        guard appToken.hasPrefix("xapp-") else {
            throw ClientError.invalidAppToken
        }
        var request = URLRequest(
            url: URL(string: "https://slack.com/api/apps.connections.open")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            throw ClientError.invalidResponse
        }
        let connection = try JSONDecoder().decode(
            SlackSocketModeConnectionResponse.self,
            from: data
        )
        guard connection.ok else {
            throw ClientError.slack(connection.error ?? "unknown_error")
        }
        guard let url = connection.url else {
            throw ClientError.invalidResponse
        }
        return url
    }
}

private struct SlackSocketModeConnectionResponse: Decodable {
    let ok: Bool
    let url: URL?
    let error: String?
}

private struct SlackSocketModeAcknowledgement: Encodable {
    let envelopeID: String

    enum CodingKeys: String, CodingKey {
        case envelopeID = "envelope_id"
    }
}

struct SlackSocketModeEnvelope: Decodable {
    let type: String
    let envelopeID: String?
    let reason: String?
    let payload: SlackSocketModePayload?

    enum CodingKeys: String, CodingKey {
        case type
        case envelopeID = "envelope_id"
        case reason
        case payload
    }

    var event: SlackSocketModeEvent? {
        guard type == "events_api",
              let teamID = payload?.teamID,
              let event = payload?.event,
              event.type == "message",
              let channelID = event.channelID
        else {
            return nil
        }
        if event.subtype == "message_deleted", let timestamp = event.deletedTimestamp {
            return .messageDeleted(
                teamID: teamID,
                channelID: channelID,
                timestamp: timestamp
            )
        }
        guard let message = event.message else {
            return nil
        }
        return .message(teamID: teamID, channelID: channelID, message: message)
    }
}

struct SlackSocketModePayload: Decodable {
    let teamID: String?
    let event: SlackSocketModeMessageEvent?

    enum CodingKeys: String, CodingKey {
        case teamID = "team_id"
        case event
    }
}

struct SlackSocketModeMessageEvent: Decodable {
    let type: String
    let subtype: String?
    let channelID: String?
    let deletedTimestamp: String?
    let message: SlackMessageDTO?

    enum CodingKeys: String, CodingKey {
        case type
        case subtype
        case channelID = "channel"
        case deletedTimestamp = "deleted_ts"
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        channelID = try container.decodeIfPresent(String.self, forKey: .channelID)
        deletedTimestamp = try container.decodeIfPresent(
            String.self,
            forKey: .deletedTimestamp
        )
        if container.contains(.message) {
            message = try container.decodeIfPresent(
                SlackMessageDTO.self,
                forKey: .message
            )
        } else {
            message = try? SlackMessageDTO(from: decoder)
        }
    }
}
