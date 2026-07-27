import SwiftUI

struct NavigationCommandActions {
    let openQuickSwitcher: () -> Void
    let showUnreadInbox: () -> Void
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
    @FocusedValue(\.navigationCommandActions) private var actions
    @FocusedValue(\.conversationFindActions) private var findActions
    @FocusedValue(\.workspaceSearchActions) private var workspaceSearchActions

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Quick Switcher…") {
                actions?.openQuickSwitcher()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(actions == nil)

            Button("Find in Conversation…") {
                findActions?.present()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(findActions == nil)

            Button("Search Workspace…") {
                workspaceSearchActions?.present()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(workspaceSearchActions == nil)

            Button("Unread Inbox") {
                actions?.showUnreadInbox()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Divider()

            Button("Next Unread") {
                actions?.moveToNextUnread()
            }
            .keyboardShortcut(.downArrow, modifiers: .control)
            .disabled(actions == nil)

            Button("Previous Unread") {
                actions?.moveToPreviousUnread()
            }
            .keyboardShortcut(.upArrow, modifiers: .control)
            .disabled(actions == nil)

            Button("Mark Conversation Read") {
                actions?.markConversationRead()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(actions?.canMarkConversationRead != true)
        }
    }
}
