import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing

struct CodePreviewDocument: Sendable {
    let lines: [[CodePreviewToken]]
    let syntaxName: String
    let isTruncated: Bool
}

actor ComposerAttachmentFileService {
    static let shared = ComposerAttachmentFileService()
    static let maximumPreviewByteCount = 512 * 1024
    static let maximumPreviewLineCount = 5000

    private let cacheRoot: URL

    init(
        cacheRoot: URL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appending(
            path: "MiniSlack/PendingUploads",
            directoryHint: .isDirectory
        )
    ) {
        self.cacheRoot = cacheRoot
    }

    func storePastedImage(
        _ data: Data,
        fileExtension: String = "png"
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: cacheRoot,
            withIntermediateDirectories: true
        )
        let url = cacheRoot
            .appending(path: UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    func thumbnail(
        for url: URL,
        maximumPixelSize: Int = 160
    ) throws -> CGImage {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary
              )
        else {
            throw ComposerAttachmentError.fileUnavailable(url.lastPathComponent)
        }
        return thumbnail
    }

    /// Image files decode directly; movies, PDFs, and documents only render
    /// through Quick Look.
    func previewImage(
        for url: URL,
        pointSize: CGFloat,
        scale: CGFloat
    ) async -> CGImage? {
        if let image = try? thumbnail(
            for: url,
            maximumPixelSize: Int(pointSize * scale)
        ) {
            return image
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pointSize, height: pointSize),
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(
                for: request
            ) { representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
    }

    func codePreview(
        for url: URL,
        filename: String
    ) -> CodePreviewDocument? {
        guard let syntax = CodePreviewSyntax.forFilename(filename) else {
            return nil
        }
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(
            upToCount: Self.maximumPreviewByteCount
        ), !data.isEmpty else {
            return nil
        }
        // A NUL byte means this is binary, not the text file the extension
        // advertised.
        guard !data.contains(0) else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else {
            return nil
        }

        let truncatedBySize = data.count == Self.maximumPreviewByteCount
        var lines = CodePreviewHighlighter.lines(of: text, syntax: syntax)
        let truncatedByLines = lines.count > Self.maximumPreviewLineCount
        if truncatedByLines {
            lines = Array(lines.prefix(Self.maximumPreviewLineCount))
        }
        return CodePreviewDocument(
            lines: lines,
            syntaxName: syntax.name,
            isTruncated: truncatedBySize || truncatedByLines
        )
    }

    func removeTemporaryFile(at url: URL) {
        let candidate = url.standardizedFileURL.path
        let root = cacheRoot.standardizedFileURL.path + "/"
        guard candidate.hasPrefix(root) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    func clearTemporaryFiles() {
        try? FileManager.default.removeItem(at: cacheRoot)
    }
}
