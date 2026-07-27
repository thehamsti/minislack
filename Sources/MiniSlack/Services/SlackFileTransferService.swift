import AppKit
import CryptoKit
import Foundation
import ImageIO

actor SlackFileTransferService {
    typealias AccessTokenProvider = @Sendable () throws -> String?

    enum TransferError: LocalizedError {
        case missingSource
        case missingCredentials
        case invalidSource
        case untrustedAuthenticatedHost
        case http(Int)
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .missingSource:
                "This file does not include a downloadable URL."
            case .missingCredentials:
                "Reconnect Slack to access this private file."
            case .invalidSource:
                "Slack returned an invalid file URL."
            case .untrustedAuthenticatedHost:
                "The private file URL did not point to a trusted Slack host."
            case let .http(status):
                status == 401 || status == 403
                    ? "Slack no longer authorizes access to this file. Reconnect and try again."
                    : "The file download failed with HTTP status \(status)."
            case .invalidImage:
                "The image preview could not be decoded."
            }
        }
    }

    static let shared = SlackFileTransferService()
    static let imageCacheCountLimit = 96
    static let imageCacheTotalCostLimit = 64 * 1_024 * 1_024

    private let urlSession: URLSession
    private let accessTokenProvider: AccessTokenProvider
    private let cacheRoot: URL
    private let imageCache = NSCache<NSString, CGImage>()

    init(
        urlSession: URLSession = .shared,
        cacheRoot: URL = SlackFileTransferService.defaultCacheRoot,
        accessTokenProvider: @escaping AccessTokenProvider = {
            try SlackCredentialStore().load()?.accessToken
        }
    ) {
        self.urlSession = urlSession
        self.cacheRoot = cacheRoot
        self.accessTokenProvider = accessTokenProvider
        imageCache.countLimit = Self.imageCacheCountLimit
        imageCache.totalCostLimit = Self.imageCacheTotalCostLimit
    }

    func localURL(for file: MessageFile) async throws -> URL {
        guard let source = file.contentSource else {
            throw TransferError.missingSource
        }
        return try await localURL(
            for: source,
            suggestedName: file.name,
            cacheKey: file.id
        )
    }

    func localURL(
        for source: MessageMediaSource,
        suggestedName: String,
        cacheKey: String
    ) async throws -> URL {
        if source.url.isFileURL && !source.requiresSlackAuthorization {
            guard FileManager.default.isReadableFile(atPath: source.url.path) else {
                throw TransferError.invalidSource
            }
            return source.url
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: cacheRoot,
            withIntermediateDirectories: true
        )
        let request = try authorizedRequest(for: source)
        let destination = cachedURL(
            suggestedName: suggestedName,
            cacheKey: Self.fileCacheKey(
                for: source,
                authorizationHeader: request.value(
                    forHTTPHeaderField: "Authorization"
                ),
                fileID: cacheKey
            )
        )
        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }

        let (temporaryURL, response) = try await urlSession.download(for: request)
        try Self.validate(response)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: temporaryURL)
            return destination
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    func download(_ file: MessageFile, to destination: URL) async throws {
        guard let source = file.contentSource else {
            throw TransferError.missingSource
        }
        try await download(
            source,
            suggestedName: file.name,
            cacheKey: file.id,
            to: destination
        )
    }

    func download(
        _ source: MessageMediaSource,
        suggestedName: String,
        cacheKey: String,
        to destination: URL
    ) async throws {
        let cached = try await localURL(
            for: source,
            suggestedName: suggestedName,
            cacheKey: cacheKey
        )
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: cached, to: destination)
    }

    func thumbnail(
        from source: MessageMediaSource,
        maximumPixelSize: Int = 720
    ) async throws -> CGImage {
        let request: URLRequest?
        if source.url.isFileURL && !source.requiresSlackAuthorization {
            request = nil
        } else {
            request = try authorizedRequest(for: source)
        }
        let cacheKey = Self.imageCacheKey(
            for: source,
            authorizationHeader: request?.value(
                forHTTPHeaderField: "Authorization"
            ),
            maximumPixelSize: maximumPixelSize
        )
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }
        if source.url.isFileURL && !source.requiresSlackAuthorization {
            guard let imageSource = CGImageSourceCreateWithURL(
                source.url as CFURL,
                nil
            ) else {
                throw TransferError.invalidImage
            }
            let image = try Self.thumbnail(
                from: imageSource,
                maximumPixelSize: maximumPixelSize
            )
            imageCache.setObject(
                image,
                forKey: cacheKey,
                cost: Self.imageCacheCost(for: image)
            )
            return image
        }
        guard let request else {
            throw TransferError.invalidSource
        }
        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response)
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw TransferError.invalidImage
        }
        let image = try Self.thumbnail(
            from: imageSource,
            maximumPixelSize: maximumPixelSize
        )
        imageCache.setObject(
            image,
            forKey: cacheKey,
            cost: Self.imageCacheCost(for: image)
        )
        return image
    }

    static func imageCacheCost(for image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    static func imageCacheKey(
        for source: MessageMediaSource,
        authorizationHeader: String?,
        maximumPixelSize: Int
    ) -> NSString {
        let scope = authorizationScope(
            for: source,
            authorizationHeader: authorizationHeader
        )
        return "\(source.url.absoluteString)|\(scope)|\(maximumPixelSize)" as NSString
    }

    static func fileCacheKey(
        for source: MessageMediaSource,
        authorizationHeader: String?,
        fileID: String
    ) -> String {
        let scope = authorizationScope(
            for: source,
            authorizationHeader: authorizationHeader
        )
        return SHA256.hash(
            data: Data(
                "\(fileID)|\(source.url.absoluteString)|\(scope)".utf8
            )
        )
        .map { String(format: "%02x", $0) }
        .joined()
    }

    static func makeRequest(
        for source: MessageMediaSource,
        accessToken: String?
    ) throws -> URLRequest {
        guard let scheme = source.url.scheme?.lowercased(),
              scheme == "https" || (!source.requiresSlackAuthorization && scheme == "http")
        else {
            throw TransferError.invalidSource
        }
        var request = URLRequest(url: source.url)
        if source.requiresSlackAuthorization {
            guard isTrustedSlackFileURL(source.url) else {
                throw TransferError.untrustedAuthenticatedHost
            }
            guard let accessToken, !accessToken.isEmpty else {
                throw TransferError.missingCredentials
            }
            request.setValue(
                "Bearer \(accessToken)",
                forHTTPHeaderField: "Authorization"
            )
        }
        return request
    }

    private func authorizedRequest(for source: MessageMediaSource) throws -> URLRequest {
        let accessToken = source.requiresSlackAuthorization
            ? try accessTokenProvider()
            : nil
        return try Self.makeRequest(for: source, accessToken: accessToken)
    }

    private func cachedURL(suggestedName: String, cacheKey: String) -> URL {
        let safeKey = cacheKey.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let fileExtension = URL(fileURLWithPath: suggestedName).pathExtension
        let base = cacheRoot.appending(path: safeKey.isEmpty ? UUID().uuidString : safeKey)
        return fileExtension.isEmpty ? base : base.appendingPathExtension(fileExtension)
    }

    private static func authorizationScope(
        for source: MessageMediaSource,
        authorizationHeader: String?
    ) -> String {
        guard source.requiresSlackAuthorization else {
            return "public"
        }
        guard let authorizationHeader else {
            return "private"
        }
        return SHA256.hash(data: Data(authorizationHeader.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw TransferError.invalidSource
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw TransferError.http(response.statusCode)
        }
    }

    private static func thumbnail(
        from imageSource: CGImageSource,
        maximumPixelSize: Int
    ) throws -> CGImage {
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        ) else {
            throw TransferError.invalidImage
        }
        return image
    }

    private static func isTrustedSlackFileURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else {
            return false
        }
        return host == "slack.com"
            || host.hasSuffix(".slack.com")
            || host == "slack-files.com"
            || host.hasSuffix(".slack-files.com")
            || host == "slack-edge.com"
            || host.hasSuffix(".slack-edge.com")
    }

    private static var defaultCacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "MiniSlack/Attachments", directoryHint: .isDirectory)
    }
}

@MainActor
enum MessageFileSystemActions {
    static func chooseDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
