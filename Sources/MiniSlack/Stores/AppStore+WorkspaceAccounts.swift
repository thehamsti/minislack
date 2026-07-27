import Foundation

@MainActor
extension AppStore {
    func refreshWorkspaceAccounts() {
        guard let credentialStore else {
            workspaceAccounts = []
            return
        }
        do {
            workspaceAccounts = try credentialStore.loadCollection().accountSummaries
        } catch {
            transientError = error.localizedDescription
        }
    }

    func switchWorkspace(to teamID: String) async throws {
        guard let credentialStore else {
            throw SlackCredentialStore.StoreError.workspaceNotFound
        }
        let existingCredentials = credentials
        let selectedCredentials = try credentialStore.select(teamID: teamID)
        refreshWorkspaceAccounts()
        guard credentials?.teamID != teamID else {
            return
        }

        clearWorkspaceSession()
        let replacementGeneration = workspaceSessionGeneration
        do {
            try await connect(with: selectedCredentials)
        } catch {
            let connectionError = error
            guard replacementGeneration == workspaceSessionGeneration else {
                throw connectionError
            }
            if let existingCredentials {
                do {
                    try await connect(with: existingCredentials)
                    transientError = connectionError.localizedDescription
                } catch {
                    connectionState = .failed(
                        "Could not switch workspaces, and \(existingCredentials.teamName) "
                            + "could not be restored: \(error.localizedDescription)"
                    )
                }
            } else {
                connectionState = .failed(connectionError.localizedDescription)
            }
            throw connectionError
        }
    }

    func removeWorkspace(teamID: String) throws {
        guard let credentialStore else {
            return
        }
        try credentialStore.delete(teamID: teamID)
        if credentials?.teamID == teamID {
            clearWorkspaceSession()
        }
        refreshWorkspaceAccounts()
    }
}
