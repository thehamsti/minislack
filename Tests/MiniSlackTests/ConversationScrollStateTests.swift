import AppKit
import Foundation
import Testing
@testable import MiniSlack

struct ConversationScrollStateTests {
    @Test @MainActor
    func viewportObserverDefersBoundsReportsUntilScrollUpdatesFinish() async {
        let scrollView = NSScrollView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 500)
        )
        scrollView.documentView = NSView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 1_000)
        )
        var reportCount = 0
        let coordinator = ScrollViewportObserver.Coordinator(
            bottomTolerance: 1
        ) { _ in
            reportCount += 1
        }
        coordinator.connect(scrollView)

        #expect(reportCount == 1)

        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        #expect(reportCount == 1)

        for _ in 0..<10 where reportCount == 1 {
            await Task.yield()
        }

        #expect(reportCount == 2)
    }

    @Test
    func scrollViewportPositionHandlesFlippedConversationCoordinates() {
        #expect(
            ScrollViewportPosition.isAtBottom(
                documentBounds: CGRect(x: 0, y: 0, width: 400, height: 1_010),
                visibleRect: CGRect(x: 0, y: 500, width: 400, height: 500),
                isFlipped: true,
                tolerance: 11
            )
        )
        #expect(
            !ScrollViewportPosition.isAtBottom(
                documentBounds: CGRect(x: 0, y: 0, width: 400, height: 1_010),
                visibleRect: CGRect(x: 0, y: 480, width: 400, height: 500),
                isFlipped: true,
                tolerance: 11
            )
        )
    }

    @Test
    func firstLoadedMessagePositionsAtBottomOnce() {
        var state = ConversationScrollState()
        let messageID = UUID()

        #expect(
            state.initialTarget(
                lastMessageID: nil,
                focusedMessageID: nil
            ) == nil
        )
        #expect(
            state.initialTarget(
                lastMessageID: messageID,
                focusedMessageID: nil
            ) == .bottom
        )
        #expect(
            state.initialTarget(
                lastMessageID: messageID,
                focusedMessageID: nil
            ) == nil
        )
    }

    @Test
    func focusedSearchResultWinsOverInitialBottomPosition() {
        var state = ConversationScrollState()
        let lastMessageID = UUID()
        let focusedMessageID = UUID()

        #expect(
            state.initialTarget(
                lastMessageID: lastMessageID,
                focusedMessageID: focusedMessageID
            ) == .message(focusedMessageID)
        )
        #expect(!state.isAtBottom)
    }

    @Test
    func jumpButtonAndNewMessageFollowingRespectScrollPosition() {
        var state = ConversationScrollState()
        _ = state.initialTarget(lastMessageID: UUID(), focusedMessageID: nil)
        state.finishSettling()
        _ = state.updateMetrics(
            isBottomVisible: true,
            contentHeight: 900,
            viewportHeight: 500
        )

        #expect(state.latestMessageTarget(isSearching: false) == .bottom)
        #expect(state.pendingTarget == .bottom)
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: false))
        state.finishSettling()

        // Same content height with the anchor gone: the user scrolled up.
        let reanchorsOnManualScroll = state.updateMetrics(
            isBottomVisible: false,
            contentHeight: 900,
            viewportHeight: 500
        )

        #expect(!reanchorsOnManualScroll)

        #expect(!state.shouldFollowLatest(isSearching: false))
        #expect(state.latestMessageTarget(isSearching: false) == nil)
        #expect(state.showsJumpToBottom(hasMessages: true, isSearching: false))
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: true))

        state.didJumpToBottom()

        #expect(state.shouldFollowLatest(isSearching: false))
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: false))
    }

    @Test
    func newMessageKeepsTheJumpButtonHiddenWhileBottomSettles() {
        var state = ConversationScrollState()
        _ = state.initialTarget(lastMessageID: UUID(), focusedMessageID: nil)
        state.finishSettling()
        _ = state.updateMetrics(
            isBottomVisible: true,
            contentHeight: 900,
            viewportHeight: 500
        )

        #expect(state.latestMessageTarget(isSearching: false) == .bottom)

        let reanchorsDuringRowLayout = state.updateMetrics(
            isBottomVisible: false,
            contentHeight: 1_040,
            viewportHeight: 500
        )

        #expect(reanchorsDuringRowLayout)
        #expect(state.isAtBottom)
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: false))
    }

    @Test
    func refocusAlwaysReturnsToBottomEvenAfterScrollingUp() {
        var state = ConversationScrollState()
        let lastMessageID = UUID()
        _ = state.initialTarget(lastMessageID: lastMessageID, focusedMessageID: nil)
        state.finishSettling()
        _ = state.updateMetrics(
            isBottomVisible: false,
            contentHeight: 0,
            viewportHeight: 500
        )

        #expect(
            state.focusTarget(
                lastMessageID: lastMessageID,
                focusedMessageID: nil
            ) == .bottom
        )
        #expect(state.isAtBottom)
        #expect(state.shouldFollowLatest(isSearching: false))
    }

    @Test
    func contentGrowingUnderAPinnedListReanchorsTheBottom() {
        var state = ConversationScrollState()

        #expect(
            state.focusTarget(lastMessageID: UUID(), focusedMessageID: nil) == .bottom
        )
        #expect(state.pendingTarget == .bottom)
        let reanchorsWhenLanded = state.updateMetrics(
            isBottomVisible: true,
            contentHeight: 900,
            viewportHeight: 500
        )

        #expect(!reanchorsWhenLanded)

        state.finishSettling()

        // A late-loading image pushes the anchor past the fold.
        let reanchorsOnGrowth = state.updateMetrics(
            isBottomVisible: false,
            contentHeight: 1_040,
            viewportHeight: 500
        )

        #expect(reanchorsOnGrowth)
        #expect(state.shouldFollowLatest(isSearching: false))
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: false))

        let reanchorsAfterCorrection = state.updateMetrics(
            isBottomVisible: true,
            contentHeight: 1_040,
            viewportHeight: 500
        )

        #expect(!reanchorsAfterCorrection)
        #expect(state.isAtBottom)
    }

    @Test
    func growthDoesNotDragTheUserBackAfterScrollingAway() {
        var state = ConversationScrollState()
        _ = state.focusTarget(lastMessageID: UUID(), focusedMessageID: nil)
        state.finishSettling()
        _ = state.updateMetrics(
            isBottomVisible: true,
            contentHeight: 900,
            viewportHeight: 500
        )
        _ = state.updateMetrics(
            isBottomVisible: false,
            contentHeight: 900,
            viewportHeight: 500
        )

        let reanchorsAfterScrollingAway = state.updateMetrics(
            isBottomVisible: false,
            contentHeight: 1_400,
            viewportHeight: 500
        )

        #expect(!reanchorsAfterScrollingAway)
        #expect(state.showsJumpToBottom(hasMessages: true, isSearching: false))
    }

    @Test
    func messageTargetSettlesOnAttemptsAndThenAllowsTheJumpButton() {
        var state = ConversationScrollState()
        let focusedMessageID = UUID()

        _ = state.focusTarget(
            lastMessageID: UUID(),
            focusedMessageID: focusedMessageID
        )

        #expect(state.pendingTarget == .message(focusedMessageID))
        #expect(!state.shouldFollowLatest(isSearching: false))
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: false))
        // Growth around a focused message must not yank the list to the bottom.
        let reanchorsWhileFocused = state.updateMetrics(
            isBottomVisible: false,
            contentHeight: 1_200,
            viewportHeight: 500
        )

        #expect(!reanchorsWhileFocused)

        state.finishSettling()

        #expect(state.showsJumpToBottom(hasMessages: true, isSearching: false))

        state.didJumpToBottom()

        #expect(state.pendingTarget == nil)
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: false))
    }

    @Test
    func viewportResizeKeepsAPinnedListAtTheBottom() {
        var state = ConversationScrollState()
        _ = state.focusTarget(lastMessageID: UUID(), focusedMessageID: nil)
        state.finishSettling()
        _ = state.updateMetrics(
            isBottomVisible: true,
            contentHeight: 900,
            viewportHeight: 500
        )

        let reanchorsAfterComposerGrowth = state.updateMetrics(
            isBottomVisible: false,
            contentHeight: 900,
            viewportHeight: 440
        )

        #expect(reanchorsAfterComposerGrowth)
        #expect(state.isAtBottom)
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: false))
    }

    @Test
    func viewportResizeDoesNotMoveAListTheUserScrolledAwayFromBottom() {
        var state = ConversationScrollState()
        _ = state.focusTarget(lastMessageID: UUID(), focusedMessageID: nil)
        state.finishSettling()
        _ = state.updateMetrics(
            isBottomVisible: true,
            contentHeight: 900,
            viewportHeight: 500
        )
        _ = state.updateMetrics(
            isBottomVisible: false,
            contentHeight: 900,
            viewportHeight: 500
        )

        let reanchorsAfterResize = state.updateMetrics(
            isBottomVisible: false,
            contentHeight: 900,
            viewportHeight: 440
        )

        #expect(!reanchorsAfterResize)
        #expect(state.showsJumpToBottom(hasMessages: true, isSearching: false))
    }

    @Test
    func refocusStillHonorsExplicitMessageFocus() {
        var state = ConversationScrollState()
        let lastMessageID = UUID()
        let focusedMessageID = UUID()
        _ = state.initialTarget(lastMessageID: lastMessageID, focusedMessageID: nil)

        #expect(
            state.focusTarget(
                lastMessageID: lastMessageID,
                focusedMessageID: focusedMessageID
            ) == .message(focusedMessageID)
        )
        #expect(!state.isAtBottom)
    }

    @Test
    func visibleLatestMessageIsEligibleToClearUnreadState() {
        var state = ConversationScrollState()
        _ = state.initialTarget(lastMessageID: UUID(), focusedMessageID: nil)

        #expect(
            state.shouldMarkRead(
                isBottomVisible: true,
                hasUnreadMessages: true,
                isSearching: false,
                markReadOnOpen: true,
                isAppActive: true
            )
        )
        #expect(
            !state.shouldMarkRead(
                isBottomVisible: false,
                hasUnreadMessages: true,
                isSearching: false,
                markReadOnOpen: true,
                isAppActive: true
            )
        )
    }

    @Test
    func visibleLatestMessageDoesNotClearUnreadStateWhileInactiveOrSearching() {
        var state = ConversationScrollState()
        _ = state.initialTarget(lastMessageID: UUID(), focusedMessageID: nil)

        #expect(
            !state.shouldMarkRead(
                isBottomVisible: true,
                hasUnreadMessages: true,
                isSearching: false,
                markReadOnOpen: true,
                isAppActive: false
            )
        )
        #expect(
            !state.shouldMarkRead(
                isBottomVisible: true,
                hasUnreadMessages: true,
                isSearching: true,
                markReadOnOpen: true,
                isAppActive: true
            )
        )
    }
}
