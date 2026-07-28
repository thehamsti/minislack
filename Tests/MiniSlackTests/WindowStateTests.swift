import Testing
@testable import MiniSlack

@MainActor
struct WindowStateTests {
    @Test
    func compactSidebarSupportsExplicitOpenCloseAndToggle() {
        let state = WindowState()

        state.presentCompactSidebar()
        #expect(state.isCompactSidebarPresented)

        state.toggleCompactSidebar()
        #expect(!state.isCompactSidebarPresented)

        state.toggleCompactSidebar()
        state.dismissCompactSidebar()
        #expect(!state.isCompactSidebarPresented)
    }

    @Test
    func pointerEntryAndExitCanRevealAndDismissCompactSidebar() {
        let state = WindowState()

        state.presentCompactSidebar()
        #expect(state.isCompactSidebarPresented)

        state.dismissCompactSidebar()
        #expect(!state.isCompactSidebarPresented)
    }

    @Test
    func presentingSearchDismissesCompactSidebar() {
        let state = WindowState()
        state.presentCompactSidebar()

        state.presentQuickSwitcher()
        #expect(!state.isCompactSidebarPresented)
        #expect(state.isQuickSwitcherPresented)

        state.presentCompactSidebar()
        state.presentWorkspaceSearch()
        #expect(!state.isCompactSidebarPresented)
        #expect(state.isWorkspaceSearchPresented)
    }

    @Test
    func composerFocusRequestsAdvanceForRepeatedShortcuts() {
        let state = WindowState()

        #expect(state.composerFocusRequestID == 0)

        state.requestComposerFocus()
        state.requestComposerFocus()

        #expect(state.composerFocusRequestID == 2)
    }
}
