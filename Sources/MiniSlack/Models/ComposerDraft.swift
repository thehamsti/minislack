import Foundation

enum ComposerTagKind: Hashable {
    case user
    case channel
    case broadcast
}

struct ComposerTag: Hashable {
    let kind: ComposerTagKind
    let entityID: String
    let displayText: String
    var range: NSRange

    var slackMarkup: String {
        switch kind {
        case .user:
            "<@\(entityID)>"
        case .channel:
            "<#\(entityID)>"
        case .broadcast:
            "<!\(entityID)>"
        }
    }
}

struct ComposerQuery: Equatable, Hashable {
    enum Kind: Hashable {
        case user
        case channel
    }

    let kind: Kind
    let term: String
    let range: NSRange
}

struct ComposerDraft: Equatable {
    var text: String
    private(set) var tags: [ComposerTag]

    init(text: String = "", tags: [ComposerTag] = []) {
        self.text = text
        self.tags = tags.sorted { $0.range.location < $1.range.location }
    }

    var isEmpty: Bool {
        text.isEmpty
    }

    var slackText: String {
        let source = text as NSString
        let validTags = tags.filter {
            NSMaxRange($0.range) <= source.length
                && source.substring(with: $0.range) == $0.displayText
        }
        var result = ""
        result.reserveCapacity(text.count)
        var cursor = 0

        for tag in validTags.sorted(by: { $0.range.location < $1.range.location }) {
            let plainRange = NSRange(
                location: cursor,
                length: tag.range.location - cursor
            )
            result += Self.escape(source.substring(with: plainRange))
            result += tag.slackMarkup
            cursor = NSMaxRange(tag.range)
        }

        result += Self.escape(
            source.substring(
                with: NSRange(location: cursor, length: source.length - cursor)
            )
        )
        return result
    }

    mutating func applyTextChange(
        _ newText: String,
        replacing range: NSRange,
        replacementLength: Int
    ) {
        let oldLength = (text as NSString).length
        let newLength = (newText as NSString).length
        guard range.location != NSNotFound,
              NSMaxRange(range) <= oldLength,
              replacementLength >= 0,
              oldLength - range.length + replacementLength == newLength
        else {
            self = ComposerDraft(text: newText)
            return
        }
        applyEdit(range: range, replacementLength: replacementLength)
        text = newText
    }

    mutating func replaceCharacters(in range: NSRange, with replacement: String) {
        let mutableText = NSMutableString(string: text)
        guard range.location != NSNotFound,
              NSMaxRange(range) <= mutableText.length
        else {
            return
        }
        mutableText.replaceCharacters(in: range, with: replacement)
        applyEdit(
            range: range,
            replacementLength: (replacement as NSString).length
        )
        text = mutableText as String
    }

    @discardableResult
    mutating func insert(
        suggestion: ComposerSuggestion,
        replacing query: ComposerQuery
    ) -> NSRange {
        let mutableText = NSMutableString(string: text)
        let shouldAppendSpace = NSMaxRange(query.range) == mutableText.length
        let replacement = suggestion.displayText + (shouldAppendSpace ? " " : "")
        mutableText.replaceCharacters(in: query.range, with: replacement)
        applyEdit(
            range: query.range,
            replacementLength: (replacement as NSString).length
        )
        text = mutableText as String
        tags.append(
            ComposerTag(
                kind: suggestion.tagKind,
                entityID: suggestion.entityID,
                displayText: suggestion.displayText,
                range: NSRange(
                    location: query.range.location,
                    length: (suggestion.displayText as NSString).length
                )
            )
        )
        tags.sort { $0.range.location < $1.range.location }
        return NSRange(
            location: query.range.location + (replacement as NSString).length,
            length: 0
        )
    }

    func query(at selection: NSRange) -> ComposerQuery? {
        let source = text as NSString
        guard selection.length == 0, selection.location <= source.length else {
            return nil
        }
        if tags.contains(where: {
            selection.location > $0.range.location
                && selection.location <= NSMaxRange($0.range)
        }) {
            return nil
        }

        var location = selection.location
        while location > 0 {
            let scalar = source.character(at: location - 1)
            if scalar == 64 || scalar == 35 {
                let triggerLocation = location - 1
                guard isTriggerBoundary(source, location: triggerLocation) else {
                    return nil
                }
                let kind: ComposerQuery.Kind = scalar == 64 ? .user : .channel
                var queryEnd = selection.location
                while queryEnd < source.length,
                      isQueryCharacter(source.character(at: queryEnd))
                {
                    queryEnd += 1
                }
                return ComposerQuery(
                    kind: kind,
                    term: source.substring(
                        with: NSRange(
                            location: location,
                            length: queryEnd - location
                        )
                    ),
                    range: NSRange(
                        location: triggerLocation,
                        length: queryEnd - triggerLocation
                    )
                )
            }
            guard isQueryCharacter(scalar) else {
                return nil
            }
            location -= 1
        }
        return nil
    }

    private mutating func applyEdit(range: NSRange, replacementLength: Int) {
        let delta = replacementLength - range.length
        tags = tags.compactMap { tag in
            var tag = tag
            if range.length == 0 {
                if range.location > tag.range.location,
                   range.location < NSMaxRange(tag.range)
                {
                    return nil
                }
                if range.location <= tag.range.location {
                    tag.range.location += delta
                }
                return tag
            }

            if NSIntersectionRange(range, tag.range).length > 0 {
                return nil
            }
            if NSMaxRange(range) <= tag.range.location {
                tag.range.location += delta
            }
            return tag
        }
    }

    private func isTriggerBoundary(_ source: NSString, location: Int) -> Bool {
        guard location > 0 else {
            return true
        }
        let scalar = source.character(at: location - 1)
        guard let unicodeScalar = UnicodeScalar(scalar) else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(unicodeScalar)
            || CharacterSet.punctuationCharacters.contains(unicodeScalar)
    }

    private func isQueryCharacter(_ scalar: unichar) -> Bool {
        guard let unicodeScalar = UnicodeScalar(scalar) else {
            return true
        }
        return CharacterSet.alphanumerics.contains(unicodeScalar)
            || CharacterSet(charactersIn: "-_.'").contains(unicodeScalar)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct ComposerSuggestion: Identifiable, Hashable {
    let tagKind: ComposerTagKind
    let entityID: String
    let displayText: String
    let title: String
    let subtitle: String?
    let avatarURL: URL?
    let isActive: Bool

    var id: String {
        "\(tagKind)-\(entityID)"
    }
}

struct ComposerSuggestionIndex {
    private struct IndexedSuggestion {
        let suggestion: ComposerSuggestion
        let searchKey: String
    }

    private let users: [IndexedSuggestion]
    private let channels: [IndexedSuggestion]

    init(users: [WorkspaceUser], conversations: [Conversation]) {
        self.users = users.map {
            IndexedSuggestion(
                suggestion: ComposerSuggestion(
                    tagKind: .user,
                    entityID: $0.id,
                    displayText: "@\($0.displayName)",
                    title: $0.displayName,
                    subtitle: $0.status.isEmpty ? nil : $0.status,
                    avatarURL: $0.avatarURL,
                    isActive: $0.isActive
                ),
                searchKey: Self.normalized($0.displayName)
            )
        }
        channels = conversations
            .filter { $0.kind == .channel }
            .map {
                IndexedSuggestion(
                    suggestion: ComposerSuggestion(
                        tagKind: .channel,
                        entityID: $0.id,
                        displayText: "#\($0.title)",
                        title: $0.title,
                        subtitle: $0.subtitle,
                        avatarURL: nil,
                        isActive: false
                    ),
                    searchKey: Self.normalized($0.title)
                )
            }
    }

    func matches(
        query: ComposerQuery,
        allowsBroadcasts: Bool,
        limit: Int = 8
    ) -> [ComposerSuggestion] {
        switch query.kind {
        case .user:
            userMatches(
                term: query.term,
                allowsBroadcasts: allowsBroadcasts,
                limit: limit
            )
        case .channel:
            Self.rankedMatches(
                term: query.term,
                candidates: channels,
                limit: limit
            )
        }
    }

    private func userMatches(
        term: String,
        allowsBroadcasts: Bool,
        limit: Int
    ) -> [ComposerSuggestion] {
        var candidates: [IndexedSuggestion] = []
        if allowsBroadcasts, !term.isEmpty {
            candidates = ["here", "channel", "everyone"].map { name in
                IndexedSuggestion(
                    suggestion: ComposerSuggestion(
                        tagKind: .broadcast,
                        entityID: name,
                        displayText: "@\(name)",
                        title: "@\(name)",
                        subtitle: "Notify a wider audience",
                        avatarURL: nil,
                        isActive: false
                    ),
                    searchKey: name
                )
            }
        }
        candidates.append(contentsOf: users)
        return Self.rankedMatches(
            term: term,
            candidates: candidates,
            limit: limit
        )
    }

    private static func rankedMatches(
        term: String,
        candidates: [IndexedSuggestion],
        limit: Int
    ) -> [ComposerSuggestion] {
        guard limit > 0 else {
            return []
        }
        guard !term.isEmpty else {
            return candidates.prefix(limit).map(\.suggestion)
        }

        let searchTerm = normalized(term)
        var prefixMatches: [ComposerSuggestion] = []
        var containsMatches: [ComposerSuggestion] = []
        for candidate in candidates {
            if candidate.searchKey.hasPrefix(searchTerm) {
                prefixMatches.append(candidate.suggestion)
                if prefixMatches.count == limit {
                    return prefixMatches
                }
            } else if candidate.searchKey.contains(searchTerm),
                      containsMatches.count < limit
            {
                containsMatches.append(candidate.suggestion)
            }
        }
        return Array((prefixMatches + containsMatches).prefix(limit))
    }

    private static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}
