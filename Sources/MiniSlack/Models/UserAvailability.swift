import Foundation

enum UserPresence: String, Codable, Hashable, Sendable {
    case active
    case away
    case offline
    case unknown
    case notApplicable

    var displayText: String {
        switch self {
        case .active:
            "Active"
        case .away:
            "Away"
        case .offline:
            "Offline"
        case .unknown:
            "Status unavailable"
        case .notApplicable:
            "Presence not applicable"
        }
    }
}

struct UserCustomStatus: Codable, Hashable, Sendable {
    let text: String
    let emoji: String?
    let expiresAt: Date?

    func isActive(at date: Date) -> Bool {
        expiresAt.map { date < $0 } ?? true
    }
}

struct UserDoNotDisturb: Codable, Hashable, Sendable {
    let isEnabled: Bool
    /// Start of the current or next scheduled DND window from Slack
    /// (`next_dnd_start_ts`). Nil for snooze-only state or legacy cache.
    let startsAt: Date?
    let endsAt: Date?

    init(isEnabled: Bool, endsAt: Date?, startsAt: Date? = nil) {
        self.isEnabled = isEnabled
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    func isActive(at date: Date) -> Bool {
        guard isEnabled else {
            return false
        }
        // Slack always reports the next (or current) DND window timestamps.
        // Outside the window, `dnd_enabled` is sometimes still true for users
        // with a schedule — require the current time to fall within [start, end).
        if let startsAt, date < startsAt {
            return false
        }
        if let endsAt, date >= endsAt {
            return false
        }
        return true
    }
}

struct UserAvailability: Codable, Hashable, Sendable {
    let presence: UserPresence
    let customStatus: UserCustomStatus?
    let doNotDisturb: UserDoNotDisturb?
    let fetchedAt: Date?

    init(
        presence: UserPresence = .unknown,
        customStatus: UserCustomStatus? = nil,
        doNotDisturb: UserDoNotDisturb? = nil,
        fetchedAt: Date? = nil
    ) {
        self.presence = presence
        self.customStatus = customStatus
        self.doNotDisturb = doNotDisturb
        self.fetchedAt = fetchedAt
    }

    func activeCustomStatus(at date: Date) -> UserCustomStatus? {
        customStatus.flatMap { $0.isActive(at: date) ? $0 : nil }
    }

    func isDoNotDisturbActive(at date: Date) -> Bool {
        doNotDisturb?.isActive(at: date) == true
    }

    func displayText(at date: Date) -> String {
        if let status = activeCustomStatus(at: date),
           let displayText = Self.customStatusDisplayText(status)
        {
            return displayText
        }
        if isDoNotDisturbActive(at: date) {
            return "Do not disturb"
        }
        return presence.displayText
    }

    func accessibilityLabel(at date: Date) -> String {
        var components = [presence.displayText]
        if isDoNotDisturbActive(at: date) {
            components.append("Do not disturb")
        }
        if let status = activeCustomStatus(at: date) {
            let text = status.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                components.append("Status: \(text)")
            } else if let emoji = status.emoji?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !emoji.isEmpty
            {
                components.append("Custom status: \(emoji)")
            }
        }
        return components.joined(separator: ", ")
    }

    private static func customStatusDisplayText(_ status: UserCustomStatus) -> String? {
        let text = status.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji = status.emoji?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        switch (emoji, text.isEmpty) {
        case let (.some(emoji), false):
            return "\(emoji) \(text)"
        case let (.some(emoji), true):
            return emoji
        case (.none, false):
            return text
        case (.none, true):
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
