import Foundation

enum SlackEmoji {
    private static let shortcodePattern = try! NSRegularExpression(
        pattern: #":([+\-\w]+):(?::?skin-tone-([2-6]):)?"#
    )

    static func replacingUnicodeShortcodes(
        in text: String,
        messageEmoji: [String: String] = [:]
    ) -> String {
        let mutableText = NSMutableString(string: text)
        let range = NSRange(location: 0, length: mutableText.length)
        for match in shortcodePattern.matches(in: text, range: range).reversed() {
            guard let nameRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let name = String(text[nameRange])
            let skinTone = Range(match.range(at: 2), in: text)
                .flatMap { Int(text[$0]) }
            let compoundName = skinTone.map { "\(name)::skin-tone-\($0)" }
            let replacement = compoundName.flatMap { messageEmoji[$0] }
                ?? messageEmoji[name].map { applying(skinTone: skinTone, to: $0) }
                ?? SlackEmojiCatalog.unicode(for: name, skinTone: skinTone)
            guard let replacement else {
                continue
            }
            mutableText.replaceCharacters(in: match.range, with: replacement)
        }
        return mutableText as String
    }

    static func shortcodeNames(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return shortcodePattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    static func string(fromSlackUnicode value: String, skinTone: Int? = nil) -> String? {
        var scalars = value
            .split(separator: "-")
            .compactMap { UInt32($0, radix: 16).flatMap(UnicodeScalar.init) }
        if let skinTone, (2 ... 6).contains(skinTone),
           let scalar = UnicodeScalar(0x1F3F9 + UInt32(skinTone))
        {
            if !scalars.contains(scalar) {
                scalars.append(scalar)
            }
        }
        guard !scalars.isEmpty else {
            return nil
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func resolveCustomEmoji(_ values: [String: String]) -> [String: URL] {
        func resolve(_ name: String, visited: Set<String>) -> URL? {
            guard !visited.contains(name), let value = values[name] else {
                return nil
            }
            guard value.hasPrefix("alias:") else {
                return URL(string: value)
            }
            return resolve(
                String(value.dropFirst("alias:".count)),
                visited: visited.union([name])
            )
        }

        return Dictionary(
            uniqueKeysWithValues: values.keys.compactMap { name in
                resolve(name, visited: []).map { (name, $0) }
            }
        )
    }

    private static func applying(skinTone: Int?, to emoji: String) -> String {
        guard let skinTone,
              let modifier = UnicodeScalar(0x1F3F9 + UInt32(skinTone))
        else {
            return emoji
        }
        return emoji.unicodeScalars.contains(modifier)
            ? emoji
            : emoji + String(modifier)
    }
}
