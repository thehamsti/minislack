import Foundation

struct MessageHistoryPage: Codable, Equatable, Sendable {
    let messages: [Message]
    let nextCursor: String?
}

struct MessageHistoryCacheStatus: Codable, Equatable, Sendable {
    var pageCount: Int
    var nextCursor: String?
    var isComplete: Bool

    static let empty = MessageHistoryCacheStatus(
        pageCount: 0,
        nextCursor: nil,
        isComplete: false
    )
}

actor MessageHistoryCache {
    private let rootURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(workspaceID: String, rootURL: URL? = nil) {
        let baseURL = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "MiniSlack/History", directoryHint: .isDirectory)
        self.rootURL = baseURL
            .appending(path: workspaceID, directoryHint: .isDirectory)
            .appending(path: "v2", directoryHint: .isDirectory)
    }

    func page(channelID: String, index: Int) throws -> MessageHistoryPage? {
        let url = channelURL(channelID).appending(path: "page-\(index).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try decoder.decode(MessageHistoryPage.self, from: Data(contentsOf: url))
    }

    func status(channelID: String) throws -> MessageHistoryCacheStatus {
        let url = channelURL(channelID).appending(path: "manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        return try decoder.decode(MessageHistoryCacheStatus.self, from: Data(contentsOf: url))
    }

    func store(_ page: MessageHistoryPage, channelID: String, index: Int) throws {
        let directory = channelURL(channelID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try encoder.encode(page).write(
            to: directory.appending(path: "page-\(index).json"),
            options: .atomic
        )

        var manifest = try status(channelID: channelID)
        if index >= manifest.pageCount {
            manifest.pageCount = index + 1
            manifest.nextCursor = page.nextCursor
            manifest.isComplete = page.nextCursor == nil
        }
        try encoder.encode(manifest).write(
            to: directory.appending(path: "manifest.json"),
            options: .atomic
        )
    }

    func mergeLatest(_ page: MessageHistoryPage, channelID: String) throws {
        let existing = try self.page(channelID: channelID, index: 0)
        var messagesByID: [String: Message] = [:]
        for message in (existing?.messages ?? []) + page.messages {
            let key = message.remoteID.map { "remote:\($0)" } ?? "local:\(message.id)"
            messagesByID[key] = message
        }
        let merged = MessageHistoryPage(
            messages: messagesByID.values.sorted { $0.timestamp < $1.timestamp },
            nextCursor: existing?.nextCursor ?? page.nextCursor
        )
        try store(merged, channelID: channelID, index: 0)
    }

    private func channelURL(_ channelID: String) -> URL {
        rootURL.appending(path: channelID, directoryHint: .isDirectory)
    }
}
