import Foundation

enum SlackMessageFormatting {
    struct Context: Sendable {
        let userNames: [String: String]
        let channelNames: [String: String]

        static let empty = Context(userNames: [:], channelNames: [:])
    }

    static func render(in text: String, context: Context) -> String {
        render(
            in: text,
            userNames: context.userNames,
            channelNames: context.channelNames
        )
    }

    static func render(
        in text: String,
        userNames: [String: String],
        channelNames: [String: String]
    ) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex

        while let open = text[cursor...].firstIndex(of: "<"),
              let close = text[open...].firstIndex(of: ">")
        {
            result += decodeEntities(String(text[cursor ..< open]))
            let tokenStart = text.index(after: open)
            let token = String(text[tokenStart ..< close])
            let original = String(text[open ... close])
            result += replacement(
                for: token,
                original: original,
                userNames: userNames,
                channelNames: channelNames
            )
            cursor = text.index(after: close)
        }

        result += decodeEntities(String(text[cursor...]))
        return result
    }

    private static func replacement(
        for token: String,
        original: String,
        userNames: [String: String],
        channelNames: [String: String]
    ) -> String {
        if token.hasPrefix("@") {
            let components = String(token.dropFirst()).split(
                separator: "|",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard let id = components.first.map(String.init) else {
                return original
            }
            let fallback = components.count == 2 ? String(components[1]) : nil
            return userNames[id].map { "@\($0)" }
                ?? fallback.map(normalizedMention)
                ?? original
        }

        if token.hasPrefix("#") {
            let components = String(token.dropFirst()).split(
                separator: "|",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard let id = components.first.map(String.init) else {
                return original
            }
            let fallback = components.count == 2 ? String(components[1]) : nil
            return channelNames[id].map { "#\($0)" }
                ?? fallback.map(normalizedChannel)
                ?? original
        }

        if token.hasPrefix("!date^") {
            return token.split(
                separator: "|",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            .dropFirst()
            .first
            .map { decodeEntities(String($0)) }
                ?? original
        }

        if token.hasPrefix("!subteam^") {
            return token.split(
                separator: "|",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            .dropFirst()
            .first
            .map { normalizedMention(String($0)) }
                ?? original
        }

        if token.hasPrefix("!") {
            let broadcast = String(token.dropFirst()).split(separator: "^", maxSplits: 1)[0]
            if ["here", "channel", "everyone"].contains(broadcast) {
                return "@\(broadcast)"
            }
            return original
        }

        let components = token.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let target = components.first.map(String.init),
              URL(string: decodeEntities(target)) != nil
        else {
            return original
        }
        if components.count == 2, !components[1].isEmpty {
            return decodeEntities(String(components[1]))
        }
        return decodeEntities(target)
    }

    private static func normalizedMention(_ value: String) -> String {
        value.hasPrefix("@") ? value : "@\(value)"
    }

    private static func normalizedChannel(_ value: String) -> String {
        value.hasPrefix("#") ? value : "#\(value)"
    }

    static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
