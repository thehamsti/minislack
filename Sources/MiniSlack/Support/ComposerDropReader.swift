import AppKit
import UniformTypeIdentifiers

@MainActor
enum ComposerDropReader {
    static let supportedContentTypes: [UTType] = [.fileURL, .image]

    static func attachments(
        from providers: [NSItemProvider]
    ) async -> [ComposerPasteboardAttachment] {
        var fileURLs: [URL] = []
        var images: [ComposerPasteboardAttachment] = []

        for provider in providers {
            if let fileURL = await provider.composerFileURL() {
                fileURLs.append(fileURL)
            } else if let image = await provider.composerImage() {
                images.append(image)
            }
        }

        var attachments: [ComposerPasteboardAttachment] = []
        if !fileURLs.isEmpty {
            attachments.append(.fileURLs(fileURLs))
        }
        attachments.append(contentsOf: images)
        return attachments
    }
}

private extension NSItemProvider {
    @MainActor
    func composerFileURL() async -> URL? {
        guard hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }
        let loaded: URL? = await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
        guard let loaded, loaded.isFileURL else {
            return nil
        }
        return loaded
    }

    @MainActor
    func composerImage() async -> ComposerPasteboardAttachment? {
        guard let identifier = registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else {
            return nil
        }
        let loaded: Data? = await withCheckedContinuation { continuation in
            _ = loadDataRepresentation(
                forTypeIdentifier: identifier
            ) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let loaded,
              let png = Self.pngData(from: loaded, identifier: identifier)
        else {
            return nil
        }
        return .image(
            data: png,
            suggestedFilename: Self.droppedImageName(preferred: suggestedName)
        )
    }

    static func pngData(from data: Data, identifier: String) -> Data? {
        if UTType(identifier) == .png {
            return data
        }
        return NSBitmapImageRep(data: data)?
            .representation(using: .png, properties: [:])
    }

    static func droppedImageName(preferred: String?) -> String {
        guard let preferred, !preferred.isEmpty else {
            return "Dropped Image \(Int(Date.now.timeIntervalSince1970)).png"
        }
        let base = URL(fileURLWithPath: preferred)
            .deletingPathExtension()
            .lastPathComponent
        return base.isEmpty ? preferred : "\(base).png"
    }
}
