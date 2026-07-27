import Foundation
import Testing
@testable import MiniSlack

struct ComposerDraftTests {
    @Test
    func detectsUserAndChannelQueriesAtTheCaret() throws {
        let userDraft = ComposerDraft(text: "Ask @maya today")
        let userQuery = try #require(
            userDraft.query(
                at: NSRange(
                    location: ("Ask @ma" as NSString).length,
                    length: 0
                )
            )
        )
        let channelDraft = ComposerDraft(text: "See #clientcredentials")
        let channelQuery = try #require(
            channelDraft.query(
                at: NSRange(
                    location: ("See #clientcredentials" as NSString).length,
                    length: 0
                )
            )
        )

        #expect(userQuery.kind == .user)
        #expect(userQuery.term == "maya")
        #expect(
            (userDraft.text as NSString).substring(with: userQuery.range)
                == "@maya"
        )
        #expect(channelQuery.kind == .channel)
        #expect(channelQuery.term == "clientcredentials")
    }

    @Test
    func ignoresEmailAddressesAndExistingTags() throws {
        let email = ComposerDraft(text: "maya@example.com")
        #expect(
            email.query(
                at: NSRange(
                    location: (email.text as NSString).length,
                    length: 0
                )
            ) == nil
        )

        var tagged = ComposerDraft(text: "@ma")
        let query = try #require(
            tagged.query(at: NSRange(location: 3, length: 0))
        )
        _ = tagged.insert(suggestion: userSuggestion(), replacing: query)

        #expect(
            tagged.query(
                at: NSRange(
                    location: ("@Maya Chen" as NSString).length,
                    length: 0
                )
            ) == nil
        )
    }

    @Test
    func insertsFriendlyTagsAndSerializesSlackIDs() throws {
        var draft = ComposerDraft(text: "Ask @ma in #cli")
        let userQuery = try #require(
            draft.query(
                at: NSRange(location: ("Ask @ma" as NSString).length, length: 0)
            )
        )
        _ = draft.insert(suggestion: userSuggestion(), replacing: userQuery)
        let channelQuery = try #require(
            draft.query(
                at: NSRange(location: (draft.text as NSString).length, length: 0)
            )
        )
        _ = draft.insert(suggestion: channelSuggestion(), replacing: channelQuery)

        #expect(draft.text == "Ask @Maya Chen in #clientcredentials ")
        #expect(draft.slackText == "Ask <@U1> in <#C1> ")
    }

    @Test
    func escapesLiteralSlackControlCharactersButPreservesTags() throws {
        var draft = ComposerDraft(text: "Use <this> & ask @ma")
        let query = try #require(
            draft.query(
                at: NSRange(location: (draft.text as NSString).length, length: 0)
            )
        )
        _ = draft.insert(suggestion: userSuggestion(), replacing: query)

        #expect(
            draft.slackText
                == "Use &lt;this&gt; &amp; ask <@U1> "
        )
    }

    @Test
    func keepsUnselectedReferencesLiteralAndExistingWhitespaceIntact() throws {
        let literalDraft = ComposerDraft(text: "Ask @maya in #general")
        #expect(literalDraft.slackText == "Ask @maya in #general")

        var taggedDraft = ComposerDraft(text: "Ask @ma today")
        let query = try #require(
            taggedDraft.query(
                at: NSRange(location: ("Ask @ma" as NSString).length, length: 0)
            )
        )
        let selection = taggedDraft.insert(
            suggestion: userSuggestion(),
            replacing: query
        )

        #expect(taggedDraft.text == "Ask @Maya Chen today")
        #expect(taggedDraft.slackText == "Ask <@U1> today")
        #expect(selection.location == ("Ask @Maya Chen" as NSString).length)
    }

    @Test
    func shiftsTagsForEarlierEditsAndInvalidatesEditedTags() throws {
        var shifted = ComposerDraft(text: "@ma")
        let query = try #require(
            shifted.query(at: NSRange(location: 3, length: 0))
        )
        _ = shifted.insert(suggestion: userSuggestion(), replacing: query)
        shifted.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: "Hello "
        )

        #expect(shifted.slackText == "Hello <@U1> ")

        let mayaRange = (shifted.text as NSString).range(of: "Maya")
        shifted.replaceCharacters(in: mayaRange, with: "Mya")

        #expect(shifted.slackText == "Hello @Mya Chen ")
    }

    @Test
    func handlesUTF16OffsetsBeforeTags() throws {
        var draft = ComposerDraft(text: "👋 @ma")
        let query = try #require(
            draft.query(
                at: NSRange(location: (draft.text as NSString).length, length: 0)
            )
        )
        _ = draft.insert(suggestion: userSuggestion(), replacing: query)

        #expect(draft.text == "👋 @Maya Chen ")
        #expect(draft.slackText == "👋 <@U1> ")
    }

    @Test
    func exactEditRangesPreserveTheSurvivingDuplicateNameID() throws {
        var draft = ComposerDraft(text: "@sa @sa")
        let firstQuery = try #require(
            draft.query(at: NSRange(location: 3, length: 0))
        )
        _ = draft.insert(
            suggestion: userSuggestion(id: "U1", displayName: "Same"),
            replacing: firstQuery
        )
        let secondQuery = try #require(
            draft.query(
                at: NSRange(location: (draft.text as NSString).length, length: 0)
            )
        )
        _ = draft.insert(
            suggestion: userSuggestion(id: "U2", displayName: "Same"),
            replacing: secondQuery
        )

        let removedRange = NSRange(
            location: 0,
            length: ("@Same " as NSString).length
        )
        let remainingText = (draft.text as NSString).substring(
            from: NSMaxRange(removedRange)
        )
        draft.applyTextChange(
            remainingText,
            replacing: removedRange,
            replacementLength: 0
        )

        #expect(draft.slackText == "<@U2> ")
    }

    @Test
    func suggestionIndexSeparatesPeopleAndChannelsAndRanksPrefixes() {
        let index = ComposerSuggestionIndex(
            users: [
                WorkspaceUser(
                    id: "amaya",
                    displayName: "Amaya",
                    status: "Design",
                    isActive: true
                ),
                WorkspaceUser(
                    id: "maya",
                    displayName: "Maya",
                    status: "Product",
                    isActive: true
                ),
            ],
            conversations: [
                conversation(id: "C1", title: "clientcredentials", kind: .channel),
                conversation(id: "D1", title: "Client Person", kind: .directMessage),
            ]
        )

        let people = index.matches(
            query: ComposerQuery(
                kind: .user,
                term: "maya",
                range: NSRange(location: 0, length: 5)
            ),
            allowsBroadcasts: false
        )
        let channels = index.matches(
            query: ComposerQuery(
                kind: .channel,
                term: "client",
                range: NSRange(location: 0, length: 7)
            ),
            allowsBroadcasts: false
        )

        #expect(people.map(\.entityID) == ["maya", "amaya"])
        #expect(channels.map(\.entityID) == ["C1"])
    }

    @Test
    func broadMentionsRequireAChannelAndAnExplicitQuery() {
        let index = ComposerSuggestionIndex(users: [], conversations: [])
        let query = ComposerQuery(
            kind: .user,
            term: "here",
            range: NSRange(location: 0, length: 5)
        )

        #expect(
            index.matches(query: query, allowsBroadcasts: false).isEmpty
        )
        #expect(
            index.matches(query: query, allowsBroadcasts: true)
                .map(\.displayText) == ["@here"]
        )
    }

    @Test
    func capsSuggestionResultsWithoutIncludingDirectMessagesAsChannels() {
        let conversations = (0 ..< 12).map {
            conversation(
                id: "C\($0)",
                title: "project-\($0)",
                kind: .channel
            )
        } + [
            conversation(id: "D1", title: "project-direct", kind: .directMessage)
        ]
        let index = ComposerSuggestionIndex(
            users: [],
            conversations: conversations
        )
        let results = index.matches(
            query: ComposerQuery(
                kind: .channel,
                term: "project",
                range: NSRange(location: 0, length: 8)
            ),
            allowsBroadcasts: false,
            limit: 5
        )

        #expect(results.count == 5)
        #expect(results.allSatisfy { $0.tagKind == .channel })
        #expect(!results.map(\.entityID).contains("D1"))
    }

    @Test
    @MainActor
    func preservesSemanticDraftsPerConversation() throws {
        let store = AppStore(
            conversations: [
                conversation(id: "C1", title: "general", kind: .channel),
                conversation(id: "C2", title: "random", kind: .channel),
            ],
            users: []
        )
        store.select("C1")
        var taggedDraft = ComposerDraft(text: "Hi @ma")
        let query = try #require(
            taggedDraft.query(
                at: NSRange(
                    location: (taggedDraft.text as NSString).length,
                    length: 0
                )
            )
        )
        _ = taggedDraft.insert(suggestion: userSuggestion(), replacing: query)
        store.composerDraft = taggedDraft

        store.select("C2")
        store.draft = "Second draft"
        store.select("C1")

        #expect(store.composerDraft.text == "Hi @Maya Chen ")
        #expect(store.composerDraft.slackText == "Hi <@U1> ")
        store.select("C2")
        #expect(store.composerDraft.text == "Second draft")
    }

    @Test
    @MainActor
    func appStoreSendsMarkupWhileKeepingTheOptimisticMessageFriendly() throws {
        let user = WorkspaceUser(
            id: "U1",
            displayName: "Maya Chen",
            status: "Product",
            isActive: true
        )
        let store = AppStore(
            conversations: [
                conversation(id: "C1", title: "general", kind: .channel)
            ],
            users: [user]
        )
        store.select("C1")
        var draft = ComposerDraft(text: "Hi @ma")
        let query = try #require(
            draft.query(
                at: NSRange(location: (draft.text as NSString).length, length: 0)
            )
        )
        _ = draft.insert(suggestion: userSuggestion(), replacing: query)
        store.composerDraft = draft

        store.sendDraft()

        #expect(store.selectedConversation?.messages.last?.body == "Hi <@U1>")
        #expect(
            store.selectedConversation?.messages.last?.displayBody
                == "Hi @Maya Chen"
        )
        #expect(store.composerDraft.isEmpty)
    }

    private func userSuggestion() -> ComposerSuggestion {
        userSuggestion(id: "U1", displayName: "Maya Chen")
    }

    private func userSuggestion(
        id: String,
        displayName: String
    ) -> ComposerSuggestion {
        ComposerSuggestion(
            tagKind: .user,
            entityID: id,
            displayText: "@\(displayName)",
            title: displayName,
            subtitle: "Product",
            avatarURL: nil,
            isActive: true
        )
    }

    private func channelSuggestion() -> ComposerSuggestion {
        ComposerSuggestion(
            tagKind: .channel,
            entityID: "C1",
            displayText: "#clientcredentials",
            title: "clientcredentials",
            subtitle: nil,
            avatarURL: nil,
            isActive: false
        )
    }

    private func conversation(
        id: String,
        title: String,
        kind: ConversationKind
    ) -> Conversation {
        Conversation(
            id: id,
            title: title,
            kind: kind,
            subtitle: nil,
            isFavorite: false,
            unreadCount: 0,
            mentionCount: 0,
            latestActivity: .now,
            messages: []
        )
    }
}
