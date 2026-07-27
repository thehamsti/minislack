import Foundation

enum OutgoingMessageQueueState: String, Codable, Equatable, Sendable {
    case queued
    case waitingToRetry
    case permanentlyFailed
}

struct OutgoingMessage: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let conversationID: String
    let semanticText: String
    let displayText: String
    let createdAt: Date
    var state: OutgoingMessageQueueState
    var retryCount: Int
    var nextRetryAt: Date?
    var lastError: String?

    init(
        id: UUID,
        conversationID: String,
        semanticText: String,
        displayText: String,
        createdAt: Date,
        state: OutgoingMessageQueueState = .queued,
        retryCount: Int = 0,
        nextRetryAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.semanticText = semanticText
        self.displayText = displayText
        self.createdAt = createdAt
        self.state = state
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
    }
}

enum OutgoingMessageFailureDisposition: Equatable, Sendable {
    case retry(after: TimeInterval)
    case permanent
}

enum OutgoingMessageRetryPolicy {
    private static let transientSlackErrors: Set<String> = [
        "fatal_error",
        "internal_error",
        "ratelimited",
        "request_timeout",
        "service_unavailable",
    ]

    static func disposition(
        for error: any Error,
        retryCount: Int
    ) -> OutgoingMessageFailureDisposition {
        if error is CancellationError {
            return .retry(after: backoffDelay(retryCount: retryCount))
        }
        if let urlError = error as? URLError {
            return disposition(for: urlError, retryCount: retryCount)
        }
        guard let apiError = error as? SlackAPIClient.APIError else {
            return .permanent
        }
        switch apiError {
        case let .rateLimited(seconds):
            return .retry(after: TimeInterval(max(1, seconds)))
        case let .http(status):
            if status == 408 || status == 425 || status == 429 || status >= 500 {
                return .retry(after: backoffDelay(retryCount: retryCount))
            }
            return .permanent
        case let .slack(code):
            return transientSlackErrors.contains(code)
                ? .retry(after: backoffDelay(retryCount: retryCount))
                : .permanent
        case .invalidResponse:
            return retryCount < 3
                ? .retry(after: backoffDelay(retryCount: retryCount))
                : .permanent
        }
    }

    static func backoffDelay(retryCount: Int) -> TimeInterval {
        let exponent = min(max(0, retryCount), 8)
        return min(300, 2 * pow(2, Double(exponent)))
    }

    private static func disposition(
        for error: URLError,
        retryCount: Int
    ) -> OutgoingMessageFailureDisposition {
        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .resourceUnavailable,
             .internationalRoamingOff,
             .dataNotAllowed,
             .secureConnectionFailed:
            .retry(after: backoffDelay(retryCount: retryCount))
        default:
            .permanent
        }
    }
}
