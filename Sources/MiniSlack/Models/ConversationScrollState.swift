import Foundation

struct ConversationScrollState: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case message(UUID)
        case bottom
    }

    private(set) var hasPositionedInitially = false
    private(set) var isAtBottom = true

    mutating func initialTarget(
        lastMessageID: UUID?,
        focusedMessageID: UUID?
    ) -> Target? {
        guard !hasPositionedInitially else {
            return nil
        }
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
