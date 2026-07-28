import Foundation
import Testing
@testable import MiniSlack

struct CodePreviewTests {
    @Test
    func onlyTextShapedFilesResolveToASyntax() {
        #expect(CodePreviewSyntax.forFilename("AppStore.swift")?.name == "Source Code")
        #expect(CodePreviewSyntax.forFilename("deploy.py")?.name == "Script")
        #expect(CodePreviewSyntax.forFilename("index.tsx")?.name == "Source Code")
        #expect(CodePreviewSyntax.forFilename("config.yml")?.name == "Configuration")
        #expect(CodePreviewSyntax.forFilename("schema.sql")?.name == "SQL")
        #expect(CodePreviewSyntax.forFilename("/tmp/Dockerfile")?.name == "Dockerfile")
        #expect(CodePreviewSyntax.forFilename("notes.TXT")?.name == "Text")

        #expect(CodePreviewSyntax.forFilename("photo.png") == nil)
        #expect(CodePreviewSyntax.forFilename("clip.mov") == nil)
        #expect(CodePreviewSyntax.forFilename("report.pdf") == nil)
        #expect(CodePreviewSyntax.forFilename("deck.key") == nil)
    }

    @Test
    func keywordsInsideStringsAndCommentsStayUncoloured() throws {
        let syntax = try #require(CodePreviewSyntax.forFilename("main.swift"))
        let source = """
        // return 42
        let name = "class func"
        """

        let lines = CodePreviewHighlighter.lines(of: source, syntax: syntax)

        #expect(lines.count == 2)
        #expect(lines[0] == [CodePreviewToken(text: "// return 42", kind: .comment)])
        #expect(lines[1].first == CodePreviewToken(text: "let", kind: .keyword))
        #expect(
            lines[1].contains(
                CodePreviewToken(text: "\"class func\"", kind: .string)
            )
        )
        #expect(!lines[1].contains { $0.kind == .keyword && $0.text == "class" })
    }

    @Test
    func blockCommentsAndNumbersSplitAcrossLines() throws {
        let syntax = try #require(CodePreviewSyntax.forFilename("app.js"))
        let source = """
        /* first
        second */
        const total = 1024;
        """

        let lines = CodePreviewHighlighter.lines(of: source, syntax: syntax)

        #expect(lines.count == 3)
        #expect(lines[0] == [CodePreviewToken(text: "/* first", kind: .comment)])
        #expect(lines[1] == [CodePreviewToken(text: "second */", kind: .comment)])
        #expect(lines[2].contains(CodePreviewToken(text: "1024", kind: .number)))
        #expect(lines[2].contains(CodePreviewToken(text: "const", kind: .keyword)))
    }

    @Test
    func unterminatedQuoteDoesNotSwallowTheRestOfTheFile() throws {
        let syntax = try #require(CodePreviewSyntax.forFilename("notes.rb"))
        let source = """
        puts "oops
        puts 7
        """

        let lines = CodePreviewHighlighter.lines(of: source, syntax: syntax)

        #expect(lines.count == 2)
        #expect(lines[1].contains(CodePreviewToken(text: "7", kind: .number)))
    }

    @Test
    func plainTextRoundTripsWithoutLosingCharacters() throws {
        let syntax = try #require(CodePreviewSyntax.forFilename("notes.txt"))
        let source = "plain line one\n\nline three"

        let lines = CodePreviewHighlighter.lines(of: source, syntax: syntax)
        let rebuilt = lines
            .map { $0.map(\.text).joined() }
            .joined(separator: "\n")

        #expect(rebuilt == source)
        #expect(lines.allSatisfy { $0.allSatisfy { $0.kind == .plain } })
    }

    @Test
    func codePreviewLoadsTextAndRejectsBinaryAndUnknownTypes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MiniSlackCodePreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appending(path: "sample.swift")
        try "let answer = 42\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let binaryURL = directory.appending(path: "fake.json")
        try Data([0x7B, 0x00, 0x7D]).write(to: binaryURL)
        let imageURL = directory.appending(path: "photo.png")
        try Data("not really a png".utf8).write(to: imageURL)

        let service = ComposerAttachmentFileService(
            cacheRoot: directory.appending(path: "cache")
        )

        let document = try #require(
            await service.codePreview(for: sourceURL, filename: "sample.swift")
        )
        #expect(document.syntaxName == "Source Code")
        #expect(document.isTruncated == false)
        #expect(
            document.lines[0].contains(
                CodePreviewToken(text: "let", kind: .keyword)
            )
        )

        #expect(
            await service.codePreview(for: binaryURL, filename: "fake.json") == nil
        )
        #expect(
            await service.codePreview(for: imageURL, filename: "photo.png") == nil
        )
    }

    @Test
    func oversizedFilesAreTruncatedRatherThanFullyTokenized() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MiniSlackCodePreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "huge.txt")
        let line = String(repeating: "a", count: 63) + "\n"
        try String(repeating: line, count: 12000)
            .write(to: url, atomically: true, encoding: .utf8)

        let service = ComposerAttachmentFileService(
            cacheRoot: directory.appending(path: "cache")
        )
        let document = try #require(
            await service.codePreview(for: url, filename: "huge.txt")
        )

        #expect(document.isTruncated)
        #expect(
            document.lines.count
                <= ComposerAttachmentFileService.maximumPreviewLineCount
        )
    }
}
