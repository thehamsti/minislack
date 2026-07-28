import Foundation

@MainActor
extension AppStore {
    var activityItems: [ActivityItem] {
        activityIndex.items
    }

    var unreadActivityCount: Int {
        activityItems.lazy.filter { $0.date > self.activityLastViewedAt }.count
    }

    func showActivityInbox() {
        destination = .activity
    }

    func markActivityRead() {
        activityLastViewedAt = .now
        guard let teamID = credentials?.teamID else {
            return
        }
        UserDefaults.standard.set(
            activityLastViewedAt.timeIntervalSince1970,
            forKey: activityReadDefaultsKey(teamID: teamID)
        )
    }

    func openActivity(_ item: ActivityItem, windowState: WindowState) {
        openMessage(conversationID: item.conversationID, messageID: item.messageID)
        guard let threadIdentifier = item.threadIdentifier else {
            return
        }
        if threadStates[threadIdentifier] == nil,
           let conversation = conversations.first(where: {
               $0.id == item.conversationID
           }),
           let message = conversation.messages.first(where: {
               $0.id == item.messageID
           })
        {
            var state = ThreadState(id: threadIdentifier, root: message)
            state.isFollowing = message.thread?.isFollowing == true
            threadStates[threadIdentifier] = state
        }
        if threadStates[threadIdentifier] != nil {
            windowState.presentThread(threadIdentifier)
        }
    }

    func resetActivity(
        conversations: [Conversation],
        currentUserID: String?,
        teamID: String?
    ) {
        activityIndex.reset(
            conversations: conversations,
            currentUserID: currentUserID
        )
        guard let teamID else {
            activityLastViewedAt = .distantPast
            return
        }
        let timestamp = UserDefaults.standard.double(
            forKey: activityReadDefaultsKey(teamID: teamID)
        )
        activityLastViewedAt = timestamp > 0
            ? Date(timeIntervalSince1970: timestamp)
            : .distantPast
    }

    private func activityReadDefaultsKey(teamID: String) -> String {
        "activity.lastViewed.\(teamID)"
    }
}
