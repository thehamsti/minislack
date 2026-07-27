import Foundation

struct CachedWorkspaceState: Codable, Sendable {
    let savedAt: Date
    let snapshot: SlackWorkspaceSnapshot
    let lastPolledAtByConversationID: [String: Date]
}

actor WorkspaceSnapshotStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(workspaceID: String, rootURL: URL? = nil) {
        let baseURL = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "MiniSlack/Snapshot", directoryHint: .isDirectory)
        fileURL = baseURL
            .appending(path: workspaceID, directoryHint: .isDirectory)
            .appending(path: "v1", directoryHint: .isDirectory)
            .appending(path: "snapshot.json")
    }

    func load() -> CachedWorkspaceState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try? decoder.decode(
            CachedWorkspaceState.self,
            from: Data(contentsOf: fileURL)
        )
    }

    func save(_ state: CachedWorkspaceState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}
