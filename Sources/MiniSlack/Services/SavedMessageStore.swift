import Foundation

actor SavedMessageStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var latestRevision = 0

    init(workspaceID: String, rootURL: URL? = nil) {
        let baseURL = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "MiniSlack/Saved", directoryHint: .isDirectory)
        fileURL = baseURL
            .appending(path: workspaceID, directoryHint: .isDirectory)
            .appending(path: "v1", directoryHint: .isDirectory)
            .appending(path: "messages.json")
    }

    func load() throws -> [SavedMessage] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        return try decoder.decode(
            [SavedMessage].self,
            from: Data(contentsOf: fileURL)
        )
        .sorted { $0.savedAt > $1.savedAt }
    }

    func save(_ messages: [SavedMessage]) throws {
        try write(messages)
    }

    func save(_ messages: [SavedMessage], revision: Int) throws {
        guard revision >= latestRevision else {
            return
        }
        try write(messages)
        latestRevision = revision
    }

    private func write(_ messages: [SavedMessage]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(messages).write(to: fileURL, options: .atomic)
    }
}
