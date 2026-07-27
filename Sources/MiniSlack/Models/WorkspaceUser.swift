import Foundation

struct WorkspaceUser: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let profileTitle: String?
    let availability: UserAvailability
    var avatarURL: URL? = nil
    let botID: String?
    let appID: String?

    init(
        id: String,
        displayName: String,
        profileTitle: String? = nil,
        availability: UserAvailability = UserAvailability(),
        avatarURL: URL? = nil,
        botID: String? = nil,
        appID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.profileTitle = profileTitle
        self.availability = availability
        self.avatarURL = avatarURL
        self.botID = botID
        self.appID = appID
    }

    init(
        id: String,
        displayName: String,
        status: String,
        isActive: Bool,
        avatarURL: URL? = nil,
        botID: String? = nil,
        appID: String? = nil
    ) {
        self.init(
            id: id,
            displayName: displayName,
            profileTitle: status.isEmpty ? nil : status,
            availability: UserAvailability(presence: isActive ? .active : .away),
            avatarURL: avatarURL,
            botID: botID,
            appID: appID
        )
    }

    var status: String {
        let now = Date.now
        if availability.activeCustomStatus(at: now) != nil
            || availability.isDoNotDisturbActive(at: now)
            || profileTitle == nil
        {
            return availability.displayText(at: now)
        }
        return profileTitle ?? availability.displayText(at: now)
    }

    var isActive: Bool {
        availability.presence == .active
    }

    var initials: String {
        displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}
