import Foundation

struct SlackConfiguration: Sendable {
    static let redirectURI = "minislack://oauth/slack"

    let clientID: String

    static func bundled() -> SlackConfiguration? {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "SlackClientID") as? String,
              !clientID.isEmpty
        else {
            return nil
        }
        return SlackConfiguration(clientID: clientID)
    }
}
