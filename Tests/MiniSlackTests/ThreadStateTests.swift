import Foundation
import Testing
@testable import MiniSlack

struct ThreadStateTests {
    @Test
    func mergeSeparatesTheRootDeduplicatesRepliesAndSortsOldestFirst() {
        let root = message(id: "100", author: "U1", time: 100)
        var state = ThreadState(
            id: ThreadIdentifier(conversationID: "C1", rootTimestamp: "100"),
            root: root
        )

        state.merge(
            [
                message(id: "102", author: "U2", time: 102),
                message(id: "100", author: "U1", time: 100, body: "Updated root"),
                message(id: "101", author: "U1", time: 101),
            ],
            nextCursor: "older"
        )
        state.merge(
            [message(id: "101", author: "U1", time: 101, body: "Updated reply")],
            nextCursor: nil
        )

        #expect(state.root.body == "Updated root")
        #expect(state.replies.map(\.remoteID) == ["101", "102"])
        #expect(state.replies.first?.body == "Updated reply")
        #expect(state.nextCursor == nil)
        #expect(state.participants == ["U1", "U2"])
    }

    @Test
    func optimisticReplyCanBeConfirmedWithoutChangingItsStableIdentity() {
        let root = message(id: "100", author: "U1", time: 100)
        var state = ThreadState(
            id: ThreadIdentifier(conversationID: "C1", rootTimestamp: "100"),
            root: root
        )
        let optimistic = Message(
            author: "You",
            authorUserID: "U0",
            body: "Reply",
            timestamp: Date(timeIntervalSince1970: 101),
            isCurrentUser: true
        )

        state.appendOptimistic(optimistic)
        state.confirm(localID: optimistic.id, remoteTimestamp: "101.500")

        #expect(state.replies.first?.id == optimistic.id)
        #expect(state.replies.first?.remoteID == "101.500")
    }

    private func message(
        id: String,
        author: String,
        time: TimeInterval,
        body: String = "Message"
    ) -> Message {
        Message(
            author: author,
            authorUserID: author,
            body: body,
            timestamp: Date(timeIntervalSince1970: time),
            remoteID: id
        )
    }
}
