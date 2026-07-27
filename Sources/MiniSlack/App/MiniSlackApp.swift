import AppKit
import SwiftUI

@main
struct MiniSlackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore.live()

    var body: some Scene {
        WindowGroup("Mini Slack", id: "main") {
            MiniSlackWindow(store: store)
        }
        .defaultSize(width: 940, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            MiniSlackNavigationCommands()
        }

        Settings {
            SettingsView(store: store)
        }
    }
}

private struct MiniSlackWindow: View {
    let store: AppStore
    @State private var windowState = WindowState()

    var body: some View {
        ContentView(store: store, windowState: windowState)
            .focusedSceneValue(
                \.navigationCommandActions,
                NavigationCommandActions(
                    openQuickSwitcher: windowState.presentQuickSwitcher,
                    showUnreadInbox: store.showUnreadInbox,
                    moveToNextUnread: { store.moveToUnread(offset: 1) },
                    moveToPreviousUnread: { store.moveToUnread(offset: -1) },
                    markConversationRead: store.markSelectedConversationRead,
                    canMarkConversationRead: store.selectedConversation != nil
                )
            )
            .onOpenURL { url in
                Task {
                    await store.handleSlackCallback(url)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
