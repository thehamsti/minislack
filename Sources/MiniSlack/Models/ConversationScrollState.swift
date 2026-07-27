import Foundation

struct ConversationScrollState: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case message(UUID)
        case bottom
    }

    private(set) var hasPositionedInitially = false
    private(set) var isAtBottom = true

    /// Target used the first time a conversation list has content to position.
    mutating func initialTarget(
        lastMessageID: UUID?,
        focusedMessageID: UUID?
    ) -> Target? {
        guard !hasPositionedInitially else {
            return nil
        }
        return focusTarget(
            lastMessageID: lastMessageID,
            focusedMessageID: focusedMessageID
        )
    }

    /// Target used whenever a conversation is (re)focused.
    /// Always re-anchors to the bottom unless a specific message is focused.
    mutating func focusTarget(
        lastMessageID: UUID?,
        focusedMessageID: UUID?
    ) -> Target? {
        if let focusedMessageID {
            hasPositionedInitially = true
            isAtBottom = false
            return .message(focusedMessageID)
        }
        guard lastMessageID != nil else {
            return nil
        }
        hasPositionedInitially = true
        isAtBottom = true
        return .bottom
    }

    mutating func updateBottomVisibility(_ isVisible: Bool) {
        guard hasPositionedInitially else {
            return
        }
        isAtBottom = isVisible
    }

    mutating func didJumpToBottom() {
        hasPositionedInitially = true
        isAtBottom = true
    }

    func shouldFollowLatest(isSearching: Bool) -> Bool {
        hasPositionedInitially && isAtBottom && !isSearching
    }

    func showsJumpToBottom(hasMessages: Bool, isSearching: Bool) -> Bool {
        hasMessages && hasPositionedInitially && !isAtBottom && !isSearching
    }
}
