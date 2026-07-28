import Foundation

struct CodePreviewSyntax: Equatable, Sendable {
    var name: String
    var lineComments: [String] = []
    var blockCommentOpen: String?
    var blockCommentClose: String?
    var stringDelimiters: Set<Character> = []
    var keywords: Set<String> = []
}

extension CodePreviewSyntax {
    /// Quick Look renders media and office documents far better than a text
    /// view, so only text-shaped files resolve to a syntax here.
    static func forFilename(_ filename: String) -> CodePreviewSyntax? {
        let name = (filename as NSString).lastPathComponent.lowercased()
        let fileExtension = (name as NSString).pathExtension
        if fileExtension.isEmpty {
            return bareFilenames[name]
        }
        return byExtension[fileExtension]
    }

    private static let bareFilenames: [String: CodePreviewSyntax] = [
        "makefile": .script(named: "Makefile"),
        "dockerfile": .script(named: "Dockerfile"),
        "gemfile": .script(named: "Ruby"),
        "rakefile": .script(named: "Ruby"),
        "podfile": .script(named: "Ruby"),
        "readme": .plain(named: "Text"),
        "license": .plain(named: "Text"),
    ]

    private static let byExtension: [String: CodePreviewSyntax] = {
        var table: [String: CodePreviewSyntax] = [:]
        func register(_ extensions: [String], _ syntax: CodePreviewSyntax) {
            for value in extensions {
                table[value] = syntax
            }
        }

        register(
            [
                "swift", "java", "kt", "kts", "c", "h", "cpp", "cc", "cxx",
                "hpp", "hh", "cs", "js", "jsx", "mjs", "cjs", "ts", "tsx",
                "go", "rs", "php", "scala", "dart", "m", "mm", "groovy",
                "gradle", "proto",
            ],
            .cLike(named: "Source Code")
        )
        register(
            ["py", "rb", "sh", "bash", "zsh", "fish", "pl", "r", "lua", "ex",
             "exs", "nim", "cr", "jl"],
            .script(named: "Script")
        )
        register(
            ["html", "htm", "xml", "svg", "vue", "svelte", "plist", "xib",
             "storyboard", "xhtml"],
            .markup(named: "Markup")
        )
        register(["css", "scss", "sass", "less"], .style(named: "Stylesheet"))
        register(["json", "jsonc", "geojson"], .json(named: "JSON"))
        register(
            ["yaml", "yml", "toml", "ini", "cfg", "conf", "env", "properties",
             "editorconfig", "gitignore", "gitattributes"],
            .configuration(named: "Configuration")
        )
        register(["sql"], .sql(named: "SQL"))
        register(
            ["md", "markdown", "txt", "text", "log", "csv", "tsv", "rtf",
             "srt", "vtt"],
            .plain(named: "Text")
        )
        return table
    }()
}

private extension CodePreviewSyntax {
    static func cLike(named name: String) -> CodePreviewSyntax {
        CodePreviewSyntax(
            name: name,
            lineComments: ["//"],
            blockCommentOpen: "/*",
            blockCommentClose: "*/",
            stringDelimiters: ["\"", "'", "`"],
            keywords: cLikeKeywords
        )
    }

    static func script(named name: String) -> CodePreviewSyntax {
        CodePreviewSyntax(
            name: name,
            lineComments: ["#"],
            stringDelimiters: ["\"", "'", "`"],
            keywords: scriptKeywords
        )
    }

    static func markup(named name: String) -> CodePreviewSyntax {
        CodePreviewSyntax(
            name: name,
            blockCommentOpen: "<!--",
            blockCommentClose: "-->",
            stringDelimiters: ["\"", "'"]
        )
    }

    static func style(named name: String) -> CodePreviewSyntax {
        CodePreviewSyntax(
            name: name,
            blockCommentOpen: "/*",
            blockCommentClose: "*/",
            stringDelimiters: ["\"", "'"],
            keywords: ["important", "media", "import", "keyframes", "supports"]
        )
    }

    static func json(named name: String) -> CodePreviewSyntax {
        CodePreviewSyntax(
            name: name,
            lineComments: ["//"],
            blockCommentOpen: "/*",
            blockCommentClose: "*/",
            stringDelimiters: ["\""],
            keywords: ["true", "false", "null"]
        )
    }

    static func configuration(named name: String) -> CodePreviewSyntax {
        CodePreviewSyntax(
            name: name,
            lineComments: ["#", ";"],
            stringDelimiters: ["\"", "'"],
            keywords: ["true", "false", "null", "yes", "no", "on", "off"]
        )
    }

    static func sql(named name: String) -> CodePreviewSyntax {
        CodePreviewSyntax(
            name: name,
            lineComments: ["--"],
            blockCommentOpen: "/*",
            blockCommentClose: "*/",
            stringDelimiters: ["'", "\""],
            keywords: sqlKeywords
        )
    }

    static func plain(named name: String) -> CodePreviewSyntax {
        CodePreviewSyntax(name: name)
    }

    static let cLikeKeywords: Set<String> = [
        "abstract", "as", "async", "await", "break", "case", "catch", "class",
        "const", "continue", "default", "defer", "deinit", "delete", "do",
        "else", "enum", "export", "extends", "extension", "false", "final",
        "finally", "for", "fun", "func", "function", "guard", "if",
        "implements", "import", "in", "init", "inout", "instanceof",
        "interface", "internal", "is", "lazy", "let", "mut", "namespace",
        "new", "nil", "null", "operator", "override", "package", "private",
        "protected", "protocol", "public", "readonly", "return", "self",
        "static", "struct", "super", "switch", "this", "throw", "throws",
        "trait", "true", "try", "type", "typealias", "typedef", "typeof",
        "union", "unsafe", "use", "var", "void", "where", "while", "yield",
        "bool", "char", "double", "float", "int", "long", "short", "string",
        "unsigned", "signed", "any", "never", "unknown",
    ]

    static let scriptKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "begin", "break", "case",
        "class", "continue", "def", "del", "do", "done", "elif", "else",
        "elsif", "end", "ensure", "esac", "except", "export", "false", "fi",
        "finally", "for", "from", "function", "global", "if", "import", "in",
        "is", "lambda", "local", "module", "next", "nil", "none", "nonlocal",
        "not", "or", "pass", "raise", "require", "rescue", "return", "self",
        "source", "then", "true", "try", "unless", "until", "when", "while",
        "with", "yield", "echo", "set", "unset", "readonly",
    ]

    static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "into", "values", "update",
        "set", "delete", "create", "table", "alter", "drop", "index", "view",
        "join", "inner", "left", "right", "outer", "full", "on", "group",
        "by", "order", "having", "limit", "offset", "union", "all",
        "distinct", "as", "and", "or", "not", "null", "is", "in", "like",
        "between", "case", "when", "then", "else", "end", "primary", "key",
        "foreign", "references", "default", "constraint", "unique", "with",
        "returning", "true", "false",
    ]
}
