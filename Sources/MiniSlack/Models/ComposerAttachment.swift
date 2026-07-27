import Foundation
import UniformTypeIdentifiers

struct ComposerPendingAttachment: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case file
        case image
    }

    enum UploadState: Hashable, Sendable {
        case ready
        case uploading
        case failed(String)
    }

    let id: UUID
    let fileURL: URL
    let filename: String
    let byteCount: Int64?
    let contentTypeIdentifier: String?
    let kind: Kind
    let isTemporary: Bool
    var uploadState: UploadState

    init(
        id: UUID = UUID(),
        fileURL: URL,
        filename: String? = nil,
        byteCount: Int64? = nil,
        contentTypeIdentifier: String? = nil,
        isTemporary: Bool = false,
        uploadState: UploadState = .ready
    ) throws {
        guard fileURL.isFileURL else {
            throw ComposerAttachmentError.notLocalFile
        }
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard values.isRegularFile == true else {
            throw ComposerAttachmentError.notRegularFile
        }
        let displayName = filename ?? fileURL.lastPathComponent
        guard !displayName.isEmpty else {
            throw ComposerAttachmentError.notRegularFile
        }
        let type = contentTypeIdentifier.flatMap(UTType.init)
            ?? UTType(filenameExtension: fileURL.pathExtension)

        self.id = id
        self.fileURL = fileURL.standardizedFileURL
        self.filename = displayName
        self.byteCount = byteCount ?? values.fileSize.map(Int64.init)
        self.contentTypeIdentifier = type?.identifier
        kind = type?.conforms(to: .image) == true ? .image : .file
        self.isTemporary = isTemporary
        self.uploadState = uploadState
    }

    var mimeType: String? {
        contentTypeIdentifier
            .flatMap(UTType.init)?
            .preferredMIMEType
    }

    var detail: String {
        let kindText = contentTypeIdentifier
            .flatMap(UTType.init)?
            .localizedDescription
        let sizeText = byteCount.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
        return [kindText, sizeText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct ComposerAttachmentUploadProgress: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int
    let filename: String

    var displayText: String {
        "Uploading \(completedCount + 1) of \(totalCount): \(filename)"
    }
}

struct ComposerAttachmentDraftState: Equatable, Sendable {
    var attachments: [ComposerPendingAttachment] = []
    var progress: ComposerAttachmentUploadProgress?
    var errorMessage: String?

    var isUploading: Bool {
        progress != nil
    }

    var isEmpty: Bool {
        attachments.isEmpty && progress == nil && errorMessage == nil
    }
}

enum ComposerPasteboardAttachment: Hashable, Sendable {
    case fileURLs([URL])
    case image(data: Data, suggestedFilename: String)
}

enum ComposerAttachmentError: LocalizedError, Equatable {
    case noConversation
    case notLocalFile
    case notRegularFile
    case tooManyAttachments(maximum: Int)
    case fileUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noConversation:
            "Open a conversation before attaching a file."
        case .notLocalFile:
            "Only local files can be attached."
        case .notRegularFile:
            "Folders and special files cannot be attached."
        case let .tooManyAttachments(maximum):
            "Attach up to \(maximum) files at a time."
        case let .fileUnavailable(filename):
            "\(filename) is no longer available."
        }
    }
}
