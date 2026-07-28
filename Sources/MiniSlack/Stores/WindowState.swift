import Observation

@MainActor
@Observable
final class WindowState {
    var isCompactSidebarPresented = false
    var isQuickSwitcherPresented = false
    var isWorkspaceSearchPresented = false
    var isUnreadNotificationsPresented = false
    var selectedThread: ThreadIdentifier?
    private(set) var composerFocusRequestID = 0

    func toggleCompactSidebar() {
        isCompactSidebarPresented.toggle()
    }

    func presentCompactSidebar() {
        isCompactSidebarPresented = true
    }

    func dismissCompactSidebar() {
        isCompactSidebarPresented = false
    }

    func toggleUnreadNotifications() {
        isUnreadNotificationsPresented.toggle()
    }

    func dismissUnreadNotifications() {
        isUnreadNotificationsPresented = false
    }

    func presentQuickSwitcher() {
        isCompactSidebarPresented = false
        isWorkspaceSearchPresented = false
        isQuickSwitcherPresented = true
    }

    func dismissQuickSwitcher() {
        isQuickSwitcherPresented = false
    }

    func presentWorkspaceSearch() {
        isCompactSidebarPresented = false
        isQuickSwitcherPresented = false
        isWorkspaceSearchPresented = true
    }

    func dismissWorkspaceSearch() {
        isWorkspaceSearchPresented = false
    }

    func presentThread(_ identifier: ThreadIdentifier) {
        selectedThread = identifier
    }

    func dismissThread() {
        selectedThread = nil
    }

    func requestComposerFocus() {
        composerFocusRequestID += 1
    }
}
