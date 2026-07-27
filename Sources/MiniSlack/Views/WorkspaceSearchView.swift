import AppKit
import SwiftUI

struct WorkspaceSearchView: View {
    let store: AppStore
    let windowState: WindowState
    @State private var mode = WorkspaceSearchMode.local
    @State private var query = ""
    @State private var results: [WorkspaceSearchResult] = []
    @State private var selectedResultID: String?
    @State private var isLocalLoading = false
    @State private var isRemoteLoading = false
    @State private var errorMessage: String?
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            resultList
            Divider()
            footer
        }
        .onChange(of: windowState.isWorkspaceSearchPresented) {
            if windowState.isWorkspaceSearchPresented {
                reset()
                Task { @MainActor in
                    isSearchFieldFocused = true
                }
            } else {
                isSearchFieldFocused = false
            }
        }
        .onChange(of: mode) {
            refreshImmediateResults()
        }
        .task(id: remoteRequest) {
            await performRemoteSearchIfNeeded()
        }
        .task(id: localRequest) {
            await performLocalHistorySearchIfNeeded()
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(
                mode == .local ? "Search downloaded messages" : "Search Slack",
                text: Binding(
                    get: { query },
                    set: {
                        query = $0
                        refreshImmediateResults()
                    }
                )
            )
            .textFieldStyle(.plain)
            .focused($isSearchFieldFocused)
            .onSubmit {
                openSelectedResult()
            }
            .onKeyPress(.downArrow) {
                moveSelection(offset: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                moveSelection(offset: -1)
                return .handled
            }
            .onKeyPress(.escape) {
                windowState.dismissWorkspaceSearch()
                return .handled
            }

            Picker("Search source", selection: $mode) {
                ForEach(WorkspaceSearchMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 132)

            Button {
                windowState.dismissWorkspaceSearch()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close search (Esc)")
            .accessibilityLabel("Close workspace search")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    @ViewBuilder
    private var resultList: some View {
        if normalizedQuery.isEmpty {
            ContentUnavailableView(
                mode == .local ? "Search Offline" : "Search Slack",
                systemImage: mode == .local ? "internaldrive" : "cloud",
                description: Text(
                    mode == .local
                        ? "Search downloaded messages, people, and conversations."
                        : "Search Slack messages and files, plus local people and conversations."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty, isSearchLoading {
            ProgressView(
                mode == .local
                    ? "Searching downloaded history…"
                    : "Searching Slack…"
            )
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(results) { result in
                            WorkspaceSearchResultRow(
                                store: store,
                                result: result,
                                isSelected: result.id == selectedResultID
                            ) {
                                selectedResultID = result.id
                                open(result)
                            }
                            .id(result.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selectedResultID) {
                    if let selectedResultID {
                        proxy.scrollTo(selectedResultID, anchor: .center)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isSearchLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(footerText)
                .lineLimit(1)
            Spacer()
            if !results.isEmpty {
                Text("↑↓ Navigate  ↩ Open")
            }
        }
        .font(.caption2)
        .foregroundStyle(
            errorMessage == nil ? Color.secondary.opacity(0.7) : Color.red
        )
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private var footerText: String {
        if let errorMessage {
            return errorMessage
        }
        if normalizedQuery.isEmpty {
            return mode == .local ? "No network requests" : "Remote requests wait until you pause"
        }
        return "\(results.count) result\(results.count == 1 ? "" : "s")"
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var remoteRequest: RemoteSearchRequest {
        RemoteSearchRequest(
            isPresented: windowState.isWorkspaceSearchPresented,
            mode: mode,
            query: normalizedQuery
        )
    }

    private var localRequest: LocalSearchRequest {
        LocalSearchRequest(
            isPresented: windowState.isWorkspaceSearchPresented,
            mode: mode,
            query: normalizedQuery
        )
    }

    private var isSearchLoading: Bool {
        isLocalLoading || isRemoteLoading
    }

    private func reset() {
        mode = .local
        query = ""
        results = []
        selectedResultID = nil
        isLocalLoading = false
        isRemoteLoading = false
        errorMessage = nil
    }

    private func refreshImmediateResults() {
        errorMessage = nil
        guard !normalizedQuery.isEmpty else {
            results = []
            selectedResultID = nil
            isLocalLoading = false
            isRemoteLoading = false
            return
        }

        switch mode {
        case .local:
            isLocalLoading = true
            isRemoteLoading = false
            setResults(store.searchWorkspaceLocally(normalizedQuery))
        case .slack:
            isLocalLoading = false
            isRemoteLoading = true
            setResults(store.searchWorkspaceEntities(normalizedQuery))
        }
    }

    private func performLocalHistorySearchIfNeeded() async {
        guard localRequest.isPresented,
              localRequest.mode == .local,
              !localRequest.query.isEmpty
        else {
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(75))
            let diskResults = try await store.searchWorkspaceHistory(
                localRequest.query
            )
            try Task.checkCancellation()
            let entities = store.searchWorkspaceEntities(localRequest.query)
            let hotMessages = store.workspaceSearchIndex.searchMessages(
                query: localRequest.query
            )
            setResults(
                WorkspaceSearchIndex.boundedMerge(
                    entities: entities,
                    content: diskResults + hotMessages
                )
            )
            isLocalLoading = false
        } catch is CancellationError {
            return
        } catch {
            isLocalLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func performRemoteSearchIfNeeded() async {
        guard remoteRequest.isPresented,
              remoteRequest.mode == .slack,
              !remoteRequest.query.isEmpty
        else {
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(300))
            let remoteResults = try await store.searchWorkspaceRemotely(
                remoteRequest.query
            )
            try Task.checkCancellation()
            let entities = store.searchWorkspaceEntities(remoteRequest.query)
            setResults(
                WorkspaceSearchIndex.boundedMerge(
                    entities: entities,
                    content: remoteResults
                )
            )
            isRemoteLoading = false
        } catch is CancellationError {
            return
        } catch {
            isRemoteLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func setResults(_ newResults: [WorkspaceSearchResult]) {
        results = Array(newResults.prefix(WorkspaceSearchIndex.maximumResultCount))
        if selectedResultID.map({ id in results.contains { $0.id == id } }) != true {
            selectedResultID = results.first?.id
        }
    }

    private func moveSelection(offset: Int) {
        guard !results.isEmpty else {
            selectedResultID = nil
            return
        }
        let currentIndex = selectedResultID.flatMap { selectedID in
            results.firstIndex { $0.id == selectedID }
        } ?? (offset < 0 ? 0 : -1)
        selectedResultID = results[
            (currentIndex + offset + results.count) % results.count
        ].id
    }

    private func openSelectedResult() {
        guard let selectedResultID,
              let result = results.first(where: { $0.id == selectedResultID })
        else {
            return
        }
        open(result)
    }

    private func open(_ result: WorkspaceSearchResult) {
        windowState.dismissWorkspaceSearch()
        Task { @MainActor in
            if let externalURL = await store.openWorkspaceSearchResultLoadingMessage(
                result
            ) {
                NSWorkspace.shared.open(externalURL)
            }
        }
    }
}

private struct WorkspaceSearchResultRow: View {
    let store: AppStore
    let result: WorkspaceSearchResult
    let isSelected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                leadingView
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if result.source == .remote {
                            Text("Slack")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(result.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                if let timestamp = result.timestamp {
                    Text(timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if result.kind == .file || result.conversationID == nil,
                   result.permalink != nil
                {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var leadingView: some View {
        if result.kind == .person,
           let userID = result.userID,
           let user = store.user(withID: userID)
        {
            UserAvatar(
                imageURL: user.avatarURL,
                initials: user.initials,
                accessibilityName: user.displayName,
                size: 30,
                availability: user.availability
            )
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var systemImage: String {
        switch result.kind {
        case .message:
            "bubble.left"
        case .person:
            "person"
        case .channel:
            "number"
        case .file:
            "doc"
        }
    }
}

private struct RemoteSearchRequest: Hashable {
    let isPresented: Bool
    let mode: WorkspaceSearchMode
    let query: String
}

private struct LocalSearchRequest: Hashable {
    let isPresented: Bool
    let mode: WorkspaceSearchMode
    let query: String
}
