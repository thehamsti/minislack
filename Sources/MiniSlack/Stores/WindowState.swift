import Observation

@MainActor
@Observable
final class WindowState {
    var isQuickSwitcherPresented = false

    func presentQuickSwitcher() {
        isQuickSwitcherPresented = true
    }

    func dismissQuickSwitcher() {
        isQuickSwitcherPresented = false
    }
}
