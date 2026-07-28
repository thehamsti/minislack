import Foundation

struct ConversationScrollState: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case message(UUID)
        case bottom
    }

    private(set) var hasPositionedInitially = false
    private(set) var isAtBottom = true
    /// Target the list is still trying to reach. Lazy rows resolve their height
    /// after the first layout pass, so one `scrollTo` usually lands short.
    private(set) var pendingTarget: Target?

    private var contentHeight: CGFloat = 0

    /// Layout passes a target is re-applied for before it is treated as final.
    /// One `scrollTo` lands short while lazy rows are still resolving, and only
    /// the bottom keeps correcting itself afterwards through content growth.
    static func settleAttemptLimit(for target: Target) -> Int {
        switch target {
        case .bottom:
            12
        case .message:
            6
        }
    }

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
            pendingTarget = .message(focusedMessageID)
            return .message(focusedMessageID)
        }
        guard lastMessageID != nil else {
            return nil
        }
        hasPositionedInitially = true
        isAtBottom = true
        pendingTarget = .bottom
        return .bottom
    }

    /// Records the latest list measurements. Returns true when the bottom needs
    /// re-anchoring because content grew underneath a list that was pinned
    /// there: media, rich text, and prepended history all resize rows after the
    /// scroll landed, which must not be mistaken for the user scrolling away.
    mutating func updateMetrics(
        isBottomVisible: Bool,
        contentHeight: CGFloat
    ) -> Bool {
        let previousHeight = self.contentHeight
        self.contentHeight = contentHeight
        guard hasPositionedInitially else {
            return false
        }
        if isBottomVisible {
            isAtBottom = true
            return false
        }
        if contentHeight > previousHeight, isAtBottom || pendingTarget == .bottom {
            return true
        }
        isAtBottom = false
        return false
    }

    mutating func didJumpToBottom() {
        hasPositionedInitially = true
        isAtBottom = true
        pendingTarget = nil
    }

    mutating func finishSettling() {
        pendingTarget = nil
    }

    func shouldFollowLatest(isSearching: Bool) -> Bool {
        guard hasPositionedInitially, !isSearching else {
            return false
        }
        return isAtBottom || pendingTarget == .bottom
    }

    mutating func latestMessageTarget(isSearching: Bool) -> Target? {
        guard shouldFollowLatest(isSearching: isSearching) else {
            return nil
        }
        isAtBottom = true
        pendingTarget = .bottom
        return .bottom
    }

    func showsJumpToBottom(hasMessages: Bool, isSearching: Bool) -> Bool {
        hasMessages
            && hasPositionedInitially
            && !isAtBottom
            && !isSearching
            && pendingTarget == nil
    }
}
