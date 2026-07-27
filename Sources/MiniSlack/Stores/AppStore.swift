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

enum ConversationManagementError: LocalizedError, Equatable {
    case invalidChannelName
    case invalidChannelDetails
    case invalidGroupSize
    case invalidReplacementGroupSize
    case invalidGroupMembers
    case channelNotFound
    case permissionDenied(String)
    case reconnectRequired(String)
    case unsupported(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidChannelName:
            "Channel names must be 1–80 characters using lowercase letters, numbers, hyphens, or underscores."
        case .invalidChannelDetails:
            "Channel topics and descriptions must be 250 characters or fewer."
        case .invalidGroupSize:
            "Choose between 2 and 8 people."
        case .invalidReplacementGroupSize:
            "Keep between 1 and 8 other people in the conversation."
        case .invalidGroupMembers:
            "One or more selected people are no longer available."
        case .channelNotFound:
            "That channel is no longer available."
        case let .permissionDenied(action):
            "Slack doesn’t allow your account to \(action) here."
        case let .reconnectRequired(action):
            "Reconnect Slack so Mini Slack can request permission to \(action)."
        case let .unsupported(action):
            "Slack’s public API doesn’t support \(action) for this conversation."
        case let .unavailable(message):
            message
        }
    }
}

enum WorkspaceConnectionError: LocalizedError, Equatable {
    case unavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Slack is not configured for this build."
        case .timedOut:
            "Slack took too long to load this workspace. Try again."
        }
    }
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
        case activity
        case savedMessages
        case conversation(String)
    }

    enum QuickSwitcherEntry: Identifiable {
        case user(WorkspaceUser)
        case conversation(Conversation)

        var id: String {
            switch self {
            case let .user(user):
                "user-\(user.id)"
            case let .conversation(conversation):
                "conversation-\(conversation.id)"
            }
        }

        var user: WorkspaceUser? {
            if case let .user(user) = self {
                return user
            }
            return nil
        }

        var conversation: Conversation? {
            if case let .conversation(conversation) = self {
                return conversation
            }
            return nil
        }

        var sortTitle: String {
            switch self {
            case let .user(user):
                user.displayName
            case let .conversation(conversation):
                conversation.title
            }
        }
    }

    enum QuickSwitcherItem: Hashable, Identifiable {
        case unreads
        case activity
        case saved
        case user(String)
        case channel(String)

        var id: String {
            switch self {
            case .unreads:
                "destination-unreads"
            case .activity:
                "destination-activity"
            case .saved:
                "destination-saved"
            case let .user(id):
                "user-\(id)"
            case let .channel(id):
                "channel-\(id)"
            }
        }
    }

    struct WorkspaceSession: Equatable, Sendable {
        let generation: UInt64
        let teamID: String
    }

    enum WorkspaceSessionError: LocalizedError, Equatable {
        case changed

        var errorDescription: String? {
            "The active Slack workspace changed. Try again."
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
    private(set) var publicChannels: [SlackPublicChannel] = []
    private(set) var historyStates: [String: ConversationHistoryState] = [:]
    var threadStates: [ThreadIdentifier: ThreadState] = [:]
    var scheduledMessagesState = ScheduledMessagesState()
    var attachmentDraftsByConversationID: [String: ComposerAttachmentDraftState] = [:]
    var activityIndex: ActivityIndex
    var activityLastViewedAt = Date.distantPast
    var savedMessages: [SavedMessage] = []
    var savedMessageStore: SavedMessageStore?
    var savedMessageRevision = 0
    var workspaceAccounts: [SlackWorkspaceAccountSummary] = []
    private var slackOAuth: SlackOAuthService?
    let credentialStore: (any SlackCredentialStoring)?
    let slackAPI: SlackAPIClient?
    var credentials: SlackCredentials?
    var messageUsers: [WorkspaceUser]
    private var usersByID: [String: WorkspaceUser]
    var workspaceSearchIndex: WorkspaceSearchIndex
    var workspaceSearchFocus: WorkspaceSearchFocus?
    var historyCache: MessageHistoryCache?
    private var loadedHistoryPageCounts: [String: Int] = [:]
    private var historyBackfillTask: Task<Void, Never>?
    private var availabilityRefreshTask: Task<Void, Never>?
    private var workspaceSearchBackfillTask: Task<Void, Never>?
    var incrementalSyncTask: Task<Void, Never>?
    var socketModeTask: Task<Void, Never>?
    var socketModeState: SlackSocketModeState = .notConfigured
    var incrementalSyncCatchups: [String: IncrementalSyncCatchupState] = [:]
    var readCursorsByConversationID: [String: MessageHistoryReadCursor]
    var unreadBaselinedConversationIDs: Set<String>
    var lastPolledAtByConversationID: [String: Date] = [:]
    var outgoingMessageOutbox: OutgoingMessageOutbox?
    var outgoingMessageReplayTask: Task<Void, Never>?
    var messageMutationQueue: MessageMutationQueue?
    var messageMutationReplayTask: Task<Void, Never>?
    var messageMutationsByTarget: [MessageMutationTarget: MessageMutation] = [:]
    private var workspaceOperationTasks: [UUID: Task<Void, Never>] = [:]
    private var credentialRefreshTask: Task<SlackCredentials, Error>?
    private var credentialRefreshSession: WorkspaceSession?
    private var credentialRefreshID: UUID?
    private var activeSlackCallbackURL: URL?
    private var isSlackWebAuthenticationActive = false
    private(set) var workspaceSessionGeneration: UInt64 = 0
    private let slackOAuthWebAuthenticator: any SlackOAuthWebAuthenticating
    var mutedConversationIDs: Set<String> = []
    let notificationService: any MessageNotificationDelivering
    let dockBadgeService: any DockBadgeUpdating
    private var canRefreshDoNotDisturb = true
    private var backfillConversationIndex = 0
    private let workspaceLoadTimeout: Duration
    private let snapshotStoreRootURL: URL?
    private var workspaceSnapshotStore: WorkspaceSnapshotStore?
    private var workspacePersistTask: Task<Void, Never>?
    /// Minimum delay between workspace snapshot persists triggered by activity
    /// updates. Internal so tests can shorten it.
    var workspaceSnapshotPersistInterval: Duration = .seconds(30)
    static let presenceFreshnessThreshold: TimeInterval = 300
    let appTokenStore: (any SlackAppTokenStoring)?
    let clientIDStore: (any SlackClientIDStoring)?
    let socketModeClient: (any SlackSocketModeEventStreaming)?

    init(
        conversations: [Conversation] = SampleData.conversations(),
        users: [WorkspaceUser] = SampleData.users,
        customEmojiURLs: [String: URL] = [:],
        connectionState: ConnectionState = .preview,
        slackOAuth: SlackOAuthService? = nil,
        credentialStore: (any SlackCredentialStoring)? = nil,
        slackAPI: SlackAPIClient? = nil,
        credentials: SlackCredentials? = nil,
        outgoingMessageOutbox: OutgoingMessageOutbox? = nil,
        messageMutationQueue: MessageMutationQueue? = nil,
        appTokenStore: (any SlackAppTokenStoring)? = nil,
        clientIDStore: (any SlackClientIDStoring)? = nil,
        socketModeClient: (any SlackSocketModeEventStreaming)? = nil,
        slackOAuthWebAuthenticator: (any SlackOAuthWebAuthenticating)? = nil,
        notificationService: (any MessageNotificationDelivering)? = nil,
        dockBadgeService: (any DockBadgeUpdating)? = nil,
        workspaceLoadTimeout: Duration = .seconds(30),
        snapshotStoreRootURL: URL? = nil
    ) {
        self.conversations = conversations
        self.users = users
        self.customEmojiURLs = customEmojiURLs
        self.connectionState = connectionState
        self.slackOAuth = slackOAuth
        self.credentialStore = credentialStore
        self.slackAPI = slackAPI
        self.credentials = credentials
        self.outgoingMessageOutbox = outgoingMessageOutbox
        self.messageMutationQueue = messageMutationQueue
        self.appTokenStore = appTokenStore
        self.clientIDStore = clientIDStore
        self.socketModeClient = socketModeClient
        self.slackOAuthWebAuthenticator =
            slackOAuthWebAuthenticator ?? SlackOAuthWebAuthenticator()
        self.notificationService = notificationService ?? MacNotificationService.shared
        self.dockBadgeService = dockBadgeService ?? MacDockBadgeService.shared
        self.workspaceLoadTimeout = workspaceLoadTimeout
        self.snapshotStoreRootURL = snapshotStoreRootURL
        readCursorsByConversationID = [:]
        unreadBaselinedConversationIDs = Set(conversations.map(\.id))
        messageUsers = users
        usersByID = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
        activityIndex = ActivityIndex(
            conversations: conversations,
            currentUserID: credentials?.userID
        )
        composerSuggestionIndex = ComposerSuggestionIndex(
            users: users,
            conversations: conversations
        )
        workspaceSearchIndex = WorkspaceSearchIndex(conversations: conversations)
        keyboardConversationID = unreadConversations.first?.id
    }

    static func live() -> AppStore {
        let clientIDStore = SlackClientIDStore()
        let storedClientID = try? clientIDStore.load()
        let clientID = storedClientID
        return AppStore(
            conversations: [],
            users: [],
            connectionState: clientID == nil ? .needsConfiguration : .disconnected,
            slackOAuth: clientID.map {
                SlackOAuthService(configuration: SlackConfiguration(clientID: $0))
            },
            credentialStore: SlackCredentialStore(),
            slackAPI: SlackAPIClient(),
            appTokenStore: SlackAppTokenStore(),
            clientIDStore: clientIDStore,
            socketModeClient: SlackSocketModeClient()
        )
    }

    func configureSlackApp(clientID: String, appToken: String) throws {
        let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppToken = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedClientID.contains(".") else {
            throw SlackAppSetupError.invalidClientID
        }
        guard normalizedAppToken.hasPrefix("xapp-") else {
            throw SlackAppSetupError.invalidAppToken
        }
        guard let clientIDStore, let appTokenStore else {
            throw WorkspaceConnectionError.unavailable
        }
        try clientIDStore.save(normalizedClientID)
        try appTokenStore.save(normalizedAppToken)
        slackOAuth = SlackOAuthService(
            configuration: SlackConfiguration(clientID: normalizedClientID)
        )
        socketModeState = .notConfigured
        if credentials == nil {
            connectionState = .disconnected
        } else {
            restartSocketMode()
        }
    }

    func savedSlackAppConfiguration() -> (clientID: String, appToken: String) {
        (
            clientID: clientIDStore.flatMap { try? $0.load() } ?? "",
            appToken: appTokenStore.flatMap { try? $0.load() } ?? ""
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

    var groupDirectMessageCandidates: [WorkspaceUser] {
        users.filter { $0.id != credentials?.userID }
    }

    var canLeaveSelectedChannel: Bool {
        selectedConversation?.kind == .channel
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

    func clearComposerDraft(
        _ expectedDraft: ComposerDraft,
        for conversationID: String
    ) {
        guard draftsByConversationID[conversationID] == expectedDraft else {
            return
        }
        draftsByConversationID[conversationID] = nil
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

    var quickSwitcherShowsActivity: Bool {
        normalizedQuickSwitcherQuery.isEmpty
            || "activity mentions reactions threads notifications"
                .localizedCaseInsensitiveContains(normalizedQuickSwitcherQuery)
    }

    var quickSwitcherShowsSaved: Bool {
        normalizedQuickSwitcherQuery.isEmpty
            || "saved messages bookmarks later"
                .localizedCaseInsensitiveContains(normalizedQuickSwitcherQuery)
    }

    var quickSwitcherEntries: [QuickSwitcherEntry] {
        let query = normalizedQuickSwitcherQuery
        let activityByUserID = directMessageActivityByUserID

        func activity(of entry: QuickSwitcherEntry) -> Date {
            switch entry {
            case let .user(user):
                activityByUserID[user.id] ?? .distantPast
            case let .conversation(conversation):
                conversation.latestActivity
            }
        }

        let matchingUsers = users.filter { user in
            query.isEmpty
                || user.displayName.localizedCaseInsensitiveContains(query)
                || user.status.localizedCaseInsensitiveContains(query)
        }
        let matchingConversations = conversations.filter { conversation in
            guard conversation.kind != .directMessage else {
                return false
            }
            return query.isEmpty
                || conversation.title.localizedCaseInsensitiveContains(query)
                || (conversation.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
        }

        let entries = matchingUsers.map(QuickSwitcherEntry.user)
            + matchingConversations.map(QuickSwitcherEntry.conversation)
        return entries.sorted { lhs, rhs in
            let lhsActivity = activity(of: lhs)
            let rhsActivity = activity(of: rhs)
            if lhsActivity != rhsActivity {
                return lhsActivity > rhsActivity
            }
            let titleOrder = lhs.sortTitle.localizedCaseInsensitiveCompare(rhs.sortTitle)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    var hasQuickSwitcherResults: Bool {
        quickSwitcherShowsUnreads
            || quickSwitcherShowsActivity
            || quickSwitcherShowsSaved
            || !quickSwitcherEntries.isEmpty
    }

    var quickSwitcherItems: [QuickSwitcherItem] {
        var items: [QuickSwitcherItem] = []
        if quickSwitcherShowsUnreads {
            items.append(.unreads)
        }
        if quickSwitcherShowsActivity {
            items.append(.activity)
        }
        if quickSwitcherShowsSaved {
            items.append(.saved)
        }
        items.append(
            contentsOf: quickSwitcherEntries.map { entry in
                switch entry {
                case let .user(user):
                    .user(user.id)
                case let .conversation(conversation):
                    .channel(conversation.id)
                }
            }
        )
        return items
    }

    func select(_ conversationID: String) {
        workspaceSearchFocus = nil
        keyboardConversationID = conversationID
        destination = .conversation(conversationID)
    }

    func loadInitialHistory(for conversationID: String) async {
        guard let session = try? captureWorkspaceSession() else {
            return
        }
        await loadMessages(for: conversationID, session: session)
    }

    func historyState(for conversationID: String) -> ConversationHistoryState {
        historyStates[conversationID] ?? ConversationHistoryState()
    }

    func loadOlderMessages(for conversationID: String) {
        startWorkspaceOperation { [weak self] session in
            await self?.loadOlderHistory(
                for: conversationID,
                session: session
            )
        }
    }

    func retryHistory(for conversationID: String) {
        startWorkspaceOperation { [weak self] session in
            await self?.loadMessages(
                for: conversationID,
                session: session
            )
        }
    }

    func showUnreadInbox() {
        workspaceSearchFocus = nil
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
            startWorkspaceOperation { [weak self] session in
                await self?.openLiveDirectMessage(
                    with: user,
                    session: session
                )
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

    static func normalizedChannelName(_ input: String) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")
    }

    static func isValidChannelName(_ input: String) -> Bool {
        let name = normalizedChannelName(input)
        guard !name.isEmpty, name.count <= 80 else {
            return false
        }
        return name.unicodeScalars.allSatisfy { scalar in
            (97 ... 122).contains(scalar.value)
                || (48 ... 57).contains(scalar.value)
                || scalar == "-"
                || scalar == "_"
        }
    }

    func refreshPublicChannels() async throws {
        guard let slackAPI else {
            return
        }
        let session = try captureWorkspaceSession()
        let credentials = try await activeCredentials(for: session)
        let channels = try await slackAPI.fetchPublicChannels(
            accessToken: credentials.accessToken
        )
        try requireCurrentWorkspaceSession(session)
        publicChannels = channels
    }

    func joinPublicChannel(_ channel: SlackPublicChannel) async throws {
        if channel.isMember,
           let existing = conversations.first(where: { $0.id == channel.id })
        {
            select(existing.id)
            return
        }

        let conversation: Conversation
        if let slackAPI {
            let session = try captureWorkspaceSession()
            let credentials = try await activeCredentials(for: session)
            let dto = try await slackAPI.joinConversation(
                channelID: channel.id,
                accessToken: credentials.accessToken
            )
            try requireCurrentWorkspaceSession(session)
            conversation = channelConversation(
                from: dto,
                fallbackName: channel.name,
                isPrivate: false
            )
        } else {
            conversation = Conversation(
                id: channel.id,
                title: channel.name,
                kind: .channel,
                subtitle: channel.purpose,
                isFavorite: false,
                createdAt: .now,
                unreadCount: 0,
                mentionCount: 0,
                latestActivity: .now,
                messages: []
            )
        }
        upsertConversation(conversation)
        updatePublicChannel(channel, isMember: true)
        select(conversation.id)
    }

    func createChannel(name input: String, isPrivate: Bool) async throws {
        guard Self.isValidChannelName(input) else {
            throw ConversationManagementError.invalidChannelName
        }
        let name = Self.normalizedChannelName(input)
        let conversation: Conversation
        if let slackAPI {
            let session = try captureWorkspaceSession()
            let credentials = try await activeCredentials(for: session)
            let dto = try await slackAPI.createConversation(
                name: name,
                isPrivate: isPrivate,
                accessToken: credentials.accessToken
            )
            try requireCurrentWorkspaceSession(session)
            conversation = channelConversation(
                from: dto,
                fallbackName: name,
                isPrivate: isPrivate
            )
        } else {
            conversation = Conversation(
                id: "preview-channel-\(UUID().uuidString)",
                title: name,
                kind: .channel,
                isPrivate: isPrivate,
                subtitle: nil,
                isFavorite: false,
                createdAt: .now,
                unreadCount: 0,
                mentionCount: 0,
                latestActivity: .now,
                messages: []
            )
        }
        upsertConversation(conversation)
        if !isPrivate {
            updatePublicChannel(
                SlackPublicChannel(
                    id: conversation.id,
                    name: conversation.title,
                    purpose: conversation.subtitle,
                    memberCount: 1,
                    isMember: true
                ),
                isMember: true
            )
        }
        select(conversation.id)
    }

    func leaveChannel(_ conversationID: String) async throws {
        guard let conversation = conversations.first(where: {
            $0.id == conversationID && $0.kind == .channel
        }) else {
            throw ConversationManagementError.channelNotFound
        }
        if let slackAPI {
            let session = try captureWorkspaceSession()
            let credentials = try await activeCredentials(for: session)
            try await slackAPI.leaveConversation(
                channelID: conversation.id,
                accessToken: credentials.accessToken
            )
            try requireCurrentWorkspaceSession(session)
        }

        conversations.removeAll { $0.id == conversation.id }
        draftsByConversationID[conversation.id] = nil
        historyStates[conversation.id] = nil
        loadedHistoryPageCounts[conversation.id] = nil
        if !conversation.isPrivate {
            updatePublicChannel(
                SlackPublicChannel(
                    id: conversation.id,
                    name: conversation.title,
                    purpose: conversation.subtitle,
                    memberCount: nil,
                    isMember: false
                ),
                isMember: false
            )
        }
        rebuildComposerSuggestionIndex()
        showUnreadInbox()
    }

    func startGroupDirectMessage(with userIDs: [String]) async throws {
        var seen = Set<String>()
        let uniqueIDs = userIDs.filter { seen.insert($0).inserted }
        guard (2 ... 8).contains(uniqueIDs.count) else {
            throw ConversationManagementError.invalidGroupSize
        }
        guard !uniqueIDs.contains(credentials?.userID ?? ""),
              uniqueIDs.allSatisfy({ usersByID[$0] != nil })
        else {
            throw ConversationManagementError.invalidGroupMembers
        }
        let selectedUsers = uniqueIDs.compactMap { usersByID[$0] }
        let participantIDs = Set(uniqueIDs)
        if let existing = conversations.first(where: {
            $0.kind == .groupDirectMessage
                && Set($0.participants.map(\.id)) == participantIDs
        }) {
            select(existing.id)
            return
        }

        let conversationID: String
        if let slackAPI {
            let session = try captureWorkspaceSession()
            let credentials = try await activeCredentials(for: session)
            conversationID = try await slackAPI.openGroupDirectMessage(
                userIDs: uniqueIDs,
                accessToken: credentials.accessToken
            )
            try requireCurrentWorkspaceSession(session)
        } else {
            conversationID = "preview-group-\(UUID().uuidString)"
        }

        if conversations.contains(where: { $0.id == conversationID }) {
            select(conversationID)
            return
        }
        let conversation = Conversation(
            id: conversationID,
            title: selectedUsers.map(\.displayName).joined(separator: ", "),
            kind: .groupDirectMessage,
            subtitle: "Group DM · \(selectedUsers.count) people",
            isFavorite: false,
            createdAt: .now,
            participants: selectedUsers,
            unreadCount: 0,
            mentionCount: 0,
            latestActivity: .now,
            messages: []
        )
        upsertConversation(conversation)
        select(conversation.id)
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
        case .activity:
            showActivityInbox()
            dismissQuickSwitcher()
        case .saved:
            showSavedMessages()
            dismissQuickSwitcher()
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
        case .activity, .savedMessages:
            nil
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
        refreshDockBadge()
        if let timestamp, slackAPI != nil {
            startWorkspaceOperation { [weak self] session in
                await self?.markLiveConversationRead(
                    channelID: id,
                    timestamp: timestamp,
                    session: session
                )
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
            displayBody: SlackEmoji.replacingUnicodeShortcodes(in: displayText),
            deliveryState: slackAPI == nil ? .sent : .sending
        )
        conversations[index].messages.append(optimisticMessage)
        workspaceSearchIndex.merge(
            messages: [optimisticMessage],
            conversation: conversations[index]
        )
        conversations[index].latestActivity = .now
        composerDraft = ComposerDraft()
        scheduleWorkspaceStatePersist()
        if slackAPI != nil {
            startWorkspaceOperation { [weak self] session in
                await self?.sendLiveMessage(
                    channelID: id,
                    text: outgoingText,
                    localMessageID: optimisticMessage.id,
                    session: session
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
        refreshWorkspaceAccounts()
        do {
            guard let storedCredentials = try credentialStore.load() else {
                return
            }
            try await connect(with: storedCredentials)
        } catch is WorkspaceSessionError {
            return
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    func signInWithSlack() async {
        guard let slackOAuth else {
            connectionState = .needsConfiguration
            return
        }
        guard !isSlackWebAuthenticationActive else {
            return
        }
        isSlackWebAuthenticationActive = true
        defer {
            isSlackWebAuthenticationActive = false
        }
        let hasActiveWorkspace = credentials != nil
        do {
            let url = try await slackOAuth.beginAuthorization()
            if !hasActiveWorkspace {
                connectionState = .authorizing
            }
            let callbackURL = try await slackOAuthWebAuthenticator.authenticate(at: url)
            await handleSlackCallback(callbackURL)
        } catch {
            if error as? SlackOAuthWebAuthenticationError == .cancelled {
                await slackOAuth.cancelAuthorization()
                if !hasActiveWorkspace {
                    connectionState = .disconnected
                }
                return
            }
            if hasActiveWorkspace {
                transientError = error.localizedDescription
            } else {
                connectionState = .failed(error.localizedDescription)
            }
        }
    }

    func handleSlackCallback(_ url: URL) async {
        guard url.scheme == "minislack", let slackOAuth else {
            return
        }
        guard activeSlackCallbackURL == nil else {
            return
        }
        activeSlackCallbackURL = url
        defer {
            activeSlackCallbackURL = nil
        }
        let existingCredentials = credentials
        var clearedExistingSession = false
        var replacementGeneration: UInt64?
        connectionState = .loading
        do {
            let newCredentials = try await slackOAuth.handleCallback(url)
            clearWorkspaceSession()
            clearedExistingSession = true
            replacementGeneration = workspaceSessionGeneration
            connectionState = .loading
            try await connect(with: newCredentials)
        } catch {
            let connectionError = error
            if connectionError is WorkspaceSessionError {
                return
            }
            if clearedExistingSession,
               replacementGeneration != workspaceSessionGeneration
            {
                return
            }
            if let existingCredentials, clearedExistingSession {
                do {
                    try await connect(with: existingCredentials)
                    transientError = connectionError.localizedDescription
                } catch {
                    connectionState = .failed(
                        "Could not connect the new workspace, and \(existingCredentials.teamName) "
                            + "could not be restored: \(error.localizedDescription)"
                    )
                }
            } else if let existingCredentials, credentials != nil {
                connectionState = .connected(existingCredentials.teamName)
                transientError = connectionError.localizedDescription
            } else {
                connectionState = .failed(connectionError.localizedDescription)
            }
        }
    }

    func cancelSlackSignIn() async {
        slackOAuthWebAuthenticator.cancel()
        await slackOAuth?.cancelAuthorization()
        if let credentials {
            connectionState = .connected(credentials.teamName)
        } else {
            connectionState = .disconnected
        }
    }

    func retrySlackConnection() async {
        do {
            let retryCredentials: SlackCredentials?
            if let credentials {
                retryCredentials = credentials
            } else {
                retryCredentials = try credentialStore?.load()
            }
            guard let retryCredentials else {
                connectionState = .disconnected
                return
            }
            try await connect(with: retryCredentials)
        } catch is WorkspaceSessionError {
            return
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    func signOut() {
        let workspaceID = credentials?.teamID
        if let workspaceID {
            do {
                try credentialStore?.delete(teamID: workspaceID)
            } catch {
                transientError = error.localizedDescription
            }
        }
        clearWorkspaceSession()
        refreshWorkspaceAccounts()
    }

    func clearWorkspaceSession() {
        workspaceSessionGeneration &+= 1
        credentialRefreshTask?.cancel()
        credentialRefreshTask = nil
        credentialRefreshSession = nil
        credentialRefreshID = nil
        let operationTasks = workspaceOperationTasks.values
        workspaceOperationTasks.removeAll()
        operationTasks.forEach { $0.cancel() }
        stopIncrementalSync()
        stopSocketMode()
        incrementalSyncCatchups = [:]
        readCursorsByConversationID = [:]
        unreadBaselinedConversationIDs = []
        lastPolledAtByConversationID = [:]
        workspaceSnapshotStore = nil
        cancelOutgoingMessageReplay()
        cancelMessageMutationReplay()
        notificationService.onOpenConversation = nil
        mutedConversationIDs = []
        dockBadgeService.update(unreadCount: 0)
        historyBackfillTask?.cancel()
        historyBackfillTask = nil
        availabilityRefreshTask?.cancel()
        availabilityRefreshTask = nil
        workspaceSearchBackfillTask?.cancel()
        workspaceSearchBackfillTask = nil
        credentials = nil
        outgoingMessageOutbox = nil
        messageMutationQueue = nil
        messageMutationsByTarget = [:]
        users = []
        messageUsers = []
        usersByID = [:]
        customEmojiURLs = [:]
        conversations = []
        workspaceSearchIndex.reset(conversations: [])
        workspaceSearchFocus = nil
        publicChannels = []
        draftsByConversationID = [:]
        composerSuggestionIndex = ComposerSuggestionIndex(users: [], conversations: [])
        historyStates = [:]
        threadStates = [:]
        activityIndex.reset(conversations: [], currentUserID: nil)
        activityLastViewedAt = .distantPast
        scheduledMessagesState = ScheduledMessagesState()
        attachmentDraftsByConversationID = [:]
        Task {
            await ComposerAttachmentFileService.shared.clearTemporaryFiles()
        }
        savedMessages = []
        savedMessageStore = nil
        savedMessageRevision = 0
        loadedHistoryPageCounts = [:]
        historyCache = nil
        keyboardConversationID = nil
        quickSwitcherQuery = ""
        quickSwitcherSelection = nil
        destination = .unreadInbox
        connectionState = .disconnected
    }

    func connect(with proposedCredentials: SlackCredentials) async throws {
        guard let slackOAuth, let credentialStore, let slackAPI else {
            throw WorkspaceConnectionError.unavailable
        }
        let connectionGeneration = workspaceSessionGeneration
        connectionState = .loading
        let activeCredentials: SlackCredentials
        do {
            if proposedCredentials.needsRefresh() {
                activeCredentials = try await slackOAuth.refresh(proposedCredentials)
            } else {
                activeCredentials = proposedCredentials
            }
        } catch {
            guard connectionGeneration == workspaceSessionGeneration else {
                throw WorkspaceSessionError.changed
            }
            throw error
        }
        guard connectionGeneration == workspaceSessionGeneration else {
            throw WorkspaceSessionError.changed
        }
        try credentialStore.save(activeCredentials)
        refreshWorkspaceAccounts()
        let snapshotStore = WorkspaceSnapshotStore(
            workspaceID: activeCredentials.teamID,
            rootURL: snapshotStoreRootURL
        )
        let cachedState = await snapshotStore.load()
        guard connectionGeneration == workspaceSessionGeneration else {
            throw WorkspaceSessionError.changed
        }
        let snapshot: SlackWorkspaceSnapshot
        if let cachedState {
            snapshot = cachedState.snapshot
        } else {
            do {
                snapshot = try await fetchWorkspaceSnapshot(
                    slackAPI: slackAPI,
                    credentials: activeCredentials
                )
            } catch {
                guard connectionGeneration == workspaceSessionGeneration else {
                    throw WorkspaceSessionError.changed
                }
                throw error
            }
            guard connectionGeneration == workspaceSessionGeneration else {
                throw WorkspaceSessionError.changed
            }
        }
        workspaceSnapshotStore = snapshotStore
        lastPolledAtByConversationID = cachedState?.lastPolledAtByConversationID ?? [:]
        credentials = activeCredentials
        workspaceSearchBackfillTask?.cancel()
        historyCache = MessageHistoryCache(workspaceID: activeCredentials.teamID)
        applyWorkspaceSnapshot(snapshot, credentials: activeCredentials, phase: .initial)
        connectionState = .connected(activeCredentials.teamName)
        canRefreshDoNotDisturb = true
        let session = WorkspaceSession(
            generation: connectionGeneration,
            teamID: activeCredentials.teamID
        )
        await startBackgroundWorkspaceServices(
            session: session,
            credentials: activeCredentials
        )
        if cachedState == nil {
            persistWorkspaceState()
        } else {
            startWorkspaceOperation { [weak self] session in
                await self?.refreshWorkspaceSnapshot(session: session)
            }
        }
    }

    private enum WorkspaceSnapshotPhase {
        case initial
        case refresh
    }

    private func applyWorkspaceSnapshot(
        _ snapshot: SlackWorkspaceSnapshot,
        credentials: SlackCredentials,
        phase: WorkspaceSnapshotPhase
    ) {
        users = snapshot.users
        messageUsers = snapshot.messageUsers
        usersByID = Dictionary(
            uniqueKeysWithValues: snapshot.messageUsers.map { ($0.id, $0) }
        )
        customEmojiURLs = snapshot.customEmojiURLs
        switch phase {
        case .initial:
            conversations = snapshot.conversations
            readCursorsByConversationID = snapshot.readCursorsByConversationID
            unreadBaselinedConversationIDs =
                snapshot.conversationsWithAuthoritativeUnreadCounts
            resetActivity(
                conversations: snapshot.conversations,
                currentUserID: credentials.userID,
                teamID: credentials.teamID
            )
            workspaceSearchIndex.reset(conversations: snapshot.conversations)
            composerSuggestionIndex = ComposerSuggestionIndex(
                users: snapshot.users,
                conversations: snapshot.conversations
            )
            destination = .unreadInbox
            keyboardConversationID = unreadConversations.first?.id
        case .refresh:
            conversations = Self.mergedConversations(
                local: conversations,
                fresh: snapshot.conversations,
                localCursors: readCursorsByConversationID,
                freshCursors: snapshot.readCursorsByConversationID
            )
            let mergedIDs = Set(conversations.map(\.id))
            var mergedCursors = snapshot.readCursorsByConversationID
            for (conversationID, localCursor) in readCursorsByConversationID
                where mergedIDs.contains(conversationID)
            {
                if Self.localReadStateIsNewer(
                    localCursor: localCursor,
                    freshCursor: mergedCursors[conversationID]
                ) {
                    mergedCursors[conversationID] = localCursor
                }
            }
            readCursorsByConversationID = mergedCursors
            unreadBaselinedConversationIDs.formUnion(
                snapshot.conversationsWithAuthoritativeUnreadCounts
            )
        }
    }

    nonisolated static func mergedConversations(
        local: [Conversation],
        fresh: [Conversation],
        localCursors: [String: MessageHistoryReadCursor],
        freshCursors: [String: MessageHistoryReadCursor]
    ) -> [Conversation] {
        let localByID = Dictionary(local.map { ($0.id, $0) }) { first, _ in first }
        return fresh.map { freshConversation in
            guard let localConversation = localByID[freshConversation.id] else {
                return freshConversation
            }
            var merged = freshConversation
            merged.messages = localConversation.messages
            merged.latestActivity = max(
                localConversation.latestActivity,
                freshConversation.latestActivity
            )
            if localReadStateIsNewer(
                localCursor: localCursors[freshConversation.id],
                freshCursor: freshCursors[freshConversation.id]
            ) {
                merged.unreadCount = localConversation.unreadCount
                merged.mentionCount = localConversation.mentionCount
            }
            return merged
        }
    }

    private nonisolated static func localReadStateIsNewer(
        localCursor: MessageHistoryReadCursor?,
        freshCursor: MessageHistoryReadCursor?
    ) -> Bool {
        switch (localCursor?.timestamp, freshCursor?.timestamp) {
        case let (localTimestamp?, freshTimestamp?):
            localTimestamp >= freshTimestamp
        case (_?, nil):
            true
        default:
            false
        }
    }

    private func startBackgroundWorkspaceServices(
        session: WorkspaceSession,
        credentials: SlackCredentials
    ) async {
        startWorkspaceOperation { [weak self] session in
            await self?.refreshCustomEmoji(session: session)
        }
        startWorkspaceOperation { [weak self] session in
            await self?.hydratePriorityGroupDirectMessages(session: session)
        }
        await loadSavedMessages(for: credentials.teamID, session: session)
        guard isCurrentWorkspaceSession(session) else {
            return
        }
        await restoreOutgoingMessages(for: credentials.teamID)
        guard isCurrentWorkspaceSession(session) else {
            return
        }
        await restoreMessageMutations(for: credentials.teamID)
        guard isCurrentWorkspaceSession(session) else {
            return
        }
        startHistoryBackfill()
        startWorkspaceSearchBackfill()
        startAvailabilityRefresh()
        loadConversationMutes(workspaceID: credentials.teamID)
        refreshDockBadge()
        startIncrementalSync()
        startSocketMode()
        scheduleOutgoingMessageReplay()
        scheduleMessageMutationReplay()
    }

    private func refreshWorkspaceSnapshot(session: WorkspaceSession) async {
        guard let slackAPI,
              let credentials = try? await activeCredentials(for: session),
              let snapshot = try? await slackAPI.fetchWorkspace(
                  accessToken: credentials.accessToken,
                  currentUserID: credentials.userID
              ),
              isCurrentWorkspaceSession(session)
        else {
            return
        }
        applyWorkspaceSnapshot(snapshot, credentials: credentials, phase: .refresh)
        persistWorkspaceState()
    }

    /// Coalesces activity-driven persists so incremental sync and history
    /// loads don't write the snapshot on every update. At most one persist
    /// is scheduled per `workspaceSnapshotPersistInterval` window; updates
    /// that arrive while one is pending are captured by that persist.
    func scheduleWorkspaceStatePersist() {
        guard workspacePersistTask == nil, credentials != nil else {
            return
        }
        workspacePersistTask = Task { [weak self] in
            guard let self else {
                return
            }
            try? await Task.sleep(for: workspaceSnapshotPersistInterval)
            workspacePersistTask = nil
            guard !Task.isCancelled else {
                return
            }
            persistWorkspaceState()
        }
    }

    private func persistWorkspaceState() {
        guard let credentials else {
            return
        }
        let store = workspaceSnapshotStore
            ?? WorkspaceSnapshotStore(
                workspaceID: credentials.teamID,
                rootURL: snapshotStoreRootURL
            )
        workspaceSnapshotStore = store
        let state = CachedWorkspaceState(
            savedAt: .now,
            snapshot: SlackWorkspaceSnapshot(
                users: users,
                messageUsers: messageUsers,
                conversations: conversations,
                customEmojiURLs: customEmojiURLs,
                readCursorsByConversationID: readCursorsByConversationID,
                conversationsWithAuthoritativeUnreadCounts:
                    unreadBaselinedConversationIDs
            ),
            lastPolledAtByConversationID: lastPolledAtByConversationID
        )
        Task {
            try? await store.save(state)
        }
    }

    private func fetchWorkspaceSnapshot(
        slackAPI: SlackAPIClient,
        credentials: SlackCredentials
    ) async throws -> SlackWorkspaceSnapshot {
        try await withThrowingTaskGroup(of: SlackWorkspaceSnapshot.self) { group in
            group.addTask {
                try await slackAPI.fetchWorkspace(
                    accessToken: credentials.accessToken,
                    currentUserID: credentials.userID
                )
            }
            group.addTask { [workspaceLoadTimeout] in
                try await Task.sleep(for: workspaceLoadTimeout)
                throw WorkspaceConnectionError.timedOut
            }
            defer {
                group.cancelAll()
            }
            guard let snapshot = try await group.next() else {
                throw WorkspaceConnectionError.unavailable
            }
            return snapshot
        }
    }

    private func refreshCustomEmoji(session: WorkspaceSession) async {
        guard let slackAPI,
              let credentials = try? await activeCredentials(for: session),
              let emoji = try? await slackAPI.fetchCustomEmojiURLs(
                  accessToken: credentials.accessToken
              ),
              isCurrentWorkspaceSession(session)
        else {
            return
        }
        customEmojiURLs = emoji
    }

    func activeCredentials() async throws -> SlackCredentials {
        try await activeCredentials(for: captureWorkspaceSession())
    }

    func captureWorkspaceSession() throws -> WorkspaceSession {
        guard let teamID = credentials?.teamID else {
            throw SlackOAuthService.OAuthError.invalidTokenResponse
        }
        return WorkspaceSession(
            generation: workspaceSessionGeneration,
            teamID: teamID
        )
    }

    func isCurrentWorkspaceSession(_ session: WorkspaceSession) -> Bool {
        session.generation == workspaceSessionGeneration
            && session.teamID == credentials?.teamID
    }

    func requireCurrentWorkspaceSession(
        _ session: WorkspaceSession
    ) throws {
        guard isCurrentWorkspaceSession(session) else {
            throw WorkspaceSessionError.changed
        }
    }

    func activeCredentials(
        for session: WorkspaceSession
    ) async throws -> SlackCredentials {
        try requireCurrentWorkspaceSession(session)
        guard let credentials, credentials.teamID == session.teamID else {
            throw WorkspaceSessionError.changed
        }
        guard credentials.needsRefresh() else {
            return credentials
        }
        guard let slackOAuth, let credentialStore else {
            throw SlackOAuthService.OAuthError.invalidTokenResponse
        }

        let refreshID: UUID
        let refreshTask: Task<SlackCredentials, Error>
        if let credentialRefreshTask,
           credentialRefreshSession == session,
           let credentialRefreshID
        {
            refreshID = credentialRefreshID
            refreshTask = credentialRefreshTask
        } else {
            credentialRefreshTask?.cancel()
            refreshID = UUID()
            refreshTask = Task {
                try await slackOAuth.refresh(credentials)
            }
            credentialRefreshTask = refreshTask
            credentialRefreshSession = session
            credentialRefreshID = refreshID
        }

        do {
            let refreshed = try await refreshTask.value
            if credentialRefreshID == refreshID {
                credentialRefreshTask = nil
                credentialRefreshSession = nil
                credentialRefreshID = nil
            }
            try requireCurrentWorkspaceSession(session)
            guard refreshed.teamID == session.teamID else {
                throw WorkspaceSessionError.changed
            }
            try credentialStore.save(refreshed)
            refreshWorkspaceAccounts()
            self.credentials = refreshed
            return refreshed
        } catch {
            if credentialRefreshID == refreshID {
                credentialRefreshTask = nil
                credentialRefreshSession = nil
                credentialRefreshID = nil
            }
            throw error
        }
    }

    func startWorkspaceOperation(
        _ operation: @escaping @MainActor (WorkspaceSession) async -> Void
    ) {
        guard let session = try? captureWorkspaceSession() else {
            return
        }
        let operationID = UUID()
        let task = Task { [weak self] in
            await operation(session)
            self?.workspaceOperationTasks[operationID] = nil
        }
        workspaceOperationTasks[operationID] = task
    }

    private func loadMessages(
        for channelID: String,
        session: WorkspaceSession
    ) async {
        guard isCurrentWorkspaceSession(session),
              let slackAPI,
              historyStates[channelID]?.isLoadingInitial != true
        else {
            return
        }
        let historyCache = self.historyCache
        historyStates[channelID, default: ConversationHistoryState()].isLoadingInitial = true
        historyStates[channelID]?.errorMessage = nil

        if let historyCache,
           let cachedPage = try? await historyCache.page(channelID: channelID, index: 0)
        {
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            apply(cachedPage.messages, to: channelID)
            historyStates[channelID]?.hasLoadedInitial = true
            loadedHistoryPageCounts[channelID] = 1
            let status = try? await historyCache.status(channelID: channelID)
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            historyStates[channelID]?.canLoadOlder =
                (status?.pageCount ?? 0) > 1 || cachedPage.nextCursor != nil
        }

        do {
            let credentials = try await activeCredentials(for: session)
            let page = try await slackAPI.fetchMessagePage(
                channelID: channelID,
                accessToken: credentials.accessToken,
                users: messageUsers,
                channelNames: conversationNamesByID,
                currentUserID: credentials.userID
            )
            try requireCurrentWorkspaceSession(session)
            if let historyCache {
                try? await historyCache.mergeLatest(
                    MessageHistoryPage(messages: page.messages, nextCursor: page.nextCursor),
                    channelID: channelID
                )
                try requireCurrentWorkspaceSession(session)
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
                scheduleWorkspaceStatePersist()
                let preference = UserDefaults.standard.object(forKey: "markReadOnOpen")
                let shouldMarkRead = preference == nil
                    || UserDefaults.standard.bool(forKey: "markReadOnOpen")
                if destination == .conversation(channelID), shouldMarkRead {
                    conversations[index].unreadCount = 0
                    conversations[index].mentionCount = 0
                    refreshDockBadge()
                    if let timestamp = latest.remoteID {
                        await markLiveConversationRead(
                            channelID: channelID,
                            timestamp: timestamp,
                            session: session
                        )
                    }
                }
            }
        } catch {
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            historyStates[channelID]?.hasLoadedInitial = true
            historyStates[channelID]?.isLoadingInitial = false
            historyStates[channelID]?.errorMessage = error.localizedDescription
        }
    }

    private func loadOlderHistory(
        for channelID: String,
        session: WorkspaceSession
    ) async {
        guard isCurrentWorkspaceSession(session),
              let slackAPI,
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
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            apply(cachedPage.messages, to: channelID)
            loadedHistoryPageCounts[channelID] = pageIndex + 1
            let status = try? await historyCache.status(channelID: channelID)
            guard isCurrentWorkspaceSession(session) else {
                return
            }
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
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            historyStates[channelID]?.canLoadOlder = false
            historyStates[channelID]?.isLoadingOlder = false
            return
        }

        do {
            try requireCurrentWorkspaceSession(session)
            let credentials = try await activeCredentials(for: session)
            let page = try await slackAPI.fetchMessagePage(
                channelID: channelID,
                cursor: cursor,
                accessToken: credentials.accessToken,
                users: messageUsers,
                channelNames: conversationNamesByID,
                currentUserID: credentials.userID
            )
            try requireCurrentWorkspaceSession(session)
            let cachedPage = MessageHistoryPage(
                messages: page.messages,
                nextCursor: page.nextCursor
            )
            try await historyCache.store(cachedPage, channelID: channelID, index: pageIndex)
            try requireCurrentWorkspaceSession(session)
            apply(page.messages, to: channelID)
            loadedHistoryPageCounts[channelID] = pageIndex + 1
            historyStates[channelID]?.canLoadOlder = page.nextCursor != nil
        } catch {
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            historyStates[channelID]?.errorMessage = error.localizedDescription
        }
        historyStates[channelID]?.isLoadingOlder = false
    }

    private func openLiveDirectMessage(
        with user: WorkspaceUser,
        session: WorkspaceSession
    ) async {
        guard isCurrentWorkspaceSession(session) else {
            return
        }
        if let existing = conversations.first(where: { $0.participantUserID == user.id }) {
            select(existing.id)
            return
        }
        guard let slackAPI else {
            return
        }
        do {
            let credentials = try await activeCredentials(for: session)
            let channelID = try await slackAPI.openDirectMessage(
                userID: user.id,
                accessToken: credentials.accessToken
            )
            try requireCurrentWorkspaceSession(session)
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
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            transientError = error.localizedDescription
        }
    }

    private func channelConversation(
        from dto: SlackConversationDTO,
        fallbackName: String,
        isPrivate: Bool
    ) -> Conversation {
        let createdAt = dto.created
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? .now
        let subtitle: String? = if dto.topic?.value.isEmpty == false {
            dto.topic?.value
        } else if dto.purpose?.value.isEmpty == false {
            dto.purpose?.value
        } else {
            nil
        }
        return Conversation(
            id: dto.id,
            title: dto.name ?? fallbackName,
            kind: .channel,
            isPrivate: isPrivate,
            subtitle: subtitle,
            isFavorite: dto.isStarred,
            createdAt: createdAt,
            topic: dto.topic?.value.isEmpty == false ? dto.topic?.value : nil,
            purpose: dto.purpose?.value.isEmpty == false ? dto.purpose?.value : nil,
            isArchived: dto.isArchived,
            unreadCount: dto.unreadCountDisplay,
            mentionCount: 0,
            latestActivity: createdAt,
            messages: []
        )
    }

    func upsertConversation(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            let messages = conversations[index].messages
            conversations[index] = conversation
            conversations[index].messages = messages
        } else {
            conversations.append(conversation)
        }
        rebuildComposerSuggestionIndex()
    }

    func updatePublicChannel(
        _ channel: SlackPublicChannel,
        isMember: Bool
    ) {
        let updated = SlackPublicChannel(
            id: channel.id,
            name: channel.name,
            purpose: channel.purpose,
            memberCount: channel.memberCount,
            isMember: isMember
        )
        if let index = publicChannels.firstIndex(where: { $0.id == channel.id }) {
            publicChannels[index] = updated
        } else {
            publicChannels.append(updated)
            publicChannels.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    func removePublicChannel(_ channelID: String) {
        publicChannels.removeAll { $0.id == channelID }
    }

    private func rebuildComposerSuggestionIndex() {
        composerSuggestionIndex = ComposerSuggestionIndex(
            users: users,
            conversations: conversations
        )
    }

    private func sendLiveMessage(
        channelID: String,
        text: String,
        localMessageID: UUID,
        session: WorkspaceSession
    ) async {
        await sendOutgoingMessage(
            conversationID: channelID,
            semanticText: text,
            localMessageID: localMessageID,
            session: session
        )
    }

    func markLiveConversationRead(
        channelID: String,
        timestamp: String,
        session proposedSession: WorkspaceSession? = nil
    ) async {
        guard let slackAPI else {
            return
        }
        guard let session = proposedSession ?? (try? captureWorkspaceSession()) else {
            return
        }
        let historyCache = self.historyCache
        do {
            let credentials = try await activeCredentials(for: session)
            try await slackAPI.markRead(
                channelID: channelID,
                timestamp: timestamp,
                accessToken: credentials.accessToken
            )
            try requireCurrentWorkspaceSession(session)
            let readCursor = MessageHistoryReadCursor(
                remoteID: timestamp,
                timestamp: Double(timestamp).map {
                    Date(timeIntervalSince1970: $0)
                }
            )
            try? await historyCache?.setReadCursor(
                readCursor,
                channelID: channelID
            )
            try requireCurrentWorkspaceSession(session)
            readCursorsByConversationID[channelID] = readCursor
            unreadBaselinedConversationIDs.insert(channelID)
        } catch {
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            transientError = error.localizedDescription
        }
    }

    private var keyboardNavigationIDs: [String] {
        switch destination {
        case .unreadInbox:
            return unreadConversations.map(\.id)
        case .activity, .savedMessages:
            return []
        case .conversation:
            let unreadIDs = unreadConversations.map(\.id)
            return unreadIDs + conversations.map(\.id).filter { !unreadIDs.contains($0) }
        }
    }

    private var normalizedQuickSwitcherQuery: String {
        quickSwitcherQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var directMessageActivityByUserID: [String: Date] {
        conversations.reduce(into: [:]) { activityByUserID, conversation in
            guard conversation.kind == .directMessage else {
                return
            }
            for userID in [conversation.participantUserID, conversation.id].compactMap({ $0 }) {
                let existing = activityByUserID[userID] ?? .distantPast
                activityByUserID[userID] = max(existing, conversation.latestActivity)
            }
        }
    }

    var conversationNamesByID: [String: String] {
        Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0.title) })
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

    func apply(
        _ messages: [Message],
        to channelID: String,
        activityObservedAt: Date? = nil
    ) {
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
        var preparedMessages: [Message] = []
        preparedMessages.reserveCapacity(messages.count)
        for message in messages {
            let message = message.preparingForDisplay(context: formattingContext)
            if message.remoteID != nil {
                messagesByID["local:\(message.id)"] = nil
            }
            let key = message.remoteID.map { "remote:\($0)" } ?? "local:\(message.id)"
            messagesByID[key] = message
            preparedMessages.append(message)
        }
        conversations[index].messages = messagesByID.values.sorted {
            $0.timestamp < $1.timestamp
        }
        workspaceSearchIndex.merge(
            messages: preparedMessages,
            conversation: conversations[index]
        )
        activityIndex.merge(
            messages: preparedMessages,
            conversation: conversations[index],
            currentUserID: credentials?.userID,
            observedAt: activityObservedAt
        )
        refreshSavedMessageSnapshots(
            preparedMessages,
            conversationID: channelID
        )
        reconcileOutgoingMessages(preparedMessages)
        reconcileMessageMutations(
            preparedMessages,
            conversationID: channelID
        )
    }

    private func startWorkspaceSearchBackfill() {
        workspaceSearchBackfillTask?.cancel()
        guard let historyCache else {
            workspaceSearchBackfillTask = nil
            return
        }
        workspaceSearchBackfillTask = Task(priority: .utility) {
            while !Task.isCancelled {
                do {
                    if try await historyCache.backfillSearchIndex(
                        maximumMessages: 100
                    ) {
                        return
                    }
                } catch {
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
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
        var isFirstPass = true
        while !Task.isCancelled {
            guard let slackAPI else {
                return
            }
            guard let session = try? captureWorkspaceSession(),
                  let credentials = try? await activeCredentials(for: session)
            else {
                try? await Task.sleep(for: .seconds(30))
                continue
            }

            if Date.now >= nextProfileRefresh {
                if let profiles = try? await slackAPI.fetchWorkspaceUsers(
                    accessToken: credentials.accessToken
                ) {
                    guard isCurrentWorkspaceSession(session) else {
                        return
                    }
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
                    guard isCurrentWorkspaceSession(session) else {
                        return
                    }
                    applyDoNotDisturb(statuses)
                } catch let SlackAPIClient.APIError.slack(error) where error == "missing_scope" {
                    canRefreshDoNotDisturb = false
                } catch let SlackAPIClient.APIError.rateLimited(seconds) {
                    try? await Task.sleep(for: .seconds(seconds))
                } catch {
                    // Presence can still refresh when DND is unavailable.
                }
            }

            let presenceUserIDs: [String]
            if isFirstPass {
                presenceUserIDs = Self.userIDsWithStalePresence(
                    userIDs,
                    usersByID: usersByID,
                    now: .now,
                    freshnessThreshold: Self.presenceFreshnessThreshold
                )
                isFirstPass = false
            } else {
                presenceUserIDs = userIDs
            }
            for userID in presenceUserIDs {
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
                    guard isCurrentWorkspaceSession(session) else {
                        return
                    }
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

    nonisolated static func userIDsWithStalePresence(
        _ userIDs: [String],
        usersByID: [String: WorkspaceUser],
        now: Date,
        freshnessThreshold: TimeInterval
    ) -> [String] {
        userIDs.filter { userID in
            guard let fetchedAt = usersByID[userID]?.availability.fetchedAt else {
                return true
            }
            return now.timeIntervalSince(fetchedAt) >= freshnessThreshold
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
        guard let session = try? captureWorkspaceSession() else {
            return nil
        }

        for offset in conversations.indices {
            let index = (backfillConversationIndex + offset) % conversations.count
            let conversationID = conversations[index].id
            guard let status = try? await historyCache.status(channelID: conversationID),
                  isCurrentWorkspaceSession(session),
                  !status.isComplete
            else {
                continue
            }

            backfillConversationIndex = (index + 1) % conversations.count
            do {
                let credentials = try await activeCredentials(for: session)
                let page = try await slackAPI.fetchMessagePage(
                    channelID: conversationID,
                    cursor: status.pageCount == 0 ? nil : status.nextCursor,
                    accessToken: credentials.accessToken,
                    users: messageUsers,
                    channelNames: conversationNamesByID,
                    currentUserID: credentials.userID
                )
                try requireCurrentWorkspaceSession(session)
                try await historyCache.store(
                    MessageHistoryPage(messages: page.messages, nextCursor: page.nextCursor),
                    channelID: conversationID,
                    index: status.pageCount
                )
                try requireCurrentWorkspaceSession(session)
                workspaceSearchIndex.merge(
                    messages: page.messages,
                    conversation: conversations[index]
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

}
