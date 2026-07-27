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

        #expect(state.shouldFollowLatest(isSearching: false))
        #expect(!state.showsJumpToBottom(hasMessages: true, isSearching: false))

        state.updateBottomVisibility(false)

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
        state.updateBottomVisibility(false)

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
