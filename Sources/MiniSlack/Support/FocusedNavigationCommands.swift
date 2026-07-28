import SwiftUI

struct NavigationCommandActions {
    let openQuickSwitcher: () -> Void
    let showUnreadInbox: () -> Void
    let showUnreadNotifications: () -> Void
    let canShowUnreadNotifications: Bool
    let moveToNextUnread: () -> Void
    let moveToPreviousUnread: () -> Void
    let markConversationRead: () -> Void
    let canMarkConversationRead: Bool
}

struct ConversationFindActions {
    let present: () -> Void
}

struct WorkspaceSearchActions {
    let present: () -> Void
}

private struct NavigationCommandActionsKey: FocusedValueKey {
    typealias Value = NavigationCommandActions
}

private struct ConversationFindActionsKey: FocusedValueKey {
    typealias Value = ConversationFindActions
}

private struct WorkspaceSearchActionsKey: FocusedValueKey {
    typealias Value = WorkspaceSearchActions
}

extension FocusedValues {
    var navigationCommandActions: NavigationCommandActions? {
        get { self[NavigationCommandActionsKey.self] }
        set { self[NavigationCommandActionsKey.self] = newValue }
    }

    var conversationFindActions: ConversationFindActions? {
        get { self[ConversationFindActionsKey.self] }
        set { self[ConversationFindActionsKey.self] = newValue }
    }

    var workspaceSearchActions: WorkspaceSearchActions? {
        get { self[WorkspaceSearchActionsKey.self] }
        set { self[WorkspaceSearchActionsKey.self] = newValue }
    }
}

struct MiniSlackNavigationCommands: Commands {
    let shortcuts: KeyboardShortcutStore
    @FocusedValue(\.navigationCommandActions) private var actions
    @FocusedValue(\.conversationFindActions) private var findActions
    @FocusedValue(\.workspaceSearchActions) private var workspaceSearchActions

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Quick Switcher…") {
                actions?.openQuickSwitcher()
            }
            .keyboardShortcut(shortcuts.binding(for: .quickSwitcher))
            .disabled(actions == nil)

            Button("Find in Conversation…") {
                findActions?.present()
            }
            .keyboardShortcut(shortcuts.binding(for: .findInConversation))
            .disabled(findActions == nil)

            Button("Search Workspace…") {
                workspaceSearchActions?.present()
            }
            .keyboardShortcut(shortcuts.binding(for: .searchWorkspace))
            .disabled(workspaceSearchActions == nil)

            Button("Unread Inbox") {
                actions?.showUnreadInbox()
            }
            .keyboardShortcut(shortcuts.binding(for: .unreadInbox))
            .disabled(actions == nil)

            Button("Unread Notifications") {
                actions?.showUnreadNotifications()
            }
            .keyboardShortcut(shortcuts.binding(for: .unreadNotifications))
            .disabled(actions?.canShowUnreadNotifications != true)

            Divider()

            Button("Next Unread") {
                actions?.moveToNextUnread()
            }
            .keyboardShortcut(shortcuts.binding(for: .nextUnread))
            .disabled(actions == nil)

            Button("Previous Unread") {
                actions?.moveToPreviousUnread()
            }
            .keyboardShortcut(shortcuts.binding(for: .previousUnread))
            .disabled(actions == nil)

            Button("Mark Conversation Read") {
                actions?.markConversationRead()
            }
            .keyboardShortcut(shortcuts.binding(for: .markConversationRead))
            .disabled(actions?.canMarkConversationRead != true)
        }
    }
}
