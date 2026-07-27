import Observation

@MainActor
@Observable
final class WindowState {
    var isQuickSwitcherPresented = false
    var isWorkspaceSearchPresented = false
    var selectedThread: ThreadIdentifier?

    func presentQuickSwitcher() {
        isWorkspaceSearchPresented = false
        isQuickSwitcherPresented = true
    }

    func dismissQuickSwitcher() {
        isQuickSwitcherPresented = false
    }

    func presentWorkspaceSearch() {
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
}
