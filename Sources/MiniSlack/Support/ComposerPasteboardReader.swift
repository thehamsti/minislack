import AppKit

@MainActor
enum ComposerPasteboardReader {
    static func attachments(
        from pasteboard: NSPasteboard
    ) -> [ComposerPasteboardAttachment] {
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.compactMap { value in
            (value as? NSURL).map { $0 as URL }
        } ?? []
        if !fileURLs.isEmpty {
            return [.fileURLs(fileURLs)]
        }

        if let png = pasteboard.data(forType: .png) {
            return [.image(data: png, suggestedFilename: pastedImageName())]
        }
        guard let tiff = pasteboard.data(forType: .tiff),
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(
                  using: .png,
                  properties: [:]
              )
        else {
            return []
        }
        return [.image(data: png, suggestedFilename: pastedImageName())]
    }

    private static func pastedImageName() -> String {
        "Pasted Image \(Int(Date.now.timeIntervalSince1970)).png"
    }
}
