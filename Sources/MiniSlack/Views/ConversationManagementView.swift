import SwiftUI

private enum ConversationManagementSheet: Identifiable {
    case browseChannels
    case createChannel
    case groupMessage
    case editChannel(String)
    case channelMembers(String)
    case groupMembers(String)

    var id: String {
        switch self {
        case .browseChannels:
            "browse-channels"
        case .createChannel:
            "create-channel"
        case .groupMessage:
            "group-message"
        case let .editChannel(id):
            "edit-channel-\(id)"
        case let .channelMembers(id):
            "channel-members-\(id)"
        case let .groupMembers(id):
            "group-members-\(id)"
        }
    }
}

private struct ChannelArchiveRequest: Identifiable {
    let conversation: Conversation
    let isArchiving: Bool

    var id: String {
        "\(conversation.id)-\(isArchiving)"
    }
}

struct ConversationManagementMenu: View {
    let store: AppStore
    @State private var sheet: ConversationManagementSheet?
    @State private var channelToLeave: Conversation?
    @State private var archiveRequest: ChannelArchiveRequest?
    @State private var errorMessage: String?

    var body: some View {
        Menu {
            Button("Browse channels", systemImage: "number") {
                sheet = .browseChannels
            }
            Button("Create channel", systemImage: "plus.rectangle.on.folder") {
                sheet = .createChannel
            }
            Button("New group message", systemImage: "person.2.fill") {
                sheet = .groupMessage
            }

            if let conversation = store.selectedConversation,
               conversation.kind == .channel
            {
                Divider()
                Button("Edit channel", systemImage: "slider.horizontal.3") {
                    sheet = .editChannel(conversation.id)
                }
                Button("Manage members", systemImage: "person.2.badge.gearshape") {
                    sheet = .channelMembers(conversation.id)
                }
                Button(
                    conversation.isArchived ? "Unarchive channel" : "Archive channel",
                    systemImage: conversation.isArchived ? "tray.and.arrow.up" : "archivebox",
                    role: conversation.isArchived ? nil : .destructive
                ) {
                    archiveRequest = ChannelArchiveRequest(
                        conversation: conversation,
                        isArchiving: !conversation.isArchived
                    )
                }
                Divider()
                Button(
                    "Leave #\(conversation.title)",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    role: .destructive
                ) {
                    channelToLeave = conversation
                }
            } else if let conversation = store.selectedConversation,
                      conversation.kind == .groupDirectMessage
            {
                Divider()
                Button("Manage group members", systemImage: "person.2.badge.gearshape") {
                    sheet = .groupMembers(conversation.id)
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Start or manage a conversation")
        .accessibilityLabel("Start or manage a conversation")
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .browseChannels:
                BrowseChannelsSheet(store: store)
            case .createChannel:
                CreateChannelSheet(store: store)
            case .groupMessage:
                NewGroupMessageSheet(store: store)
            case let .editChannel(conversationID):
                if let conversation = store.conversations.first(where: {
                    $0.id == conversationID
                }) {
                    EditChannelSheet(store: store, conversation: conversation)
                }
            case let .channelMembers(conversationID):
                if let conversation = store.conversations.first(where: {
                    $0.id == conversationID
                }) {
                    ManageConversationMembersSheet(
                        store: store,
                        conversation: conversation,
                        mode: .channel
                    )
                }
            case let .groupMembers(conversationID):
                if let conversation = store.conversations.first(where: {
                    $0.id == conversationID
                }) {
                    ManageConversationMembersSheet(
                        store: store,
                        conversation: conversation,
                        mode: .groupDirectMessage
                    )
                }
            }
        }
        .confirmationDialog(
            channelToLeave.map { "Leave #\($0.title)?" } ?? "Leave channel?",
            isPresented: Binding(
                get: { channelToLeave != nil },
                set: { if !$0 { channelToLeave = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Leave channel", role: .destructive) {
                guard let conversation = channelToLeave else {
                    return
                }
                channelToLeave = nil
                Task {
                    do {
                        try await store.leaveChannel(conversation.id)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can rejoin public channels later from Browse channels.")
        }
        .confirmationDialog(
            archiveRequest.map {
                $0.isArchiving
                    ? "Archive #\($0.conversation.title)?"
                    : "Unarchive #\($0.conversation.title)?"
            } ?? "Update channel?",
            isPresented: Binding(
                get: { archiveRequest != nil },
                set: { if !$0 { archiveRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                archiveRequest?.isArchiving == true ? "Archive channel" : "Unarchive channel",
                role: archiveRequest?.isArchiving == true ? .destructive : nil
            ) {
                guard let request = archiveRequest else {
                    return
                }
                archiveRequest = nil
                Task {
                    do {
                        try await store.setChannelArchived(
                            request.isArchiving,
                            conversationID: request.conversation.id
                        )
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                archiveRequest?.isArchiving == true
                    ? "Messages stay searchable, but no new messages can be sent until the channel is unarchived."
                    : "You’ll be added back to the channel when Slack unarchives it."
            )
        }
        .alert(
            "Couldn’t update Slack",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct BrowseChannelsSheet: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedChannelID: String?
    @State private var isLoading = true
    @State private var isJoining = false
    @State private var errorMessage: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ManagementSheetHeader(title: "Browse channels") {
                dismiss()
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find a public channel", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit(openSelectedChannel)
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .padding(12)

            if isLoading {
                Spacer()
                ProgressView("Loading channels…")
                Spacer()
            } else if filteredChannels.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(filteredChannels, selection: $selectedChannelID) { channel in
                    ChannelDiscoveryRow(channel: channel)
                        .tag(channel.id)
                }
                .listStyle(.inset)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }

            HStack {
                Text("\(filteredChannels.count) public channels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(selectedChannel?.isMember == true ? "Open" : "Join") {
                    openSelectedChannel()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedChannel == nil || isJoining)
            }
            .padding(12)
        }
        .frame(minWidth: 380, idealWidth: 460, minHeight: 360, idealHeight: 460)
        .task {
            await loadChannels()
            isSearchFocused = true
        }
        .onChange(of: query) {
            ensureSelection()
        }
    }

    private var filteredChannels: [SlackPublicChannel] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            return store.publicChannels
        }
        return store.publicChannels.filter {
            $0.name.localizedCaseInsensitiveContains(term)
                || ($0.purpose?.localizedCaseInsensitiveContains(term) ?? false)
        }
    }

    private var selectedChannel: SlackPublicChannel? {
        guard let selectedChannelID else {
            return nil
        }
        return filteredChannels.first { $0.id == selectedChannelID }
    }

    private func loadChannels() async {
        isLoading = true
        errorMessage = nil
        do {
            try await store.refreshPublicChannels()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        ensureSelection()
    }

    private func ensureSelection() {
        let channels = filteredChannels
        if selectedChannelID.map({ id in channels.contains { $0.id == id } }) != true {
            selectedChannelID = channels.first?.id
        }
    }

    private func moveSelection(by offset: Int) {
        let channels = filteredChannels
        guard !channels.isEmpty else {
            return
        }
        let current = selectedChannelID.flatMap { id in
            channels.firstIndex { $0.id == id }
        } ?? (offset < 0 ? 0 : -1)
        selectedChannelID = channels[(current + offset + channels.count) % channels.count].id
    }

    private func openSelectedChannel() {
        guard let channel = selectedChannel, !isJoining else {
            return
        }
        isJoining = true
        errorMessage = nil
        Task {
            do {
                try await store.joinPublicChannel(channel)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isJoining = false
            }
        }
    }
}

private struct ChannelDiscoveryRow: View {
    let channel: SlackPublicChannel

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "number")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let purpose = channel.purpose {
                    Text(purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if channel.isMember {
                Text("Joined")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let memberCount = channel.memberCount {
                Label("\(memberCount)", systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct CreateChannelSheet: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isPrivate = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ManagementSheetHeader(title: "Create a channel") {
                dismiss()
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Image(systemName: isPrivate ? "lock.fill" : "number")
                            .foregroundStyle(.secondary)
                        TextField("project-launch", text: $name)
                            .textFieldStyle(.plain)
                            .focused($isNameFocused)
                            .onSubmit(create)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    Text(nameHint)
                        .font(.caption)
                        .foregroundStyle(
                            name.isEmpty || AppStore.isValidChannelName(name)
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(.red)
                        )
                }

                Toggle("Make private", isOn: $isPrivate)
                Text(
                    isPrivate
                        ? "Private channels are visible only to invited members."
                        : "Anyone in the workspace can find and join this channel."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!AppStore.isValidChannelName(name) || isCreating)
            }
            .padding(12)
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 270)
        .onAppear {
            isNameFocused = true
        }
    }

    private var nameHint: String {
        guard !name.isEmpty else {
            return "Lowercase letters, numbers, hyphens, and underscores."
        }
        let normalized = AppStore.normalizedChannelName(name)
        return normalized == name ? "#\(name)" : "Creates #\(normalized)"
    }

    private func create() {
        guard AppStore.isValidChannelName(name), !isCreating else {
            return
        }
        isCreating = true
        errorMessage = nil
        Task {
            do {
                try await store.createChannel(name: name, isPrivate: isPrivate)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}

private struct EditChannelSheet: View {
    private enum Field: Hashable {
        case name
        case topic
        case purpose
    }

    let store: AppStore
    let conversation: Conversation
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var topic: String
    @State private var purpose: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    init(store: AppStore, conversation: Conversation) {
        self.store = store
        self.conversation = conversation
        _name = State(initialValue: conversation.title)
        _topic = State(initialValue: conversation.topic ?? "")
        _purpose = State(initialValue: conversation.purpose ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            ManagementSheetHeader(title: "Edit #\(conversation.title)") {
                dismiss()
            }

            VStack(alignment: .leading, spacing: 13) {
                channelField(
                    title: "Name",
                    placeholder: "project-launch",
                    text: $name,
                    field: .name
                )
                channelField(
                    title: "Topic",
                    placeholder: "What’s happening right now",
                    text: $topic,
                    field: .topic
                )
                channelField(
                    title: "Description",
                    placeholder: "What this channel is for",
                    text: $purpose,
                    field: .purpose
                )

                HStack {
                    Text("Topics and descriptions can be up to 250 characters.")
                    Spacer()
                    Text("\(max(topic.count, purpose.count))/250")
                }
                .font(.caption)
                .foregroundStyle(
                    hasValidDetails
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(.red)
                )

                if conversation.isArchived {
                    Label(
                        "Unarchive this channel before changing its details.",
                        systemImage: "archivebox"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)

            Spacer(minLength: 0)

            HStack {
                Text("⌘↩ saves")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 340)
        .onAppear {
            focusedField = .name
        }
    }

    private var hasValidDetails: Bool {
        topic.count <= 250 && purpose.count <= 250
    }

    private var canSave: Bool {
        AppStore.isValidChannelName(name)
            && hasValidDetails
            && !conversation.isArchived
            && !isSaving
    }

    @ViewBuilder
    private func channelField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: field)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
    }

    private func save() {
        guard canSave else {
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await store.updateChannelDetails(
                    conversationID: conversation.id,
                    name: name,
                    topic: topic,
                    purpose: purpose
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private enum ConversationMemberManagementMode {
    case channel
    case groupDirectMessage
}

private struct ManageConversationMembersSheet: View {
    let store: AppStore
    let conversation: Conversation
    let mode: ConversationMemberManagementMode
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedUserIDs: Set<String> = []
    @State private var keyboardUserID: String?
    @State private var isLoading = true
    @State private var didLoadMembers = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ManagementSheetHeader(title: title) {
                dismiss()
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find people", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit(toggleKeyboardUser)
                    .onKeyPress(.downArrow) {
                        moveKeyboardSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveKeyboardSelection(by: -1)
                        return .handled
                    }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .padding(12)

            if isLoading {
                Spacer()
                ProgressView("Loading members…")
                Spacer()
            } else if filteredUsers.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(filteredUsers) { user in
                    Button {
                        toggle(user.id)
                    } label: {
                        GroupMessageUserRow(
                            store: store,
                            user: user,
                            isSelected: selectedUserIDs.contains(user.id),
                            isKeyboardSelected: keyboardUserID == user.id
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isUserDisabled(user.id))
                }
                .listStyle(.inset)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)

            HStack {
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(saveTitle) {
                    save()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(minWidth: 390, idealWidth: 470, minHeight: 420, idealHeight: 540)
        .task {
            await loadMembers()
            isSearchFocused = true
        }
        .onChange(of: query) {
            ensureKeyboardSelection()
        }
    }

    private var title: String {
        switch mode {
        case .channel:
            "Members of #\(conversation.title)"
        case .groupDirectMessage:
            "Group message members"
        }
    }

    private var candidates: [WorkspaceUser] {
        switch mode {
        case .channel:
            store.users
        case .groupDirectMessage:
            store.groupDirectMessageCandidates
        }
    }

    private var filteredUsers: [WorkspaceUser] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let users = candidates.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
        guard !term.isEmpty else {
            return users
        }
        return users.filter {
            $0.displayName.localizedCaseInsensitiveContains(term)
                || $0.status.localizedCaseInsensitiveContains(term)
        }
    }

    private var canSave: Bool {
        guard !isLoading, !isSaving else {
            return false
        }
        switch mode {
        case .channel:
            return didLoadMembers
        case .groupDirectMessage:
            return (1 ... 8).contains(selectedUserIDs.count)
        }
    }

    private var saveTitle: String {
        switch mode {
        case .channel:
            "Apply"
        case .groupDirectMessage:
            "Open replacement"
        }
    }

    private var selectionSummary: String {
        switch mode {
        case .channel:
            "\(selectedUserIDs.count) selected"
        case .groupDirectMessage:
            "\(selectedUserIDs.count) of 8 selected"
        }
    }

    private var helpText: String {
        switch mode {
        case .channel:
            "Your own membership stays selected. Workspace permissions may limit who you can add or remove."
        case .groupDirectMessage:
            "Slack can’t change an existing group DM. Applying opens the DM for this exact set of people and keeps the original intact."
        }
    }

    private func isUserDisabled(_ userID: String) -> Bool {
        if mode == .channel, userID == store.credentials?.userID {
            return true
        }
        return mode == .groupDirectMessage
            && selectedUserIDs.count == 8
            && !selectedUserIDs.contains(userID)
    }

    private func loadMembers() async {
        errorMessage = nil
        switch mode {
        case .channel:
            do {
                selectedUserIDs = Set(
                    try await store.channelMembers(conversationID: conversation.id)
                        .map(\.id)
                )
                didLoadMembers = true
            } catch {
                errorMessage = error.localizedDescription
            }
        case .groupDirectMessage:
            selectedUserIDs = Set(conversation.participants.map(\.id))
            didLoadMembers = true
        }
        if let currentUserID = store.credentials?.userID, mode == .channel {
            selectedUserIDs.insert(currentUserID)
        }
        isLoading = false
        ensureKeyboardSelection()
    }

    private func toggle(_ userID: String) {
        guard !isUserDisabled(userID) else {
            return
        }
        keyboardUserID = userID
        if selectedUserIDs.contains(userID) {
            selectedUserIDs.remove(userID)
        } else {
            selectedUserIDs.insert(userID)
        }
    }

    private func ensureKeyboardSelection() {
        if keyboardUserID.map({ id in filteredUsers.contains { $0.id == id } }) != true {
            keyboardUserID = filteredUsers.first?.id
        }
    }

    private func moveKeyboardSelection(by offset: Int) {
        let users = filteredUsers
        guard !users.isEmpty else {
            return
        }
        let current = keyboardUserID.flatMap { id in
            users.firstIndex { $0.id == id }
        } ?? (offset < 0 ? 0 : -1)
        keyboardUserID = users[(current + offset + users.count) % users.count].id
    }

    private func toggleKeyboardUser() {
        if let keyboardUserID {
            toggle(keyboardUserID)
        }
    }

    private func save() {
        guard canSave else {
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                switch mode {
                case .channel:
                    try await store.updateChannelMembers(
                        conversationID: conversation.id,
                        selectedUserIDs: selectedUserIDs
                    )
                case .groupDirectMessage:
                    try await store.replaceGroupDirectMessageParticipants(
                        conversationID: conversation.id,
                        with: selectedUserIDs
                    )
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private struct NewGroupMessageSheet: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedUserIDs: Set<String> = []
    @State private var keyboardUserID: String?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ManagementSheetHeader(title: "New group message") {
                dismiss()
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find people", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit(toggleKeyboardUser)
                    .onKeyPress(.downArrow) {
                        moveKeyboardSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveKeyboardSelection(by: -1)
                        return .handled
                    }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .padding(12)

            List(filteredUsers) { user in
                Button {
                    toggle(user.id)
                } label: {
                    GroupMessageUserRow(
                        store: store,
                        user: user,
                        isSelected: selectedUserIDs.contains(user.id),
                        isKeyboardSelected: keyboardUserID == user.id
                    )
                }
                .buttonStyle(.plain)
                .disabled(
                    selectedUserIDs.count == 8
                        && !selectedUserIDs.contains(user.id)
                )
            }
            .listStyle(.inset)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }

            HStack {
                Text("\(selectedUserIDs.count) of 8 selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start group message") {
                    startGroupMessage()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!(2 ... 8).contains(selectedUserIDs.count) || isCreating)
            }
            .padding(12)
        }
        .frame(minWidth: 380, idealWidth: 460, minHeight: 400, idealHeight: 520)
        .onAppear {
            ensureKeyboardSelection()
            isSearchFocused = true
        }
        .onChange(of: query) {
            ensureKeyboardSelection()
        }
    }

    private var filteredUsers: [WorkspaceUser] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            return store.groupDirectMessageCandidates
        }
        return store.groupDirectMessageCandidates.filter {
            $0.displayName.localizedCaseInsensitiveContains(term)
                || $0.status.localizedCaseInsensitiveContains(term)
        }
    }

    private func toggle(_ userID: String) {
        keyboardUserID = userID
        if selectedUserIDs.contains(userID) {
            selectedUserIDs.remove(userID)
        } else if selectedUserIDs.count < 8 {
            selectedUserIDs.insert(userID)
        }
    }

    private func ensureKeyboardSelection() {
        if keyboardUserID.map({ id in filteredUsers.contains { $0.id == id } }) != true {
            keyboardUserID = filteredUsers.first?.id
        }
    }

    private func moveKeyboardSelection(by offset: Int) {
        let users = filteredUsers
        guard !users.isEmpty else {
            return
        }
        let current = keyboardUserID.flatMap { id in users.firstIndex { $0.id == id } }
            ?? (offset < 0 ? 0 : -1)
        keyboardUserID = users[(current + offset + users.count) % users.count].id
    }

    private func toggleKeyboardUser() {
        if let keyboardUserID {
            toggle(keyboardUserID)
        }
    }

    private func startGroupMessage() {
        guard (2 ... 8).contains(selectedUserIDs.count), !isCreating else {
            return
        }
        let userIDs = store.groupDirectMessageCandidates
            .filter { selectedUserIDs.contains($0.id) }
            .map(\.id)
        isCreating = true
        errorMessage = nil
        Task {
            do {
                try await store.startGroupDirectMessage(with: userIDs)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}

private struct GroupMessageUserRow: View {
    let store: AppStore
    let user: WorkspaceUser
    let isSelected: Bool
    let isKeyboardSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            UserAvatar(
                imageURL: user.avatarURL,
                initials: user.initials,
                accessibilityName: user.displayName,
                size: 28,
                availability: user.availability
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(user.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                UserStatusLabel(
                    user: user,
                    customEmojiURLs: store.customEmojiURLs
                )
            }
            Spacer(minLength: 8)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(
                    isSelected
                        ? AnyShapeStyle(.orange)
                        : AnyShapeStyle(.tertiary)
                )
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .background(
            isKeyboardSelected ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ManagementSheetHeader: View {
    let title: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
