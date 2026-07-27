import Foundation
import Testing
@testable import MiniSlack

struct ConversationFindStateTests {
    @Test
    func searchesLoadedRenderedMessagesAndAuthorsLocally() {
        let messages = [
            message(id: 1, author: "Maya Chen", body: "Shipped the résumé parser"),
            message(id: 2, author: "Sam", body: "Nothing relevant"),
            message(id: 3, author: "Casey", body: "MAYA reviewed this"),
        ]
        var state = ConversationFindState()

        state.update(query: "resume", messages: messages)
        #expect(state.matchIDs == [messages[0].id])

        state.update(query: "maya", messages: messages)
        #expect(state.matchIDs == [messages[0].id, messages[2].id])
        #expect(state.selectedMessageID == messages[0].id)
    }

    @Test
    func searchesSemanticRichTextWhenSlackFallbackTextIsEmpty() {
        let richText = MessageRichText(
            blocks: [
                .quote([
                    .init(
                        content: .text(raw: "Roadmap complete", display: "Roadmap complete"),
                        style: .init()
                    )
                ])
            ]
        )
        let message = Message(
            author: "Maya",
            body: "",
            timestamp: .distantPast,
            richText: richText
        )
        var state = ConversationFindState()

        state.update(query: "roadmap", messages: [message])

        #expect(state.matchIDs == [message.id])
    }

    @Test
    func arrowAndReturnNavigationWrapAcrossResults() {
        let messages = [
            message(id: 1, body: "ship this"),
            message(id: 2, body: "ship that"),
            message(id: 3, body: "ship everything"),
        ]
        var state = ConversationFindState()
        state.update(query: "ship", messages: messages)

        #expect(state.selectedResultNumber == 1)
        #expect(state.moveSelection(offset: 1) == messages[1].id)
        #expect(state.moveSelection(offset: 1) == messages[2].id)
        #expect(state.moveSelection(offset: 1) == messages[0].id)
        #expect(state.moveSelection(offset: -1) == messages[2].id)
    }

    @Test
    func refreshedWorkingSetPreservesSelectionAndDismissResetClearsIt() {
        let first = message(id: 1, body: "needle one")
        let second = message(id: 2, body: "needle two")
        let older = message(id: 3, body: "needle older")
        var state = ConversationFindState()
        state.update(query: "needle", messages: [first, second])
        state.moveSelection(offset: 1)

        state.refresh(messages: [older, first, second])

        #expect(state.selectedMessageID == second.id)
        #expect(state.selectedResultNumber == 3)

        state.reset()

        #expect(!state.isSearching)
        #expect(state.matchIDs.isEmpty)
        #expect(state.selectedMessageID == nil)
    }

    @Test
    func whitespaceAndNoMatchQueriesDoNotSelectRows() {
        let messages = [message(id: 1, body: "hello")]
        var state = ConversationFindState()

        state.update(query: "   ", messages: messages)
        #expect(!state.isSearching)
        #expect(state.matchIDs.isEmpty)

        state.update(query: "missing", messages: messages)
        #expect(state.isSearching)
        #expect(state.matchIDs.isEmpty)
        #expect(state.moveSelection(offset: 1) == nil)
    }

    private func message(
        id: UInt8,
        author: String = "Author",
        body: String
    ) -> Message {
        Message(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, id)),
            author: author,
            body: body,
            timestamp: .distantPast
        )
    }
}
