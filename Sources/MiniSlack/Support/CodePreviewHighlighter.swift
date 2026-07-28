import Foundation

enum CodePreviewTokenKind: Equatable, Sendable {
    case plain
    case comment
    case string
    case number
    case keyword
}

struct CodePreviewToken: Equatable, Sendable {
    let text: String
    let kind: CodePreviewTokenKind
}

/// A single pass over the file keeps keywords inside strings and comments from
/// being coloured, which layered regular expressions get wrong.
enum CodePreviewHighlighter {
    static func lines(
        of text: String,
        syntax: CodePreviewSyntax
    ) -> [[CodePreviewToken]] {
        var lines: [[CodePreviewToken]] = []
        var current: [CodePreviewToken] = []

        func emit(_ value: [Character], _ kind: CodePreviewTokenKind) {
            guard !value.isEmpty else {
                return
            }
            // A token may span newlines; split it so every line renders alone.
            var buffer: [Character] = []
            for character in value {
                if character == "\n" {
                    if !buffer.isEmpty {
                        current.append(
                            CodePreviewToken(text: String(buffer), kind: kind)
                        )
                    }
                    lines.append(current)
                    current = []
                    buffer = []
                } else {
                    buffer.append(character)
                }
            }
            if !buffer.isEmpty {
                current.append(
                    CodePreviewToken(text: String(buffer), kind: kind)
                )
            }
        }

        let characters = Array(text)
        var index = 0
        var plain: [Character] = []

        func flushPlain() {
            emit(plain, .plain)
            plain = []
        }

        while index < characters.count {
            if syntax.lineComments.contains(where: {
                matches($0, in: characters, at: index)
            }) {
                flushPlain()
                let start = index
                while index < characters.count, characters[index] != "\n" {
                    index += 1
                }
                emit(Array(characters[start ..< index]), .comment)
                continue
            }

            if let open = syntax.blockCommentOpen,
               let close = syntax.blockCommentClose,
               matches(open, in: characters, at: index)
            {
                flushPlain()
                let start = index
                index += open.count
                while index < characters.count,
                      !matches(close, in: characters, at: index)
                {
                    index += 1
                }
                index = min(characters.count, index + close.count)
                emit(Array(characters[start ..< index]), .comment)
                continue
            }

            let character = characters[index]

            if syntax.stringDelimiters.contains(character) {
                flushPlain()
                let start = index
                index += 1
                while index < characters.count {
                    if characters[index] == "\\", index + 1 < characters.count {
                        index += 2
                        continue
                    }
                    if characters[index] == character {
                        index += 1
                        break
                    }
                    // Only backticks legitimately wrap lines; a stray quote
                    // must not swallow the rest of the file.
                    if characters[index] == "\n", character != "`" {
                        break
                    }
                    index += 1
                }
                emit(Array(characters[start ..< index]), .string)
                continue
            }

            if character.isNumber, !isIdentifierCharacter(previous(characters, index)) {
                flushPlain()
                let start = index
                while index < characters.count,
                      characters[index].isHexDigit
                          || characters[index] == "."
                          || characters[index] == "_"
                          || characters[index] == "x"
                          || characters[index] == "X"
                {
                    index += 1
                }
                emit(Array(characters[start ..< index]), .number)
                continue
            }

            if isIdentifierStart(character) {
                let start = index
                while index < characters.count,
                      isIdentifierCharacter(characters[index])
                {
                    index += 1
                }
                let word = String(characters[start ..< index])
                if syntax.keywords.contains(word.lowercased()) {
                    flushPlain()
                    emit(Array(word), .keyword)
                } else {
                    plain.append(contentsOf: word)
                }
                continue
            }

            plain.append(character)
            index += 1
        }

        flushPlain()
        lines.append(current)
        return lines
    }

    private static func matches(
        _ needle: String,
        in characters: [Character],
        at index: Int
    ) -> Bool {
        let needleCharacters = Array(needle)
        guard !needleCharacters.isEmpty,
              index + needleCharacters.count <= characters.count
        else {
            return false
        }
        for offset in 0 ..< needleCharacters.count
        where characters[index + offset] != needleCharacters[offset] {
            return false
        }
        return true
    }

    private static func previous(
        _ characters: [Character],
        _ index: Int
    ) -> Character? {
        index > 0 ? characters[index - 1] : nil
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$"
    }

    private static func isIdentifierCharacter(_ character: Character?) -> Bool {
        guard let character else {
            return false
        }
        return character.isLetter || character.isNumber
            || character == "_" || character == "$"
    }
}
