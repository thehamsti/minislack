import AppKit
import Foundation
import Observation

struct ConversationHistoryState: Equatable, Sendable {
    var hasLoadedInitial = false
    var isLoadingInitial = false
    var isLoadingOlder = false
    var canLoadOlder = false
    var errorMessage: String?
}

@MainActor
@Observable
final class AppStore {
    enum ConnectionState: Equatable {
        case preview
        case needsConfiguration
        case disconnected
        case authorizing
        case loading
        case connected(String)
        case failed(String)
    }

    enum Destination: Hashable {
        case unreadInbox
        case conversation(String)
    }

    enum QuickSwitcherItem: Hashable, Identifiable {
        case unreads
        case user(String)
        case channel(String)

        var id: String {
            switch self {
            case .unreads:
                "destination-unreads"
            case let .user(id):
                "user-\(id)"
            case let .channel(id):
                "channel-\(id)"
            }
        }
    }

    var conversations: [Conversation]
    var users: [WorkspaceUser]
    var customEmojiURLs: [String: URL]
    var connectionState: ConnectionState
    var transientError: String?
    var destination: Destination = .unreadInbox
    private var draftsByConversationID: [String: ComposerDraft] = [:]
    private var composerSuggestionIndex: ComposerSuggestionIndex
    var quickSwitcherQuery = ""
    var quickSwitcherSelection: QuickSwitcherItem?
    var keyboardConversationID: String?
    private(set) var historyStates: [String: ConversationHistoryState] = [:]
    private let slackOAuth: SlackOAuthService?
    private let credentialStore: SlackCredentialStore?
    private let slackAPI: SlackAPIClient?
    private var credentials: SlackCredentials?
    private var messageUsers: [WorkspaceUser]
    private var usersByID: [String: WorkspaceUser]
    private var historyCache: MessageHistoryCache?
    private var loadedHistoryPageCounts: [String: Int] = [:]
    private var historyBackfillTask: Task<Void, Never>?
    private var availabilityRefreshTask: Task<Void, Never>?
    private var canRefreshDoNotDisturb = true
    private var backfillConversationIndex = 0

    init(
        conversations: [Conversation] = SampleData.conversations(),
        users: [WorkspaceUser] = SampleData.users,
        customEmojiURLs: [String: URL] = [:],
        connectionState: ConnectionState = .preview,
        slackOAuth: SlackOAuthService? = nil,
        credentialStore: SlackCredentialStore? = nil,
        slackAPI: SlackAPIClient? = nil
    ) {
        self.conversations = conversations
        self.users = users
        self.customEmojiURLs = customEmojiURLs
        self.connectionState = connectionState
        self.slackOAuth = slackOAuth
        self.credentialStore = credentialStore
        self.slackAPI = slackAPI
        messageUsers = users
        usersByID = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
        composerSuggestionIndex = ComposerSuggestionIndex(
            users: users,
            conversations: conversations
        )
        keyboardConversationID = unreadConversations.first?.id
    }

    static func live() -> AppStore {
        guard let configuration = SlackConfiguration.bundled() else {
            return AppStore(
                conversations: [],
                users: [],
                connectionState: .needsConfiguration
            )
        }
        return AppStore(
            conversations: [],
            users: [],
            connectionState: .disconnected,
            slackOAuth: SlackOAuthService(configuration: configuration),
            credentialStore: SlackCredentialStore(),
            slackAPI: SlackAPIClient()
        )
    }

    var unreadConversations: [Conversation] {
        conversations
            .filter(\.isUnread)
            .sorted {
                if $0.mentionCount != $1.mentionCount {
                    return $0.mentionCount > $1.mentionCount
                }
                return $0.latestActivity > $1.latestActivity
            }
    }

    var selectedConversation: Conversation? {
        guard case let .conversation(id) = destination else {
            return nil
        }
        return conversations.first { $0.id == id }
    }

    func user(withID userID: String) -> WorkspaceUser? {
        usersByID[userID]
    }

    var composerDraft: ComposerDraft {
        get {
            guard case let .conversation(id) = destination else {
                return ComposerDraft()
            }
            return draftsByConversationID[id] ?? ComposerDraft()
        }
        set {
            guard case let .conversation(id) = destination else {
                return
            }
            if newValue.isEmpty {
                draftsByConversationID.removeValue(forKey: id)
            } else {
                draftsByConversationID[id] = newValue
            }
        }
    }

    var draft: String {
        get {
            composerDraft.text
        }
        set {
            composerDraft = ComposerDraft(text: newValue)
        }
    }

    func composerSuggestions(
        for query: ComposerQuery,
        allowsBroadcasts: Bool
    ) -> [ComposerSuggestion] {
        composerSuggestionIndex.matches(
            query: query,
            allowsBroadcasts: allowsBroadcasts
        )
    }

    var favoriteConversations: [Conversation] {
        sortedFavoriteConversations(by: .activity)
    }

    var channelConversations: [Conversation] {
        sortedChannelConversations(by: .activity)
    }

    var directConversations: [Conversation] {
        sortedDirectConversations(by: .activity)
    }

    var groupDirectConversations: [Conversation] {
        sortedGroupDirectConversations(by: .activity)
    }

    func sortedUnreadConversations(by option: ConversationSortOption) -> [Conversation] {
        sortedConversations(conversations.filter(\.isUnread), by: option)
    }

    func sortedFavoriteConversations(by option: ConversationSortOption) -> [Conversation] {
        sortedConversations(conversations.filter(\.isFavorite), by: option)
    }

    func sortedChannelConversations(by option: ConversationSortOption) -> [Conversation] {
        sortedConversations(
            conversations.filter { $0.kind == .channel && !$0.isFavorite },
            by: option
        )
    }

    func sortedDirectConversations(by option: ConversationSortOption) -> [Conversation] {
        sortedConversations(
            conversations.filter { $0.kind == .directMessage && !$0.isFavorite },
            by: option
        )
    }

    func sortedGroupDirectConversations(by option: ConversationSortOption) -> [Conversation] {
        sortedConversations(
            conversations.filter { $0.kind == .groupDirectMessage && !$0.isFavorite },
            by: option
        )
    }

    var quickSwitcherShowsUnreads: Bool {
        normalizedQuickSwitcherQuery.isEmpty
            || "unreads".localizedCaseInsensitiveContains(normalizedQuickSwitcherQuery)
    }

    var quickSwitcherUsers: [WorkspaceUser] {
        guard !normalizedQuickSwitcherQuery.isEmpty else {
            return users
        }
        return users.filter {
            $0.displayName.localizedCaseInsensitiveContains(normalizedQuickSwitcherQuery)
                || $0.status.localizedCaseInsensitiveContains(normalizedQuickSwitcherQuery)
        }
    }

    var quickSwitcherChannels: [Conversation] {
        let channels = sortedByLatestActivity(
            conversations.filter { $0.kind == .channel }
        )
        guard !normalizedQuickSwitcherQuery.isEmpty else {
            return channels
        }
        return channels.filter {
            $0.title.localizedCaseInsensitiveContains(normalizedQuickSwitcherQuery)
                || ($0.subtitle?.localizedCaseInsensitiveContains(normalizedQuickSwitcherQuery) ?? false)
        }
    }

    var quickSwitcherGroupMessages: [Conversation] {
        let groups = sortedByLatestActivity(
            conversations.filter { $0.kind == .groupDirectMessage }
        )
        guard !normalizedQuickSwitcherQuery.isEmpty else {
            return groups
        }
        return groups.filter {
            $0.title.localizedCaseInsensitiveContains(normalizedQuickSwitcherQuery)
                || ($0.subtitle?.localizedCaseInsensitiveContains(normalizedQuickSwitcherQuery) ?? false)
        }
    }

    var hasQuickSwitcherResults: Bool {
        quickSwitcherShowsUnreads
            || !quickSwitcherUsers.isEmpty
            || !quickSwitcherGroupMessages.isEmpty
            || !quickSwitcherChannels.isEmpty
    }

    var quickSwitcherItems: [QuickSwitcherItem] {
        var items: [QuickSwitcherItem] = []
        if quickSwitcherShowsUnreads {
            items.append(.unreads)
        }
        items.append(contentsOf: quickSwitcherUsers.map { .user($0.id) })
        items.append(contentsOf: quickSwitcherGroupMessages.map { .channel($0.id) })
        items.append(contentsOf: quickSwitcherChannels.map { .channel($0.id) })
        return items
    }

    func select(_ conversationID: String) {
        keyboardConversationID = conversationID
        destination = .conversation(conversationID)
    }

    func loadInitialHistory(for conversationID: String) async {
        await loadMessages(for: conversationID)
    }

    func historyState(for conversationID: String) -> ConversationHistoryState {
        historyStates[conversationID] ?? ConversationHistoryState()
    }

    func loadOlderMessages(for conversationID: String) {
        Task {
            await loadOlderHistory(for: conversationID)
        }
    }

    func retryHistory(for conversationID: String) {
        Task {
            await loadMessages(for: conversationID)
        }
    }

    func showUnreadInbox() {
        destination = .unreadInbox
        ensureKeyboardSelection()
    }

    func openUnreadFromQuickSwitcher() {
        showUnreadInbox()
        dismissQuickSwitcher()
    }

    func startDirectMessage(with userID: String) {
        guard let user = users.first(where: { $0.id == userID }) else {
            return
        }

        if slackAPI != nil {
            dismissQuickSwitcher()
            Task {
                await openLiveDirectMessage(with: user)
            }
        } else if let existing = conversations.first(where: {
            ($0.id == userID || $0.participantUserID == userID) && $0.kind == .directMessage
        }) {
            select(existing.id)
        } else {
            conversations.append(
                Conversation(
                    id: user.id,
                    title: user.displayName,
                    kind: .directMessage,
                    subtitle: user.status,
                    isFavorite: false,
                    createdAt: .now,
                    participantUserID: user.id,
                    avatarURL: user.avatarURL,
                    participants: [user],
                    unreadCount: 0,
                    mentionCount: 0,
                    latestActivity: .now,
                    messages: []
                )
            )
            select(userID)
            dismissQuickSwitcher()
        }
    }

    func openChannelFromQuickSwitcher(_ conversationID: String) {
        select(conversationID)
        dismissQuickSwitcher()
    }

    func openFirstQuickSwitcherResult() {
        ensureQuickSwitcherSelection()
        openQuickSwitcherSelection()
    }

    func ensureQuickSwitcherSelection() {
        let items = quickSwitcherItems
        guard !items.isEmpty else {
            quickSwitcherSelection = nil
            return
        }
        if quickSwitcherSelection.map(items.contains) != true {
            quickSwitcherSelection = items.first
        }
    }

    func moveQuickSwitcherSelection(offset: Int) {
        ensureQuickSwitcherSelection()
        let items = quickSwitcherItems
        guard let quickSwitcherSelection,
              let currentIndex = items.firstIndex(of: quickSwitcherSelection)
        else {
            return
        }

        let nextIndex = (currentIndex + offset + items.count) % items.count
        self.quickSwitcherSelection = items[nextIndex]
    }

    func openQuickSwitcherSelection() {
        ensureQuickSwitcherSelection()
        guard let quickSwitcherSelection else {
            return
        }

        switch quickSwitcherSelection {
        case .unreads:
            openUnreadFromQuickSwitcher()
        case let .user(id):
            startDirectMessage(with: id)
        case let .channel(id):
            openChannelFromQuickSwitcher(id)
        }
    }

    func dismissQuickSwitcher() {
        quickSwitcherQuery = ""
        quickSwitcherSelection = nil
    }

    func handleKeyboardNavigation(_ action: KeyboardNavigationAction) {
        switch action {
        case .next:
            moveKeyboardSelection(offset: 1)
        case .previous:
            moveKeyboardSelection(offset: -1)
        case .open:
            openKeyboardSelection()
        case .back:
            showUnreadInbox()
        }
    }

    func ensureKeyboardSelection() {
        let ids = keyboardNavigationIDs
        guard !ids.isEmpty else {
            keyboardConversationID = nil
            return
        }

        if keyboardConversationID.map(ids.contains) != true {
            keyboardConversationID = ids.first
        }
    }

    func moveKeyboardSelection(offset: Int) {
        let ids = keyboardNavigationIDs
        guard !ids.isEmpty else {
            keyboardConversationID = nil
            return
        }

        let currentID: String? = switch destination {
        case .unreadInbox:
            keyboardConversationID
        case let .conversation(id):
            id
        }
        let currentIndex = currentID.flatMap(ids.firstIndex(of:)) ?? (offset < 0 ? 0 : -1)
        let nextIndex = (currentIndex + offset + ids.count) % ids.count
        let nextID = ids[nextIndex]
        keyboardConversationID = nextID

        if case .conversation = destination {
            destination = .conversation(nextID)
        }
    }

    func openKeyboardSelection() {
        guard case .unreadInbox = destination else {
            return
        }
        ensureKeyboardSelection()
        if let keyboardConversationID {
            select(keyboardConversationID)
        }
    }

    func moveToUnread(offset: Int) {
        let unreadIDs = unreadConversations.map(\.id)
        guard let first = unreadIDs.first else {
            return
        }

        guard case let .conversation(currentID) = destination,
              let currentIndex = unreadIDs.firstIndex(of: currentID)
        else {
            select(offset < 0 ? unreadIDs.last ?? first : first)
            return
        }

        let nextIndex = (currentIndex + offset + unreadIDs.count) % unreadIDs.count
        select(unreadIDs[nextIndex])
    }

    func markSelectedConversationRead() {
        guard case let .conversation(id) = destination,
              let index = conversations.firstIndex(where: { $0.id == id })
        else {
            return
        }
        let timestamp = conversations[index].messages.last?.remoteID
        conversations[index].unreadCount = 0
        conversations[index].mentionCount = 0
        if let timestamp, slackAPI != nil {
            Task {
                await markLiveConversationRead(channelID: id, timestamp: timestamp)
            }
        }
    }

    func sendDraft() {
        let activeDraft = composerDraft
        let displayText = activeDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingText = activeDraft.slackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayText.isEmpty,
              case let .conversation(id) = destination,
              let index = conversations.firstIndex(where: { $0.id == id })
        else {
            return
        }

        let currentUser = credentials.flatMap { credentials in
            users.first { $0.id == credentials.userID }
        }
        let optimisticMessage = Message(
            author: currentUser?.displayName ?? "You",
            authorUserID: currentUser?.id,
            body: outgoingText,
            timestamp: .now,
            authorAvatarURL: currentUser?.avatarURL,
            isCurrentUser: true,
            displayBody: SlackEmoji.replacingUnicodeShortcodes(in: displayText)
        )
        conversations[index].messages.append(optimisticMessage)
        conversations[index].latestActivity = .now
        composerDraft = ComposerDraft()
        if slackAPI != nil {
            Task {
                await sendLiveMessage(
                    channelID: id,
                    text: outgoingText,
                    localMessageID: optimisticMessage.id
                )
            }
        }
    }

    func restoreSession() async {
        guard connectionState == .disconnected,
              let credentialStore
        else {
            return
        }
        do {
            guard let storedCredentials = try credentialStore.load() else {
                return
            }
            try await connect(with: storedCredentials)
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    func signInWithSlack() async {
        guard let slackOAuth else {
            connectionState = .needsConfiguration
            return
        }
        do {
            let url = try await slackOAuth.beginAuthorization()
            connectionState = .authorizing
            guard NSWorkspace.shared.open(url) else {
                connectionState = .failed("Could not open Slack in your browser.")
                return
            }
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    func handleSlackCallback(_ url: URL) async {
        guard url.scheme == "minislack", let slackOAuth else {
            return
        }
        connectionState = .loading
        do {
            let newCredentials = try await slackOAuth.handleCallback(url)
            try await connect(with: newCredentials)
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    func cancelSlackSignIn() async {
        await slackOAuth?.cancelAuthorization()
        connectionState = .disconnected
    }

    func retrySlackConnection() async {
        if let credentials {
            do {
                try await connect(with: credentials)
            } catch {
                connectionState = .failed(error.localizedDescription)
            }
        } else {
            connectionState = .disconnected
        }
    }

    func signOut() {
        historyBackfillTask?.cancel()
        historyBackfillTask = nil
        availabilityRefreshTask?.cancel()
        availabilityRefreshTask = nil
        do {
            try credentialStore?.delete()
        } catch {
            transientError = error.localizedDescription
        }
        credentials = nil
        users = []
        messageUsers = []
        usersByID = [:]
        customEmojiURLs = [:]
        conversations = []
        draftsByConversationID = [:]
        composerSuggestionIndex = ComposerSuggestionIndex(users: [], conversations: [])
        historyStates = [:]
        loadedHistoryPageCounts = [:]
        historyCache = nil
        destination = .unreadInbox
        connectionState = .disconnected
    }

    private func connect(with proposedCredentials: SlackCredentials) async throws {
        guard let slackOAuth, let credentialStore, let slackAPI else {
            return
        }
        connectionState = .loading
        let activeCredentials: SlackCredentials
        if proposedCredentials.needsRefresh() {
            activeCredentials = try await slackOAuth.refresh(proposedCredentials)
        } else {
            activeCredentials = proposedCredentials
        }
        try credentialStore.save(activeCredentials)
        let snapshot = try await slackAPI.fetchWorkspace(
            accessToken: activeCredentials.accessToken,
            currentUserID: activeCredentials.userID
        )
        credentials = activeCredentials
        historyCache = MessageHistoryCache(workspaceID: activeCredentials.teamID)
        users = snapshot.users
        messageUsers = snapshot.messageUsers
        usersByID = Dictionary(
            uniqueKeysWithValues: snapshot.messageUsers.map { ($0.id, $0) }
        )
        customEmojiURLs = snapshot.customEmojiURLs
        conversations = snapshot.conversations
        composerSuggestionIndex = ComposerSuggestionIndex(
            users: snapshot.users,
            conversations: snapshot.conversations
        )
        destination = .unreadInbox
        keyboardConversationID = unreadConversations.first?.id
        connectionState = .connected(activeCredentials.teamName)
        canRefreshDoNotDisturb = true
        Task {
            await refreshConversationMetadata(accessToken: activeCredentials.accessToken)
        }
        startHistoryBackfill()
        startAvailabilityRefresh()
    }

    private func activeCredentials() async throws -> SlackCredentials {
        guard let credentials, let slackOAuth, let credentialStore else {
            throw SlackOAuthService.OAuthError.invalidTokenResponse
        }
        guard credentials.needsRefresh() else {
            return credentials
        }
        let refreshed = try await slackOAuth.refresh(credentials)
        try credentialStore.save(refreshed)
        self.credentials = refreshed
        return refreshed
    }

    private func loadMessages(for channelID: String) async {
        guard let slackAPI,
              historyStates[channelID]?.isLoadingInitial != true
        else {
            return
        }
        historyStates[channelID, default: ConversationHistoryState()].isLoadingInitial = true
        historyStates[channelID]?.errorMessage = nil

        if let historyCache,
           let cachedPage = try? await historyCache.page(channelID: channelID, index: 0)
        {
            apply(cachedPage.messages, to: channelID)
            historyStates[channelID]?.hasLoadedInitial = true
            loadedHistoryPageCounts[channelID] = 1
            let status = try? await historyCache.status(channelID: channelID)
            historyStates[channelID]?.canLoadOlder =
                (status?.pageCount ?? 0) > 1 || cachedPage.nextCursor != nil
        }

        do {
            let credentials = try await activeCredentials()
            let page = try await slackAPI.fetchMessagePage(
                channelID: channelID,
                accessToken: credentials.accessToken,
                users: messageUsers,
                channelNames: conversationNamesByID,
                currentUserID: credentials.userID
            )
            if let historyCache {
                try? await historyCache.mergeLatest(
                    MessageHistoryPage(messages: page.messages, nextCursor: page.nextCursor),
                    channelID: channelID
                )
            }
            apply(page.messages, to: channelID)
            loadedHistoryPageCounts[channelID] = max(loadedHistoryPageCounts[channelID] ?? 0, 1)
            let cachedStatus = try? await historyCache?.status(channelID: channelID)
            historyStates[channelID]?.canLoadOlder =
                (cachedStatus?.pageCount ?? 0) > 1 || page.nextCursor != nil
            historyStates[channelID]?.hasLoadedInitial = true
            historyStates[channelID]?.isLoadingInitial = false

            if let index = conversations.firstIndex(where: { $0.id == channelID }),
               let latest = conversations[index].messages.last
            {
                conversations[index].latestActivity = latest.timestamp
                let preference = UserDefaults.standard.object(forKey: "markReadOnOpen")
                let shouldMarkRead = preference == nil
                    || UserDefaults.standard.bool(forKey: "markReadOnOpen")
                if destination == .conversation(channelID), shouldMarkRead {
                    conversations[index].unreadCount = 0
                    conversations[index].mentionCount = 0
                    if let timestamp = latest.remoteID {
                        await markLiveConversationRead(channelID: channelID, timestamp: timestamp)
                    }
                }
            }
        } catch {
            historyStates[channelID]?.hasLoadedInitial = true
            historyStates[channelID]?.isLoadingInitial = false
            historyStates[channelID]?.errorMessage = error.localizedDescription
        }
    }

    private func loadOlderHistory(for channelID: String) async {
        guard let slackAPI,
              let historyCache,
              historyStates[channelID]?.isLoadingOlder != true,
              historyStates[channelID]?.canLoadOlder == true
        else {
            return
        }
        historyStates[channelID]?.isLoadingOlder = true
        historyStates[channelID]?.errorMessage = nil

        let pageIndex = loadedHistoryPageCounts[channelID] ?? 1
        if let cachedPage = try? await historyCache.page(channelID: channelID, index: pageIndex) {
            apply(cachedPage.messages, to: channelID)
            loadedHistoryPageCounts[channelID] = pageIndex + 1
            let status = try? await historyCache.status(channelID: channelID)
            historyStates[channelID]?.canLoadOlder =
                (status?.pageCount ?? 0) > pageIndex + 1 || cachedPage.nextCursor != nil
            historyStates[channelID]?.isLoadingOlder = false
            return
        }

        guard let previousPage = try? await historyCache.page(
            channelID: channelID,
            index: pageIndex - 1
        ), let cursor = previousPage.nextCursor
        else {
            historyStates[channelID]?.canLoadOlder = false
            historyStates[channelID]?.isLoadingOlder = false
            return
        }

        do {
            let credentials = try await activeCredentials()
            let page = try await slackAPI.fetchMessagePage(
                channelID: channelID,
                cursor: cursor,
                accessToken: credentials.accessToken,
                users: messageUsers,
                channelNames: conversationNamesByID,
                currentUserID: credentials.userID
            )
            let cachedPage = MessageHistoryPage(
                messages: page.messages,
                nextCursor: page.nextCursor
            )
            try await historyCache.store(cachedPage, channelID: channelID, index: pageIndex)
            apply(page.messages, to: channelID)
            loadedHistoryPageCounts[channelID] = pageIndex + 1
            historyStates[channelID]?.canLoadOlder = page.nextCursor != nil
        } catch {
            historyStates[channelID]?.errorMessage = error.localizedDescription
        }
        historyStates[channelID]?.isLoadingOlder = false
    }

    private func openLiveDirectMessage(with user: WorkspaceUser) async {
        if let existing = conversations.first(where: { $0.participantUserID == user.id }) {
            select(existing.id)
            return
        }
        guard let slackAPI else {
            return
        }
        do {
            let credentials = try await activeCredentials()
            let channelID = try await slackAPI.openDirectMessage(
                userID: user.id,
                accessToken: credentials.accessToken
            )
            if !conversations.contains(where: { $0.id == channelID }) {
                conversations.append(
                    Conversation(
                        id: channelID,
                        title: user.displayName,
                        kind: .directMessage,
                        subtitle: user.status,
                        isFavorite: false,
                        createdAt: .now,
                        participantUserID: user.id,
                        avatarURL: user.avatarURL,
                        participants: [user],
                        unreadCount: 0,
                        mentionCount: 0,
                        latestActivity: .now,
                        messages: []
                    )
                )
            }
            select(channelID)
        } catch {
            transientError = error.localizedDescription
        }
    }

    private func sendLiveMessage(channelID: String, text: String, localMessageID: UUID) async {
        guard let slackAPI else {
            return
        }
        do {
            let credentials = try await activeCredentials()
            let sentMessage = try await slackAPI.sendMessage(
                channelID: channelID,
                text: text,
                accessToken: credentials.accessToken
            )
            guard let conversationIndex = conversations.firstIndex(where: { $0.id == channelID }),
                  let messageIndex = conversations[conversationIndex].messages.firstIndex(where: {
                      $0.id == localMessageID
                  })
            else {
                return
            }
            conversations[conversationIndex].messages[messageIndex].remoteID = sentMessage.timestamp
        } catch {
            transientError = error.localizedDescription
        }
    }

    private func markLiveConversationRead(channelID: String, timestamp: String) async {
        guard let slackAPI else {
            return
        }
        do {
            let credentials = try await activeCredentials()
            try await slackAPI.markRead(
                channelID: channelID,
                timestamp: timestamp,
                accessToken: credentials.accessToken
            )
        } catch {
            transientError = error.localizedDescription
        }
    }

    private var keyboardNavigationIDs: [String] {
        switch destination {
        case .unreadInbox:
            return unreadConversations.map(\.id)
        case .conversation:
            let unreadIDs = unreadConversations.map(\.id)
            return unreadIDs + conversations.map(\.id).filter { !unreadIDs.contains($0) }
        }
    }

    private var normalizedQuickSwitcherQuery: String {
        quickSwitcherQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var conversationNamesByID: [String: String] {
        Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0.title) })
    }

    private func sortedByLatestActivity(_ conversations: [Conversation]) -> [Conversation] {
        sortedConversations(conversations, by: .activity)
    }

    private func sortedConversations(
        _ conversations: [Conversation],
        by option: ConversationSortOption
    ) -> [Conversation] {
        conversations.sorted {
            switch option {
            case .activity where $0.latestActivity != $1.latestActivity:
                return $0.latestActivity > $1.latestActivity
            case .creation where $0.createdAt != $1.createdAt:
                return $0.createdAt > $1.createdAt
            default:
                let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                return $0.id < $1.id
            }
        }
    }

    private func apply(_ messages: [Message], to channelID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == channelID }) else {
            return
        }
        var messagesByID: [String: Message] = [:]
        for message in conversations[index].messages {
            let key = message.remoteID.map { "remote:\($0)" } ?? "local:\(message.id)"
            messagesByID[key] = message
        }
        let formattingContext = SlackMessageFormatting.Context(
            userNames: Dictionary(
                uniqueKeysWithValues: messageUsers.map { ($0.id, $0.displayName) }
            ),
            channelNames: conversationNamesByID
        )
        for message in messages {
            let message = message.preparingForDisplay(context: formattingContext)
            let key = message.remoteID.map { "remote:\($0)" } ?? "local:\(message.id)"
            messagesByID[key] = message
        }
        conversations[index].messages = messagesByID.values.sorted {
            $0.timestamp < $1.timestamp
        }
    }

    func updateAvailability(_ availability: UserAvailability, for userID: String) {
        guard let user = usersByID[userID] else {
            return
        }
        let updated = WorkspaceUser(
            id: user.id,
            displayName: user.displayName,
            profileTitle: user.profileTitle,
            availability: availability,
            avatarURL: user.avatarURL
        )
        usersByID[userID] = updated
        if let index = users.firstIndex(where: { $0.id == userID }) {
            users[index] = updated
        }
        if let index = messageUsers.firstIndex(where: { $0.id == userID }) {
            messageUsers[index] = updated
        }
    }

    private func applyUserProfiles(_ profiles: [WorkspaceUser]) {
        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let mergedByID = usersByID.mapValues { current in
            guard let profile = profilesByID[current.id] else {
                return current
            }
            let presence: UserPresence = if profile.availability.presence == .notApplicable {
                .notApplicable
            } else if current.availability.presence == .notApplicable {
                .unknown
            } else {
                current.availability.presence
            }
            return WorkspaceUser(
                id: profile.id,
                displayName: profile.displayName,
                profileTitle: profile.profileTitle,
                availability: UserAvailability(
                    presence: presence,
                    customStatus: profile.availability.customStatus,
                    doNotDisturb: current.availability.doNotDisturb,
                    fetchedAt: current.availability.fetchedAt
                ),
                avatarURL: profile.avatarURL
            )
        }
        usersByID = mergedByID
        users = users.map { mergedByID[$0.id] ?? $0 }
        messageUsers = messageUsers.map { mergedByID[$0.id] ?? $0 }
        for index in conversations.indices {
            conversations[index].participants = conversations[index].participants.map {
                mergedByID[$0.id] ?? $0
            }
            if let userID = conversations[index].participantUserID,
               let participant = mergedByID[userID]
            {
                conversations[index].title = participant.displayName
                conversations[index].avatarURL = participant.avatarURL
            } else if conversations[index].kind == .groupDirectMessage,
                      !conversations[index].participants.isEmpty
            {
                conversations[index].title = conversations[index].participants
                    .map(\.displayName)
                    .joined(separator: ", ")
            }
        }
        composerSuggestionIndex = ComposerSuggestionIndex(
            users: users,
            conversations: conversations
        )
    }

    private func applyDoNotDisturb(_ statuses: [String: UserDoNotDisturb]) {
        var updatedByID = usersByID
        for (userID, doNotDisturb) in statuses {
            guard let user = updatedByID[userID] else {
                continue
            }
            updatedByID[userID] = WorkspaceUser(
                id: user.id,
                displayName: user.displayName,
                profileTitle: user.profileTitle,
                availability: UserAvailability(
                    presence: user.availability.presence,
                    customStatus: user.availability.customStatus,
                    doNotDisturb: doNotDisturb,
                    fetchedAt: user.availability.fetchedAt
                ),
                avatarURL: user.avatarURL
            )
        }
        usersByID = updatedByID
        users = users.map { updatedByID[$0.id] ?? $0 }
        messageUsers = messageUsers.map { updatedByID[$0.id] ?? $0 }
    }

    private func startAvailabilityRefresh() {
        availabilityRefreshTask?.cancel()
        availabilityRefreshTask = Task { [weak self] in
            await self?.runAvailabilityRefresh()
        }
    }

    private func runAvailabilityRefresh() async {
        var nextProfileRefresh = Date.now.addingTimeInterval(300)
        while !Task.isCancelled {
            guard let slackAPI else {
                return
            }
            guard let credentials = try? await activeCredentials() else {
                try? await Task.sleep(for: .seconds(30))
                continue
            }

            if Date.now >= nextProfileRefresh {
                if let profiles = try? await slackAPI.fetchWorkspaceUsers(
                    accessToken: credentials.accessToken
                ) {
                    applyUserProfiles(profiles)
                }
                nextProfileRefresh = Date.now.addingTimeInterval(300)
            }

            let userIDs = availabilityPriorityUserIDs
            if canRefreshDoNotDisturb, !userIDs.isEmpty {
                do {
                    let statuses = try await slackAPI.fetchDoNotDisturb(
                        userIDs: userIDs,
                        accessToken: credentials.accessToken
                    )
                    applyDoNotDisturb(statuses)
                } catch let SlackAPIClient.APIError.slack(error) where error == "missing_scope" {
                    canRefreshDoNotDisturb = false
                } catch let SlackAPIClient.APIError.rateLimited(seconds) {
                    try? await Task.sleep(for: .seconds(seconds))
                } catch {
                    // Presence can still refresh when DND is unavailable.
                }
            }

            for userID in userIDs {
                guard !Task.isCancelled else {
                    return
                }
                guard let user = usersByID[userID] else {
                    continue
                }
                do {
                    let presence = try await slackAPI.fetchPresence(
                        userID: userID,
                        currentUserID: credentials.userID,
                        accessToken: credentials.accessToken
                    )
                    updateAvailability(
                        UserAvailability(
                            presence: presence,
                            customStatus: user.availability.customStatus,
                            doNotDisturb: user.availability.doNotDisturb,
                            fetchedAt: .now
                        ),
                        for: userID
                    )
                } catch let SlackAPIClient.APIError.rateLimited(seconds) {
                    try? await Task.sleep(for: .seconds(seconds))
                } catch {
                    // Keep the last truthful state until the next refresh.
                }
                try? await Task.sleep(for: .milliseconds(1_250))
            }

            try? await Task.sleep(for: .seconds(60))
        }
    }

    private var availabilityPriorityUserIDs: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        func append(_ userID: String?) {
            guard let userID,
                  seen.insert(userID).inserted,
                  usersByID[userID]?.availability.presence != .notApplicable
            else {
                return
            }
            result.append(userID)
        }

        append(credentials?.userID)
        if let selectedConversation {
            append(selectedConversation.participantUserID)
            selectedConversation.participants.forEach { append($0.id) }
            selectedConversation.messages.suffix(50).forEach { append($0.authorUserID) }
        }
        for conversation in conversations.sorted(by: { $0.latestActivity > $1.latestActivity }) {
            append(conversation.participantUserID)
            conversation.participants.forEach { append($0.id) }
        }
        users
            .sorted { lhs, rhs in
                if lhs.availability.presence != rhs.availability.presence {
                    return lhs.availability.presence == .active
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                    == .orderedAscending
            }
            .forEach { append($0.id) }
        return result
    }

    private func startHistoryBackfill() {
        historyBackfillTask?.cancel()
        historyBackfillTask = Task { [weak self] in
            await self?.runHistoryBackfill()
        }
    }

    private func runHistoryBackfill() async {
        while !Task.isCancelled {
            let speed = HistoryBackfillSpeed.current
            guard let interval = speed.requestInterval else {
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            let retryDelay = await backfillNextHistoryPage()
            try? await Task.sleep(for: retryDelay ?? interval)
        }
    }

    private func backfillNextHistoryPage() async -> Duration? {
        guard let slackAPI, let historyCache, !conversations.isEmpty else {
            return nil
        }

        for offset in conversations.indices {
            let index = (backfillConversationIndex + offset) % conversations.count
            let conversationID = conversations[index].id
            guard let status = try? await historyCache.status(channelID: conversationID),
                  !status.isComplete
            else {
                continue
            }

            backfillConversationIndex = (index + 1) % conversations.count
            do {
                let credentials = try await activeCredentials()
                let page = try await slackAPI.fetchMessagePage(
                    channelID: conversationID,
                    cursor: status.pageCount == 0 ? nil : status.nextCursor,
                    accessToken: credentials.accessToken,
                    users: messageUsers,
                    channelNames: conversationNamesByID,
                    currentUserID: credentials.userID
                )
                try await historyCache.store(
                    MessageHistoryPage(messages: page.messages, nextCursor: page.nextCursor),
                    channelID: conversationID,
                    index: status.pageCount
                )
                return nil
            } catch let SlackAPIClient.APIError.rateLimited(seconds) {
                return .seconds(seconds)
            } catch {
                return nil
            }
        }
        return .seconds(30)
    }

    private func refreshConversationMetadata(accessToken: String) async {
        guard let slackAPI else {
            return
        }
        let conversationIDs = conversations.map(\.id)
        await withTaskGroup(of: SlackConversationMetadata?.self) { group in
            for conversationID in conversationIDs {
                group.addTask {
                    try? await slackAPI.fetchConversationMetadata(
                        channelID: conversationID,
                        accessToken: accessToken
                    )
                }
            }

            for await metadata in group {
                guard let metadata,
                      let index = conversations.firstIndex(where: {
                          $0.id == metadata.conversationID
                      })
                else {
                    continue
                }
                conversations[index].createdAt = metadata.createdAt
                conversations[index].latestActivity = max(
                    conversations[index].latestActivity,
                    metadata.latestActivity
                )
            }
        }
    }
}
