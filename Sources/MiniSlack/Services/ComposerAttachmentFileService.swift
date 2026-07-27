import CoreGraphics
import Foundation
import ImageIO

actor ComposerAttachmentFileService {
    static let shared = ComposerAttachmentFileService()

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
