import Foundation

/// Parses Slack mrkdwn (not full Markdown) into styled rich-text runs.
///
/// Handles:
/// - `*bold*`, `_italic_`, `~strike~`, `` `code` ``
/// - Nested emphasis (`*_bold italic_*`)
/// - Entities: `<url|label>`, `<@U…>`, `<#C…>`, `<!date^…|fallback>`, etc.
enum SlackMrkdwn {
    static func runs(
        in text: String,
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) -> [MessageRichText.Run] {
        parse(
            text[text.startIndex...],
            style: .init(),
            context: context,
            messageEmoji: messageEmoji
        )
    }

    /// Plain display string with markers stripped and entities resolved.
    static func plainText(
        in text: String,
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) -> String {
        runs(in: text, context: context, messageEmoji: messageEmoji)
            .map(\.displayText)
            .joined()
    }

    private static func parse(
        _ slice: Substring,
        style: MessageRichText.Style,
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) -> [MessageRichText.Run] {
        var runs: [MessageRichText.Run] = []
        var cursor = slice.startIndex
        var plainStart = cursor

        func flushPlain(upTo end: String.Index) {
            guard plainStart < end else { return }
            let raw = String(slice[plainStart ..< end])
            let display = SlackEmoji.replacingUnicodeShortcodes(
                in: SlackMessageFormatting.decodeEntities(raw),
                messageEmoji: messageEmoji
            )
            guard !display.isEmpty || !raw.isEmpty else { return }
            runs.append(
                MessageRichText.Run(
                    content: .text(raw: raw, display: display),
                    style: style
                )
            )
        }

        while cursor < slice.endIndex {
            let ch = slice[cursor]

            if ch == "<",
               let close = slice[cursor...].firstIndex(of: ">")
            {
                flushPlain(upTo: cursor)
                let tokenStart = slice.index(after: cursor)
                let token = String(slice[tokenStart ..< close])
                let original = String(slice[cursor ... close])
                runs.append(
                    contentsOf: entityRuns(
                        token: token,
                        original: original,
                        style: style,
                        context: context,
                        messageEmoji: messageEmoji
                    )
                )
                cursor = slice.index(after: close)
                plainStart = cursor
                continue
            }

            if ch == "`",
               let close = findClosingDelimiter(slice, opening: cursor, delimiter: "`")
            {
                flushPlain(upTo: cursor)
                let innerStart = slice.index(after: cursor)
                let raw = String(slice[innerStart ..< close])
                let display = SlackEmoji.replacingUnicodeShortcodes(
                    in: SlackMessageFormatting.decodeEntities(raw),
                    messageEmoji: messageEmoji
                )
                var codeStyle = style
                codeStyle.isCode = true
                runs.append(
                    MessageRichText.Run(
                        content: .text(raw: raw, display: display),
                        style: codeStyle
                    )
                )
                cursor = slice.index(after: close)
                plainStart = cursor
                continue
            }

            if let delimiter = EmphasisDelimiter(rawValue: ch),
               !style.isCode,
               canOpenEmphasis(slice, at: cursor, delimiter: delimiter),
               let close = findClosingEmphasis(slice, opening: cursor, delimiter: delimiter)
            {
                flushPlain(upTo: cursor)
                let innerStart = slice.index(after: cursor)
                var nested = style
                switch delimiter {
                case .bold:
                    nested.isBold = true
                case .italic:
                    nested.isItalic = true
                case .strike:
                    nested.isStruck = true
                }
                runs.append(
                    contentsOf: parse(
                        slice[innerStart ..< close],
                        style: nested,
                        context: context,
                        messageEmoji: messageEmoji
                    )
                )
                cursor = slice.index(after: close)
                plainStart = cursor
                continue
            }

            cursor = slice.index(after: cursor)
        }

        flushPlain(upTo: slice.endIndex)
        return runs
    }

    private static func entityRuns(
        token: String,
        original: String,
        style: MessageRichText.Style,
        context: SlackMessageFormatting.Context,
        messageEmoji: [String: String]
    ) -> [MessageRichText.Run] {
        let parts = token.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        if let target = parts.first.map(String.init),
           let url = URL(string: SlackMessageFormatting.decodeEntities(target)),
           url.scheme != nil
        {
            let labelRaw = parts.count == 2 && !parts[1].isEmpty
                ? String(parts[1])
                : target
            // Labels can themselves contain emphasis (rare) — keep plain for stability.
            let label = SlackEmoji.replacingUnicodeShortcodes(
                in: SlackMessageFormatting.render(in: labelRaw, context: context),
                messageEmoji: messageEmoji
            )
            return [
                MessageRichText.Run(
                    content: .link(url: url.absoluteString, label: label),
                    style: style
                )
            ]
        }

        // Mentions, channels, dates, broadcasts → resolved plain text, keep style.
        let rendered = SlackMessageFormatting.render(in: original, context: context)
        let display = SlackEmoji.replacingUnicodeShortcodes(
            in: rendered,
            messageEmoji: messageEmoji
        )
        return [
            MessageRichText.Run(
                content: .text(raw: original, display: display),
                style: style
            )
        ]
    }

    private enum EmphasisDelimiter: Character {
        case bold = "*"
        case italic = "_"
        case strike = "~"
    }

    /// Opening marker: not followed by whitespace / end, and not already the same open style
    /// consumed by the outer parse (outer handles nesting via recursive style flags).
    private static func canOpenEmphasis(
        _ slice: Substring,
        at index: String.Index,
        delimiter: EmphasisDelimiter
    ) -> Bool {
        let next = slice.index(after: index)
        guard next < slice.endIndex else { return false }
        let nextChar = slice[next]
        // Slack does not bold empty or whitespace-leading spans.
        if nextChar == delimiter.rawValue { return false }
        if nextChar.isWhitespace { return false }
        return true
    }

    /// Left-to-right first valid closer: non-whitespace before `*`, not empty span.
    private static func findClosingEmphasis(
        _ slice: Substring,
        opening: String.Index,
        delimiter: EmphasisDelimiter
    ) -> String.Index? {
        var index = slice.index(after: opening)
        while index < slice.endIndex {
            let ch = slice[index]
            if ch == "<",
               let close = slice[index...].firstIndex(of: ">")
            {
                index = slice.index(after: close)
                continue
            }
            if ch == "`",
               let close = findClosingDelimiter(slice, opening: index, delimiter: "`")
            {
                index = slice.index(after: close)
                continue
            }
            if ch == delimiter.rawValue {
                let prev = slice.index(before: index)
                if prev > opening, !slice[prev].isWhitespace {
                    return index
                }
            }
            index = slice.index(after: index)
        }
        return nil
    }

    private static func findClosingDelimiter(
        _ slice: Substring,
        opening: String.Index,
        delimiter: Character
    ) -> String.Index? {
        var index = slice.index(after: opening)
        while index < slice.endIndex {
            if slice[index] == delimiter {
                return index
            }
            index = slice.index(after: index)
        }
        return nil
    }
}
