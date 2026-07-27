import Foundation

enum WorkspaceSearchMode: String, CaseIterable, Hashable, Sendable {
    case local
    case slack

    var title: String {
        switch self {
        case .local:
            "Offline"
        case .slack:
            "Slack"
        }
    }
}

struct WorkspaceSearchResult: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case message
        case person
        case channel
        case file
    }

    enum Source: Hashable, Sendable {
        case local
        case remote
    }

    let id: String
    let kind: Kind
    let source: Source
    let title: String
    let detail: String
    let conversationID: String?
    let userID: String?
    let messageID: UUID?
    let timestamp: Date?
    let permalink: URL?
    let cacheStableID: String?

    init(
        id: String,
        kind: Kind,
        source: Source,
        title: String,
        detail: String,
        conversationID: String?,
        userID: String?,
        messageID: UUID?,
        timestamp: Date?,
        permalink: URL?,
        cacheStableID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.title = title
        self.detail = detail
        self.conversationID = conversationID
        self.userID = userID
        self.messageID = messageID
        self.timestamp = timestamp
        self.permalink = permalink
        self.cacheStableID = cacheStableID
    }
}

struct WorkspaceSearchIndexMetrics: Equatable, Sendable {
    let documentCount: Int
    let prefixCount: Int
    let postingCount: Int
    let retentionEntryCount: Int
}

struct WorkspaceSearchFocus: Equatable, Sendable {
    let conversationID: String
    let messageID: UUID
}

struct WorkspaceSearchIndex: Sendable {
    static let maximumResultCount = 100
    static let maximumHotMessageCount = 2_000
    static let maximumIndexedTokensPerMessage = 48
    static let maximumIndexedPrefixLength = 16
    static let maximumPostingCount =
        maximumHotMessageCount
        * maximumIndexedTokensPerMessage
        * maximumIndexedPrefixLength
    private static let maximumIndexedTextCharacters = 4_096
    private static let maximumResultDetailCharacters = 2_048
    private static let maximumQueryTokens = 8

    private struct Document: Sendable {
        let result: WorkspaceSearchResult
        let normalizedTitle: String
        let normalizedDetail: String
        let indexedTokens: [String]
        let generation: UInt64
    }

    private struct RankedDocument {
        let document: Document
        let score: Int
    }

    private struct RetentionEntry: Sendable {
        let documentID: String
        let timestamp: Date
        let generation: UInt64
    }

    private let capacity: Int
    private var documentsByID: [String: Document] = [:]
    private var documentIDsByPrefix: [String: Set<String>] = [:]
    private var retentionHeap: [RetentionEntry] = []
    private var nextGeneration: UInt64 = 0

    init(
        conversations: [Conversation] = [],
        capacity: Int = maximumHotMessageCount
    ) {
        self.capacity = max(1, min(capacity, Self.maximumHotMessageCount))
        for conversation in conversations {
            merge(messages: conversation.messages, conversation: conversation)
        }
    }

    mutating func reset(conversations: [Conversation]) {
        self = WorkspaceSearchIndex(
            conversations: conversations,
            capacity: capacity
        )
    }

    mutating func merge(messages: [Message], conversation: Conversation) {
        for message in messages {
            upsert(message: message, conversation: conversation)
        }
        compactRetentionHeapIfNeeded()
    }

    var metrics: WorkspaceSearchIndexMetrics {
        WorkspaceSearchIndexMetrics(
            documentCount: documentsByID.count,
            prefixCount: documentIDsByPrefix.count,
            postingCount: documentIDsByPrefix.values.reduce(into: 0) {
                $0 += $1.count
            },
            retentionEntryCount: retentionHeap.count
        )
    }

    func searchMessages(
        query: String,
        limit: Int = maximumResultCount
    ) -> [WorkspaceSearchResult] {
        let normalizedQuery = Self.normalized(query)
        guard !normalizedQuery.isEmpty, limit > 0 else {
            return []
        }

        let queryTokens = Set(
            Self.tokens(in: normalizedQuery).prefix(Self.maximumQueryTokens)
        )
        let candidateIDs: Set<String>
        if queryTokens.isEmpty {
            candidateIDs = Set(documentsByID.keys)
        } else {
            var intersection: Set<String>?
            for queryToken in queryTokens {
                let lookupPrefix = String(
                    queryToken.prefix(Self.maximumIndexedPrefixLength)
                )
                let tokenMatches = documentIDsByPrefix[lookupPrefix] ?? []
                intersection = intersection.map { $0.intersection(tokenMatches) }
                    ?? tokenMatches
                if intersection?.isEmpty == true {
                    return []
                }
            }
            candidateIDs = intersection ?? []
        }

        let boundedLimit = min(limit, Self.maximumResultCount)
        var ranked: [RankedDocument] = []
        ranked.reserveCapacity(boundedLimit)
        for documentID in candidateIDs {
            guard let document = documentsByID[documentID],
                  document.normalizedTitle.contains(normalizedQuery)
                    || document.normalizedDetail.contains(normalizedQuery)
                    || queryTokens.count > 1
            else {
                continue
            }
            let candidate = RankedDocument(
                document: document,
                score: Self.score(document, query: normalizedQuery)
            )
            let insertionIndex = Self.insertionIndex(
                for: candidate,
                in: ranked
            )
            guard insertionIndex < boundedLimit else {
                continue
            }
            ranked.insert(candidate, at: insertionIndex)
            if ranked.count > boundedLimit {
                ranked.removeLast()
            }
        }
        return ranked.map(\.document.result)
    }

    static func searchEntities(
        query: String,
        users: [WorkspaceUser],
        conversations: [Conversation],
        limit: Int = 20
    ) -> [WorkspaceSearchResult] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty, limit > 0 else {
            return []
        }

        let people = users.compactMap { user -> (Int, WorkspaceSearchResult)? in
            let text = normalized(
                "\(user.displayName) \(user.profileTitle ?? "") \(user.status)"
            )
            guard text.contains(normalizedQuery) else {
                return nil
            }
            return (
                entityScore(name: user.displayName, query: normalizedQuery),
                WorkspaceSearchResult(
                    id: "person-\(user.id)",
                    kind: .person,
                    source: .local,
                    title: user.displayName,
                    detail: user.status,
                    conversationID: nil,
                    userID: user.id,
                    messageID: nil,
                    timestamp: nil,
                    permalink: nil
                )
            )
        }

        let channels = conversations.compactMap {
            conversation -> (Int, WorkspaceSearchResult)? in
            let text = normalized("\(conversation.title) \(conversation.subtitle ?? "")")
            guard text.contains(normalizedQuery) else {
                return nil
            }
            return (
                entityScore(name: conversation.title, query: normalizedQuery),
                WorkspaceSearchResult(
                    id: "conversation-\(conversation.id)",
                    kind: .channel,
                    source: .local,
                    title: Self.conversationLabel(conversation),
                    detail: conversation.subtitle ?? conversation.kind.searchTitle,
                    conversationID: conversation.id,
                    userID: conversation.participantUserID,
                    messageID: nil,
                    timestamp: conversation.latestActivity,
                    permalink: nil
                )
            )
        }

        return (people + channels)
            .sorted {
                if $0.0 != $1.0 {
                    return $0.0 > $1.0
                }
                let titleOrder = $0.1.title.localizedCaseInsensitiveCompare($1.1.title)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                return $0.1.id < $1.1.id
            }
            .prefix(min(limit, maximumResultCount))
            .map(\.1)
    }

    static func boundedMerge(
        entities: [WorkspaceSearchResult],
        content: [WorkspaceSearchResult],
        limit: Int = maximumResultCount
    ) -> [WorkspaceSearchResult] {
        let boundedLimit = min(max(0, limit), maximumResultCount)
        guard boundedLimit > 0 else {
            return []
        }
        var seen = Set<String>()
        return (entities + content)
            .filter { seen.insert($0.id).inserted }
            .prefix(boundedLimit)
            .map { $0 }
    }

    private mutating func removeFromPostings(
        _ document: Document,
        documentID: String
    ) {
        for token in document.indexedTokens {
            for prefix in Self.indexedPrefixes(for: token) {
                documentIDsByPrefix[prefix]?.remove(documentID)
                if documentIDsByPrefix[prefix]?.isEmpty == true {
                    documentIDsByPrefix.removeValue(forKey: prefix)
                }
            }
        }
    }

    private mutating func upsert(
        message: Message,
        conversation: Conversation
    ) {
        let id = Self.documentID(
            message: message,
            conversationID: conversation.id
        )
        if let existing = documentsByID[id] {
            removeFromPostings(existing, documentID: id)
        }

        nextGeneration &+= 1
        let title = Self.clipped(
            "\(message.author) in \(Self.conversationLabel(conversation))",
            maximumCharacters: Self.maximumResultDetailCharacters
        )
        let fullDetail = message.copyText
        let detail = Self.clipped(
            fullDetail,
            maximumCharacters: Self.maximumResultDetailCharacters
        )
        let normalizedTitle = Self.normalized(title)
        let normalizedDetail = Self.normalized(
            Self.clipped(
                fullDetail,
                maximumCharacters: Self.maximumIndexedTextCharacters
            )
        )
        let indexedTokens = Self.indexedTokens(
            title: normalizedTitle,
            detail: normalizedDetail
        )
        let document = Document(
            result: WorkspaceSearchResult(
                id: id,
                kind: .message,
                source: .local,
                title: title,
                detail: detail,
                conversationID: conversation.id,
                userID: message.authorUserID,
                messageID: message.id,
                timestamp: message.timestamp,
                permalink: nil
            ),
            normalizedTitle: normalizedTitle,
            normalizedDetail: normalizedDetail,
            indexedTokens: indexedTokens,
            generation: nextGeneration
        )
        documentsByID[id] = document
        for token in indexedTokens {
            for prefix in Self.indexedPrefixes(for: token) {
                documentIDsByPrefix[prefix, default: []].insert(id)
            }
        }
        pushRetentionEntry(
            RetentionEntry(
                documentID: id,
                timestamp: message.timestamp,
                generation: nextGeneration
            )
        )
        trimToCapacity()
    }

    private mutating func trimToCapacity() {
        while documentsByID.count > capacity,
              let oldest = popOldestCurrentEntry(),
              let document = documentsByID.removeValue(
                  forKey: oldest.documentID
              )
        {
            removeFromPostings(document, documentID: oldest.documentID)
        }
    }

    private mutating func pushRetentionEntry(_ entry: RetentionEntry) {
        retentionHeap.append(entry)
        var index = retentionHeap.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard Self.isOlder(retentionHeap[index], than: retentionHeap[parent])
            else {
                break
            }
            retentionHeap.swapAt(index, parent)
            index = parent
        }
    }

    private mutating func popOldestCurrentEntry() -> RetentionEntry? {
        while let candidate = popRetentionEntry() {
            if documentsByID[candidate.documentID]?.generation == candidate.generation {
                return candidate
            }
        }
        return nil
    }

    private mutating func popRetentionEntry() -> RetentionEntry? {
        guard !retentionHeap.isEmpty else {
            return nil
        }
        if retentionHeap.count == 1 {
            return retentionHeap.removeLast()
        }
        let oldest = retentionHeap[0]
        retentionHeap[0] = retentionHeap.removeLast()
        var index = 0
        while true {
            let left = index * 2 + 1
            guard left < retentionHeap.count else {
                break
            }
            let right = left + 1
            let child = right < retentionHeap.count
                && Self.isOlder(retentionHeap[right], than: retentionHeap[left])
                ? right : left
            guard Self.isOlder(retentionHeap[child], than: retentionHeap[index])
            else {
                break
            }
            retentionHeap.swapAt(index, child)
            index = child
        }
        return oldest
    }

    private mutating func compactRetentionHeapIfNeeded() {
        guard retentionHeap.count > capacity * 2 else {
            return
        }
        retentionHeap = documentsByID.map {
            RetentionEntry(
                documentID: $0.key,
                timestamp: $0.value.result.timestamp ?? .distantPast,
                generation: $0.value.generation
            )
        }
        if retentionHeap.count > 1 {
            for index in stride(
                from: retentionHeap.count / 2 - 1,
                through: 0,
                by: -1
            ) {
                heapifyDown(from: index)
            }
        }
    }

    private mutating func heapifyDown(from startIndex: Int) {
        var index = startIndex
        while true {
            let left = index * 2 + 1
            guard left < retentionHeap.count else {
                return
            }
            let right = left + 1
            let child = right < retentionHeap.count
                && Self.isOlder(retentionHeap[right], than: retentionHeap[left])
                ? right : left
            guard Self.isOlder(retentionHeap[child], than: retentionHeap[index])
            else {
                return
            }
            retentionHeap.swapAt(index, child)
            index = child
        }
    }

    private static func isOlder(
        _ lhs: RetentionEntry,
        than rhs: RetentionEntry
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.documentID != rhs.documentID {
            return lhs.documentID < rhs.documentID
        }
        return lhs.generation < rhs.generation
    }

    private static func documentID(message: Message, conversationID: String) -> String {
        if let remoteID = message.remoteID {
            return "local-message-\(conversationID)-\(remoteID)"
        }
        return "local-message-\(conversationID)-\(message.id.uuidString)"
    }

    private static func score(_ document: Document, query: String) -> Int {
        let titleMatches = document.normalizedTitle.contains(query)
        let detailMatches = document.normalizedDetail.contains(query)
        var score = titleMatches || detailMatches ? 20 : 0
        if titleMatches {
            score += 8
        }
        if document.normalizedDetail.hasPrefix(query) {
            score += 4
        }
        return score
    }

    private static func insertionIndex(
        for candidate: RankedDocument,
        in ranked: [RankedDocument]
    ) -> Int {
        var lowerBound = 0
        var upperBound = ranked.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if ranksBefore(candidate, ranked[middle]) {
                upperBound = middle
            } else {
                lowerBound = middle + 1
            }
        }
        return lowerBound
    }

    private static func ranksBefore(
        _ lhs: RankedDocument,
        _ rhs: RankedDocument
    ) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        let lhsTimestamp = lhs.document.result.timestamp ?? .distantPast
        let rhsTimestamp = rhs.document.result.timestamp ?? .distantPast
        if lhsTimestamp != rhsTimestamp {
            return lhsTimestamp > rhsTimestamp
        }
        return lhs.document.result.id < rhs.document.result.id
    }

    private static func entityScore(name: String, query: String) -> Int {
        let normalizedName = normalized(name)
        if normalizedName == query {
            return 30
        }
        if normalizedName.hasPrefix(query) {
            return 20
        }
        return 10
    }

    private static func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func indexedTokens(
        title: String,
        detail: String
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in tokens(in: title) + tokens(in: detail) {
            guard seen.insert(token).inserted else {
                continue
            }
            result.append(token)
            if result.count == maximumIndexedTokensPerMessage {
                break
            }
        }
        return result
    }

    private static func indexedPrefixes(for token: String) -> [String] {
        let length = min(token.count, maximumIndexedPrefixLength)
        return (1 ... length).map { String(token.prefix($0)) }
    }

    private static func clipped(
        _ text: String,
        maximumCharacters: Int
    ) -> String {
        guard text.count > maximumCharacters else {
            return text
        }
        return String(text.prefix(maximumCharacters))
    }

    static func conversationLabel(_ conversation: Conversation) -> String {
        switch conversation.kind {
        case .channel:
            "#\(conversation.title)"
        case .directMessage, .groupDirectMessage:
            conversation.title
        }
    }
}

private extension ConversationKind {
    var searchTitle: String {
        switch self {
        case .channel:
            "Channel"
        case .directMessage:
            "Direct message"
        case .groupDirectMessage:
            "Group direct message"
        }
    }
}
