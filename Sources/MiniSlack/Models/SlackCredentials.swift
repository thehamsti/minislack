import Foundation

struct SlackCredentials: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let teamID: String
    let teamName: String
    let userID: String

    func needsRefresh(now: Date = .now) -> Bool {
        expiresAt.timeIntervalSince(now) < 300
    }
}
