import Foundation

enum ComposerTagKind: Hashable, Sendable {
    case user
    case channel
    case broadcast
    case emoji
}

struct ComposerTag: Hashable, Sendable {
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
        case .emoji:
            ":\(entityID):"
        }
    }
}

struct ComposerQuery: Equatable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case user
        case channel
        case emoji
    }

    let kind: Kind
    let term: String
    let range: NSRange
}

struct ComposerDraft: Equatable, Sendable {
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
    mutating func applyFormatting(
        _ formatting: ComposerFormatting,
        to selection: NSRange
    ) -> NSRange {
        let source = text as NSString
        guard selection.location != NSNotFound,
              NSMaxRange(selection) <= source.length
        else {
            return selection
        }
        let delimiters = formatting.delimiters
        replaceCharacters(
            in: NSRange(location: NSMaxRange(selection), length: 0),
            with: delimiters.suffix
        )
        replaceCharacters(
            in: NSRange(location: selection.location, length: 0),
            with: delimiters.prefix
        )
        if selection.length == 0 {
            return NSRange(
                location: selection.location + (delimiters.prefix as NSString).length,
                length: 0
            )
        }
        return NSRange(
            location: selection.location,
            length: selection.length
                + (delimiters.prefix as NSString).length
                + (delimiters.suffix as NSString).length
        )
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
            if scalar == 64 || scalar == 35 || scalar == 58 {
                let triggerLocation = location - 1
                guard isTriggerBoundary(
                    source,
                    location: triggerLocation,
                    trigger: scalar
                ) else {
                    return nil
                }
                let kind: ComposerQuery.Kind
                switch scalar {
                case 64:
                    kind = .user
                case 35:
                    kind = .channel
                default:
                    kind = .emoji
                }
                var queryEnd = selection.location
                while queryEnd < source.length,
                      isQueryCharacter(source.character(at: queryEnd))
                {
                    queryEnd += 1
                }
                let replacementEnd = kind == .emoji
                    && queryEnd < source.length
                    && source.character(at: queryEnd) == 58
                    ? queryEnd + 1
                    : queryEnd
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
                        length: replacementEnd - triggerLocation
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

    private func isTriggerBoundary(
        _ source: NSString,
        location: Int,
        trigger: unichar
    ) -> Bool {
        guard location > 0 else {
            return true
        }
        let scalar = source.character(at: location - 1)
        if trigger == 58, scalar == 58 {
            return false
        }
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
            || CharacterSet(charactersIn: "+-_.'").contains(unicodeScalar)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

enum ComposerFormatting: String, CaseIterable, Identifiable, Sendable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case codeBlock

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .bold:
            "Bold"
        case .italic:
            "Italic"
        case .strikethrough:
            "Strikethrough"
        case .inlineCode:
            "Inline code"
        case .codeBlock:
            "Code block"
        }
    }

    var systemImage: String {
        switch self {
        case .bold:
            "bold"
        case .italic:
            "italic"
        case .strikethrough:
            "strikethrough"
        case .inlineCode:
            "chevron.left.forwardslash.chevron.right"
        case .codeBlock:
            "text.rectangle"
        }
    }

    fileprivate var delimiters: (prefix: String, suffix: String) {
        switch self {
        case .bold:
            ("*", "*")
        case .italic:
            ("_", "_")
        case .strikethrough:
            ("~", "~")
        case .inlineCode:
            ("`", "`")
        case .codeBlock:
            ("```\n", "\n```")
        }
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
        case .emoji:
            Self.emojiMatches(query: query, customEmojiURLs: [:], limit: limit)
        }
    }

    static func emojiMatches(
        query: ComposerQuery,
        customEmojiURLs: [String: URL],
        limit: Int = 8
    ) -> [ComposerSuggestion] {
        guard query.kind == .emoji, limit > 0 else {
            return []
        }

        let names: [(name: String, url: URL?)]
        if query.term.isEmpty {
            names = commonEmojiShortcodes.prefix(limit).map { ($0, nil) }
        } else {
            names = rankedEmojiNames(
                term: query.term,
                customEmojiURLs: customEmojiURLs,
                limit: limit
            )
        }

        return names.map { name, url in
            ComposerSuggestion(
                tagKind: .emoji,
                entityID: name,
                displayText: ":\(name):",
                title: ":\(name):",
                subtitle: url == nil ? "Emoji" : "Workspace emoji",
                avatarURL: url,
                isActive: false
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

    private static func rankedEmojiNames(
        term: String,
        customEmojiURLs: [String: URL],
        limit: Int
    ) -> [(name: String, url: URL?)] {
        let searchTerm = term.lowercased()
        var exactMatch: (name: String, url: URL?)?
        var prefixMatches: [(name: String, url: URL?)] = []
        var containsMatches: [(name: String, url: URL?)] = []

        func collect(name: String, searchKey: String, url: URL?) {
            if searchKey == searchTerm {
                exactMatch = (name, url)
            } else if searchKey.hasPrefix(searchTerm) {
                if prefixMatches.count < limit {
                    prefixMatches.append((name, url))
                }
            } else if searchKey.contains(searchTerm),
                      containsMatches.count < limit
            {
                containsMatches.append((name, url))
            }
        }

        let customNames = customEmojiURLs.keys.sorted()
        for name in customNames {
            collect(
                name: name,
                searchKey: name.lowercased(),
                url: customEmojiURLs[name]
            )
        }
        for name in SlackEmojiCatalog.shortcodes where customEmojiURLs[name] == nil {
            collect(name: name, searchKey: name, url: nil)
        }

        return Array(
            ([exactMatch].compactMap(\.self) + prefixMatches + containsMatches)
                .prefix(limit)
        )
    }

    private static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    private static let commonEmojiShortcodes = [
        "thumbsup",
        "heart",
        "joy",
        "tada",
        "fire",
        "eyes",
        "white_check_mark",
        "rocket",
    ]
}
