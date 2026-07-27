import Foundation

struct ConversationFindState: Equatable {
    private(set) var query = ""
    private(set) var matchIDs: [UUID] = []
    private(set) var selectionIndex: Int?

    var isSearching: Bool {
        !normalizedQuery.isEmpty
    }

    var selectedMessageID: UUID? {
        guard let selectionIndex, matchIDs.indices.contains(selectionIndex) else {
            return nil
        }
        return matchIDs[selectionIndex]
    }

    var selectedResultNumber: Int? {
        selectionIndex.map { $0 + 1 }
    }

    mutating func update(query: String, messages: [Message]) {
        self.query = query
        refresh(messages: messages)
    }

    mutating func refresh(messages: [Message]) {
        let previousSelection = selectedMessageID
        let searchTerm = normalizedQuery
        guard !searchTerm.isEmpty else {
            matchIDs = []
            selectionIndex = nil
            return
        }

        matchIDs = messages.compactMap { message in
            Self.matches(message, query: searchTerm) ? message.id : nil
        }

        if let previousSelection,
           let previousIndex = matchIDs.firstIndex(of: previousSelection)
        {
            selectionIndex = previousIndex
        } else {
            selectionIndex = matchIDs.isEmpty ? nil : 0
        }
    }

    @discardableResult
    mutating func moveSelection(offset: Int) -> UUID? {
        guard !matchIDs.isEmpty else {
            selectionIndex = nil
            return nil
        }

        let currentIndex = selectionIndex ?? 0
        selectionIndex = (currentIndex + offset % matchIDs.count + matchIDs.count)
            % matchIDs.count
        return selectedMessageID
    }

    mutating func reset() {
        self = ConversationFindState()
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ message: Message, query: String) -> Bool {
        message.author.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
            || message.copyText.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
    }
}
