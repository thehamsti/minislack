import Foundation

extension AppStore {
    var currentUser: WorkspaceUser? {
        if let userID = credentials?.userID {
            return user(withID: userID)
        }
        return connectionState == .preview ? users.first : nil
    }

    func updateCurrentUserStatus(
        text: String,
        emoji: String,
        expiresAt: Date?
    ) async throws {
        let status = try UserCustomStatus.validated(
            text: text,
            emoji: emoji,
            expiresAt: expiresAt
        )
        let user = try currentUserOrThrow()

        if let slackAPI {
            let session = try captureWorkspaceSession()
            let credentials = try await activeCredentials(for: session)
            do {
                try await slackAPI.setProfileStatus(
                    text: status?.text ?? "",
                    emoji: status?.emoji ?? "",
                    expiration: status?.expiresAt,
                    accessToken: credentials.accessToken
                )
                try requireCurrentWorkspaceSession(session)
            } catch {
                throw translatedProfileMutationError(error)
            }
        }

        updateCurrentUserAvailability(userID: user.id) { availability in
            UserAvailability(
                presence: availability.presence,
                customStatus: status,
                doNotDisturb: availability.doNotDisturb,
                fetchedAt: .now
            )
        }
    }

    func setCurrentUserPresence(
        _ setting: ManualPresenceSetting
    ) async throws {
        let user = try currentUserOrThrow()
        let resolvedPresence: UserPresence
        if let slackAPI {
            let session = try captureWorkspaceSession()
            let credentials = try await activeCredentials(for: session)
            do {
                try await slackAPI.setManualPresence(
                    setting,
                    accessToken: credentials.accessToken
                )
                try requireCurrentWorkspaceSession(session)
            } catch {
                throw translatedProfileMutationError(error)
            }
            if setting == .away {
                resolvedPresence = .away
            } else {
                resolvedPresence = (try? await slackAPI.fetchPresence(
                    userID: user.id,
                    currentUserID: credentials.userID,
                    accessToken: credentials.accessToken
                )) ?? .unknown
                try requireCurrentWorkspaceSession(session)
            }
        } else {
            resolvedPresence = setting == .away ? .away : .active
        }

        updateCurrentUserAvailability(userID: user.id) { availability in
            UserAvailability(
                presence: resolvedPresence,
                customStatus: availability.customStatus,
                doNotDisturb: availability.doNotDisturb,
                fetchedAt: .now
            )
        }
    }

    func snoozeCurrentUserDoNotDisturb(minutes: Int) async throws {
        guard minutes > 0 else {
            throw ProfileSettingsError.invalidSnoozeDuration
        }
        let user = try currentUserOrThrow()
        let doNotDisturb: UserDoNotDisturb
        if let slackAPI {
            let session = try captureWorkspaceSession()
            let credentials = try await activeCredentials(for: session)
            do {
                doNotDisturb = try await slackAPI.snoozeDoNotDisturb(
                    minutes: minutes,
                    accessToken: credentials.accessToken
                )
                try requireCurrentWorkspaceSession(session)
            } catch {
                throw translatedProfileMutationError(error)
            }
        } else {
            doNotDisturb = UserDoNotDisturb(
                isEnabled: true,
                endsAt: .now.addingTimeInterval(TimeInterval(minutes * 60))
            )
        }

        updateCurrentUserAvailability(userID: user.id) { availability in
            UserAvailability(
                presence: availability.presence,
                customStatus: availability.customStatus,
                doNotDisturb: doNotDisturb,
                fetchedAt: .now
            )
        }
    }

    func endCurrentUserDoNotDisturb() async throws {
        let user = try currentUserOrThrow()
        let doNotDisturb: UserDoNotDisturb
        if let slackAPI {
            let session = try captureWorkspaceSession()
            let credentials = try await activeCredentials(for: session)
            do {
                doNotDisturb = try await slackAPI.endDoNotDisturbSnooze(
                    accessToken: credentials.accessToken
                )
                try requireCurrentWorkspaceSession(session)
            } catch {
                throw translatedProfileMutationError(error)
            }
        } else {
            doNotDisturb = UserDoNotDisturb(isEnabled: false, endsAt: nil)
        }

        updateCurrentUserAvailability(userID: user.id) { availability in
            UserAvailability(
                presence: availability.presence,
                customStatus: availability.customStatus,
                doNotDisturb: doNotDisturb,
                fetchedAt: .now
            )
        }
    }

    private func currentUserOrThrow() throws -> WorkspaceUser {
        guard let currentUser else {
            throw ProfileSettingsError.currentUserUnavailable
        }
        return currentUser
    }

    private func updateCurrentUserAvailability(
        userID: String,
        transform: (UserAvailability) -> UserAvailability
    ) {
        guard let latestUser = user(withID: userID) else {
            return
        }
        updateAvailability(transform(latestUser.availability), for: userID)
    }

    private func translatedProfileMutationError(_ error: Error) -> Error {
        if let apiError = error as? SlackAPIClient.APIError,
           apiError == .slack("missing_scope")
        {
            return ProfileSettingsError.reconnectRequired
        }
        return error
    }
}
