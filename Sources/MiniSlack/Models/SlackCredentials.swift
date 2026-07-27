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

struct SlackWorkspaceAccountSummary: Equatable, Hashable, Identifiable, Sendable {
    let teamID: String
    let teamName: String
    let userID: String
    let isActive: Bool

    var id: String {
        teamID
    }
}

struct SlackCredentialCollection: Codable, Equatable, Sendable {
    private(set) var credentials: [SlackCredentials]
    private(set) var activeWorkspaceID: String?

    init(
        credentials: [SlackCredentials] = [],
        activeWorkspaceID: String? = nil
    ) {
        var byTeamID: [String: SlackCredentials] = [:]
        for credential in credentials {
            byTeamID[credential.teamID] = credential
        }
        self.credentials = byTeamID.values.sorted(by: Self.credentialOrder)
        self.activeWorkspaceID = byTeamID[activeWorkspaceID ?? ""] == nil
            ? nil
            : activeWorkspaceID
    }

    var activeCredentials: SlackCredentials? {
        activeWorkspaceID.flatMap(credential(for:))
    }

    var accountSummaries: [SlackWorkspaceAccountSummary] {
        credentials.map {
            SlackWorkspaceAccountSummary(
                teamID: $0.teamID,
                teamName: $0.teamName,
                userID: $0.userID,
                isActive: $0.teamID == activeWorkspaceID
            )
        }
    }

    func credential(for teamID: String) -> SlackCredentials? {
        credentials.first { $0.teamID == teamID }
    }

    mutating func upsert(
        _ credential: SlackCredentials,
        makeActive: Bool = true
    ) {
        credentials.removeAll { $0.teamID == credential.teamID }
        credentials.append(credential)
        credentials.sort(by: Self.credentialOrder)
        if makeActive {
            activeWorkspaceID = credential.teamID
        }
    }

    @discardableResult
    mutating func select(_ teamID: String) -> SlackCredentials? {
        guard let credential = credential(for: teamID) else {
            return nil
        }
        activeWorkspaceID = teamID
        return credential
    }

    mutating func remove(_ teamID: String) {
        credentials.removeAll { $0.teamID == teamID }
        if activeWorkspaceID == teamID {
            activeWorkspaceID = nil
        }
    }

    private static func credentialOrder(
        _ lhs: SlackCredentials,
        _ rhs: SlackCredentials
    ) -> Bool {
        let nameOrder = lhs.teamName.localizedCaseInsensitiveCompare(rhs.teamName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.teamID < rhs.teamID
    }
}
