import Foundation

enum ManualPresenceSetting: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case away

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .automatic:
            "Use automatic presence"
        case .away:
            "Mark as away"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "Slack marks you active while you are using it."
        case .away:
            "Stay away until you switch back to automatic."
        }
    }

    var slackValue: String {
        switch self {
        case .automatic:
            "auto"
        case .away:
            "away"
        }
    }
}

enum DoNotDisturbDuration: Int, CaseIterable, Identifiable, Sendable {
    case thirtyMinutes = 30
    case oneHour = 60
    case twoHours = 120
    case fourHours = 240
    case eightHours = 480

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .thirtyMinutes:
            "30 minutes"
        case .oneHour:
            "1 hour"
        case .twoHours:
            "2 hours"
        case .fourHours:
            "4 hours"
        case .eightHours:
            "8 hours"
        }
    }
}

enum ProfileSettingsError: LocalizedError, Equatable {
    case currentUserUnavailable
    case statusTooLong
    case invalidStatusEmoji
    case expirationMustBeFuture
    case invalidSnoozeDuration
    case reconnectRequired

    var errorDescription: String? {
        switch self {
        case .currentUserUnavailable:
            "Your Slack profile is not available yet. Wait for the workspace to finish loading."
        case .statusTooLong:
            "Custom status text must be 100 characters or fewer."
        case .invalidStatusEmoji:
            "Use a Slack emoji name such as :headphones:."
        case .expirationMustBeFuture:
            "Choose a status expiration time in the future."
        case .invalidSnoozeDuration:
            "Choose a valid Do Not Disturb duration."
        case .reconnectRequired:
            "Slack access needs updating. Sign out, then sign in again to grant the new permission."
        }
    }
}

extension UserCustomStatus {
    static func validated(
        text inputText: String,
        emoji inputEmoji: String,
        expiresAt: Date?,
        now: Date = .now
    ) throws -> UserCustomStatus? {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 100 else {
            throw ProfileSettingsError.statusTooLong
        }
        let emoji = try normalizedEmoji(inputEmoji)
        guard !text.isEmpty || emoji != nil else {
            return nil
        }
        if let expiresAt, expiresAt <= now {
            throw ProfileSettingsError.expirationMustBeFuture
        }
        return UserCustomStatus(text: text, emoji: emoji, expiresAt: expiresAt)
    }

    private static func normalizedEmoji(_ input: String) throws -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let name: Substring
        if trimmed.hasPrefix(":"), trimmed.hasSuffix(":"), trimmed.count > 2 {
            name = trimmed.dropFirst().dropLast()
        } else {
            name = Substring(trimmed)
        }
        guard !name.isEmpty, name.count <= 100,
              name.unicodeScalars.allSatisfy({ scalar in
                  (97 ... 122).contains(scalar.value)
                      || (65 ... 90).contains(scalar.value)
                      || (48 ... 57).contains(scalar.value)
                      || scalar == "+"
                      || scalar == "-"
                      || scalar == "_"
              })
        else {
            throw ProfileSettingsError.invalidStatusEmoji
        }
        return ":\(name.lowercased()):"
    }
}
