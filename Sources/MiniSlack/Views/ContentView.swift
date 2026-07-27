import SwiftUI

struct ContentView: View {
    let store: AppStore
    let windowState: WindowState

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
        .background {
            KeyboardNavigationMonitor { action in
                if !windowState.isQuickSwitcherPresented,
                   !windowState.isWorkspaceSearchPresented
                {
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
            SavedMessagesView(store: store, compact: true)
                .transition(.opacity)
        case .conversation:
            ConversationView(store: store, windowState: windowState, compact: true)
                .transition(.opacity)
        }
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
            SavedMessagesView(store: store, compact: false)
        case .conversation:
            ConversationView(store: store, windowState: windowState, compact: false)
        }
    }
}
