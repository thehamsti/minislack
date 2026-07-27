import SwiftUI

struct NavigationCommandActions {
    let openQuickSwitcher: () -> Void
    let showUnreadInbox: () -> Void
    let moveToNextUnread: () -> Void
    let moveToPreviousUnread: () -> Void
    let markConversationRead: () -> Void
    let canMarkConversationRead: Bool
}

private struct NavigationCommandActionsKey: FocusedValueKey {
    typealias Value = NavigationCommandActions
}

extension FocusedValues {
    var navigationCommandActions: NavigationCommandActions? {
        get { self[NavigationCommandActionsKey.self] }
        set { self[NavigationCommandActionsKey.self] = newValue }
    }
}

struct MiniSlackNavigationCommands: Commands {
    @FocusedValue(\.navigationCommandActions) private var actions

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Quick Switcher…") {
                actions?.openQuickSwitcher()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(actions == nil)

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
