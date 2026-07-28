import Foundation
import Testing
@testable import MiniSlack

struct ConversationScrollStateTests {
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
        _ = state.updateMetrics(isBottomVisible: true, contentHeight: 900)

        #expect(state.shouldFollowLatest(isSearching: false))
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: false))

        // Same content height with the anchor gone: the user scrolled up.
        let reanchorsOnManualScroll = state.updateMetrics(
            isBottomVisible: false,
            contentHeight: 900
        )

        #expect(!reanchorsOnManualScroll)

        #expect(!state.shouldFollowLatest(isSearching: false))
        #expect(state.showsJumpToBottom(hasMessages: true, isSearching: false))
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: true))

        state.didJumpToBottom()

        #expect(state.shouldFollowLatest(isSearching: false))
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: false))
    }

    @Test
    func refocusAlwaysReturnsToBottomEvenAfterScrollingUp() {
        var state = ConversationScrollState()
        let lastMessageID = UUID()
        _ = state.initialTarget(lastMessageID: lastMessageID, focusedMessageID: nil)
        state.finishSettling()
        _ = state.updateMetrics(isBottomVisible: false, contentHeight: 0)

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
            contentHeight: 900
        )

        #expect(!reanchorsWhenLanded)

        state.finishSettling()

        // A late-loading image pushes the anchor past the fold.
        let reanchorsOnGrowth = state.updateMetrics(
            isBottomVisible: false,
            contentHeight: 1_040
        )

        #expect(reanchorsOnGrowth)
        #expect(state.shouldFollowLatest(isSearching: false))
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: false))

        let reanchorsAfterCorrection = state.updateMetrics(
            isBottomVisible: true,
            contentHeight: 1_040
        )

        #expect(!reanchorsAfterCorrection)
        #expect(state.isAtBottom)
    }

    @Test
    func growthDoesNotDragTheUserBackAfterScrollingAway() {
        var state = ConversationScrollState()
        _ = state.focusTarget(lastMessageID: UUID(), focusedMessageID: nil)
        state.finishSettling()
        _ = state.updateMetrics(isBottomVisible: true, contentHeight: 900)
        _ = state.updateMetrics(isBottomVisible: false, contentHeight: 900)

        let reanchorsAfterScrollingAway = state.updateMetrics(
            isBottomVisible: false,
            contentHeight: 1_400
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
            contentHeight: 1_200
        )

        #expect(!reanchorsWhileFocused)

        state.finishSettling()

        #expect(state.showsJumpToBottom(hasMessages: true, isSearching: false))

        state.didJumpToBottom()

        #expect(state.pendingTarget == nil)
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: false))
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
}
