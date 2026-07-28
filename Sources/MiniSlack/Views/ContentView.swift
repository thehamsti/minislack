import SwiftUI

struct ContentView: View {
    let store: AppStore
    let windowState: WindowState
    @Environment(KeyboardShortcutStore.self) private var shortcuts

    var body: some View {
        Group {
            switch store.connectionState {
            case .preview, .connected:
                workspace
            case .needsConfiguration, .disconnected, .authorizing, .loading, .failed:
                SlackSignInView(store: store)
            }
        }
        .task {
            await store.restoreSession()
        }
    }

    private var workspace: some View {
        GeometryReader { proxy in
            if proxy.size.width < 700 {
                CompactRootView(store: store, windowState: windowState)
            } else {
                NavigationSplitView {
                    SidebarView(store: store, windowState: windowState)
                        .navigationSplitViewColumnWidth(min: 210, ideal: 242, max: 280)
                } detail: {
                    DestinationView(store: store, windowState: windowState)
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .frame(minWidth: 420, minHeight: 500)
        .overlay {
            QuickSwitcherOverlay(store: store, windowState: windowState)
                .opacity(windowState.isQuickSwitcherPresented ? 1 : 0)
                .allowsHitTesting(windowState.isQuickSwitcherPresented)
                .accessibilityHidden(!windowState.isQuickSwitcherPresented)
        }
        .overlay {
            WorkspaceSearchOverlay(store: store, windowState: windowState)
                .opacity(windowState.isWorkspaceSearchPresented ? 1 : 0)
                .allowsHitTesting(windowState.isWorkspaceSearchPresented)
                .accessibilityHidden(!windowState.isWorkspaceSearchPresented)
        }
        .conversationAttachmentDrop(store: store)
        .background {
            KeyboardNavigationMonitor(settings: shortcuts.settings) { action in
                if !windowState.isQuickSwitcherPresented,
                   !windowState.isWorkspaceSearchPresented
                {
                    if action == .focusComposer {
                        if store.selectedConversation != nil {
                            windowState.requestComposerFocus()
                        }
                        return
                    }
                    if action == .back, windowState.isCompactSidebarPresented {
                        windowState.dismissCompactSidebar()
                        return
                    }
                    if action == .back, windowState.selectedThread != nil {
                        windowState.dismissThread()
                        return
                    }
                    store.handleKeyboardNavigation(action)
                }
            }
            .frame(width: 0, height: 0)
        }
        .focusedSceneValue(
            \.workspaceSearchActions,
            WorkspaceSearchActions(present: windowState.presentWorkspaceSearch)
        )
        .tint(.orange)
    }
}

private struct QuickSwitcherOverlay: View {
    let store: AppStore
    let windowState: WindowState

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.14)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        windowState.dismissQuickSwitcher()
                    }

                QuickSwitcherView(store: store, windowState: windowState)
                    .frame(
                        width: min(500, proxy.size.width - 24),
                        height: min(540, proxy.size.height - 24)
                    )
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(.separator.opacity(0.7), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct WorkspaceSearchOverlay: View {
    let store: AppStore
    let windowState: WindowState

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.14)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        windowState.dismissWorkspaceSearch()
                    }

                WorkspaceSearchView(store: store, windowState: windowState)
                    .frame(
                        width: min(540, proxy.size.width - 24),
                        height: min(600, proxy.size.height - 24)
                    )
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(.separator.opacity(0.7), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct CompactRootView: View {
    let store: AppStore
    let windowState: WindowState

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                destination

                if windowState.isCompactSidebarPresented {
                    Color.black.opacity(0.16)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismissSidebar()
                        }
                        .transition(.opacity)

                    CompactSidebarView(store: store, windowState: windowState)
                        .frame(width: min(280, proxy.size.width - 48))
                        .transition(.move(edge: .leading))
                        .shadow(color: .black.opacity(0.22), radius: 18, x: 5)
                        .onContinuousHover { phase in
                            if case .ended = phase {
                                dismissSidebar()
                            }
                        }
                } else {
                    Color.black.opacity(0.001)
                        .frame(width: 5)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active = phase {
                                presentSidebar()
                            }
                        }
                        .zIndex(1)
                }
            }
        }
        .onChange(of: store.destination) {
            if windowState.isCompactSidebarPresented {
                dismissSidebar()
            }
        }
        .onDisappear {
            windowState.dismissCompactSidebar()
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch store.destination {
        case .unreadInbox:
            UnreadInboxView(store: store, windowState: windowState, compact: true)
                .transition(.opacity)
        case .activity:
            ActivityInboxView(
                store: store,
                windowState: windowState,
                compact: true
            )
            .transition(.opacity)
        case .savedMessages:
            SavedMessagesView(store: store, windowState: windowState, compact: true)
                .transition(.opacity)
        case .conversation:
            ConversationView(store: store, windowState: windowState, compact: true)
                .transition(.opacity)
        }
    }

    private func presentSidebar() {
        withAnimation(.snappy(duration: 0.2)) {
            windowState.presentCompactSidebar()
        }
    }

    private func dismissSidebar() {
        withAnimation(.snappy(duration: 0.2)) {
            windowState.dismissCompactSidebar()
        }
    }
}

private struct CompactSidebarView: View {
    let store: AppStore
    let windowState: WindowState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Acme Studio")
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                ConversationManagementMenu(store: store)

                Button {
                    windowState.presentQuickSwitcher()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Quick switcher (⌘K)")

                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        windowState.dismissCompactSidebar()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help("Close sidebar")
                .accessibilityLabel("Close sidebar")
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(.bar)

            Divider()

            SidebarView(store: store, windowState: windowState, compact: true)
        }
        .background(.regularMaterial)
    }
}

struct CompactSidebarButton: View {
    let windowState: WindowState

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                windowState.toggleCompactSidebar()
            }
        } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(.borderless)
        .help("Open sidebar")
        .accessibilityLabel("Open sidebar")
    }
}

private struct DestinationView: View {
    let store: AppStore
    let windowState: WindowState

    var body: some View {
        switch store.destination {
        case .unreadInbox:
            UnreadInboxView(store: store, windowState: windowState, compact: false)
        case .activity:
            ActivityInboxView(
                store: store,
                windowState: windowState,
                compact: false
            )
        case .savedMessages:
            SavedMessagesView(store: store, windowState: windowState, compact: false)
        case .conversation:
            ConversationView(store: store, windowState: windowState, compact: false)
        }
    }
}
