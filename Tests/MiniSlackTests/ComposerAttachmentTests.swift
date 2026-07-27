import AppKit
import Foundation
import Testing
@testable import MiniSlack

@MainActor
struct ComposerAttachmentTests {
    @Test
    func attachmentDraftsStayWithTheirConversationAndPreviewAsMessageFiles() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let firstFile = temporaryDirectory.appending(path: "brief.txt")
        let secondFile = temporaryDirectory.appending(path: "diagram.png")
        try Data("launch notes".utf8).write(to: firstFile)
        try tinyPNG.write(to: secondFile)
        let store = AppStore(conversations: [
            conversation(id: "C1"),
            conversation(id: "C2"),
        ])

        store.select("C1")
        store.draft = "Here is the brief"
        store.addComposerAttachments([firstFile], to: "C1")
        store.addComposerAttachments([secondFile], to: "C2")

        #expect(store.attachmentDraftState(for: "C1").attachments.count == 1)
        #expect(store.attachmentDraftState(for: "C2").attachments.count == 1)

        store.sendComposerDraft()

        let sent = try #require(store.selectedConversation?.messages.last)
        let sentFile = try #require(sent.files.first)
        #expect(sent.displayBody == "Here is the brief")
        #expect(sentFile.name == "brief.txt")
        #expect(sentFile.contentSource?.url == firstFile.standardizedFileURL)
        #expect(sentFile.contentSource?.requiresSlackAuthorization == false)
        #expect(store.attachmentDraftState(for: "C1").isEmpty)
        #expect(store.attachmentDraftState(for: "C2").attachments.count == 1)
        #expect(store.composerDraft.isEmpty)
    }

    @Test
    func pasteboardPrefersFilesAndAcceptsScreenshots() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fileURL = temporaryDirectory.appending(path: "notes.txt")
        try Data("notes".utf8).write(to: fileURL)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("MiniSlackTests-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([fileURL as NSURL]))

        let fileAttachments = ComposerPasteboardReader.attachments(from: pasteboard)
        #expect(fileAttachments == [.fileURLs([fileURL])])

        pasteboard.clearContents()
        pasteboard.setData(tinyPNG, forType: .png)
        let imageAttachments = ComposerPasteboardReader.attachments(from: pasteboard)
        guard case let .image(data, suggestedFilename) = imageAttachments.first else {
            Issue.record("Expected a pasted image attachment")
            return
        }
        #expect(data == tinyPNG)
        #expect(suggestedFilename.hasPrefix("Pasted Image "))
        #expect(suggestedFilename.hasSuffix(".png"))
    }

    @Test
    func localPreviewFilesSupportQuickLookThumbnailAndDownload() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appending(path: "preview.png")
        let destinationURL = temporaryDirectory.appending(path: "saved.png")
        try tinyPNG.write(to: sourceURL)
        let source = MessageMediaSource(
            url: sourceURL,
            requiresSlackAuthorization: false
        )
        let service = SlackFileTransferService(
            cacheRoot: temporaryDirectory.appending(path: "cache"),
            accessTokenProvider: { nil }
        )

        let localURL = try await service.localURL(
            for: source,
            suggestedName: "preview.png",
            cacheKey: "preview"
        )
        let thumbnail = try await service.thumbnail(
            from: source,
            maximumPixelSize: 32
        )
        try await service.download(
            source,
            suggestedName: "preview.png",
            cacheKey: "preview",
            to: destinationURL
        )

        #expect(localURL == sourceURL)
        #expect(thumbnail.width == 1)
        #expect(thumbnail.height == 1)
        #expect(try Data(contentsOf: destinationURL) == tinyPNG)
    }

    @Test
    func fileURLUploadStreamsBytesAndEncodesInitialComment() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fileURL = temporaryDirectory.appending(path: "brief.txt")
        let fileData = Data("launch notes".utf8)
        try fileData.write(to: fileURL)
        let token = "api-upload-\(UUID().uuidString)"
        let recorder = ComposerUploadRequestRecorder()
        let client = composerUploadClient(token: token) { request in
            let request = try materializedRequest(request)
            recorder.append(request)
            switch (request.url?.host, request.url?.path) {
            case ("slack.com", "/api/files.getUploadURLExternal"):
                return try composerResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "upload_url": "https://uploads.example.test/\(token)",
                      "file_id": "F1"
                    }
                    """
                )
            case ("uploads.example.test", _):
                return try composerResponse(for: request, json: "{}")
            case ("slack.com", "/api/files.completeUploadExternal"):
                return try composerResponse(
                    for: request,
                    json: #"{"ok":true,"files":[{"id":"F1","title":"brief"}]}"#
                )
            default:
                throw ComposerUploadStubError.unexpectedRequest
            }
        }
        defer { ComposerUploadURLProtocol.unregister(token: token) }

        let uploaded = try await client.uploadFile(
            fileURL: fileURL,
            filename: "brief.txt",
            title: "brief",
            channelID: "C1",
            initialComment: "For <@U1>",
            accessToken: token
        )

        #expect(uploaded.id == "F1")
        let requests = recorder.values
        #expect(requests.count == 3)
        #expect(requests[1].httpBody == fileData)
        let completionBody = try #require(requests[2].httpBody)
        let completion = try #require(
            JSONSerialization.jsonObject(with: completionBody)
                as? [String: Any]
        )
        #expect(completion["channel_id"] as? String == "C1")
        #expect(completion["initial_comment"] as? String == "For <@U1>")
    }

    @Test
    func liveUploadUsesSlackExternalFlowAndRefreshesHistory() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fileURL = temporaryDirectory.appending(path: "brief.txt")
        let fileData = Data("launch notes".utf8)
        try fileData.write(to: fileURL)
        let token = "upload-\(UUID().uuidString)"
        let recorder = ComposerUploadRequestRecorder()
        let client = composerUploadClient(token: token) { request in
            let request = try materializedRequest(request)
            recorder.append(request)
            switch (request.url?.host, request.url?.path) {
            case ("slack.com", "/api/files.getUploadURLExternal"):
                return try composerResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "upload_url": "https://uploads.example.test/\(token)",
                      "file_id": "F1"
                    }
                    """
                )
            case ("uploads.example.test", _):
                return try composerResponse(for: request, json: "{}")
            case ("slack.com", "/api/files.completeUploadExternal"):
                return try composerResponse(
                    for: request,
                    json: #"{"ok":true,"files":[{"id":"F1","title":"brief"}]}"#
                )
            case ("slack.com", "/api/conversations.history"):
                return try composerResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "messages": [{
                        "ts": "1900000000.000100",
                        "user": "U1",
                        "text": "",
                        "files": [{
                          "id": "F1",
                          "name": "brief.txt",
                          "title": "brief",
                          "mimetype": "text/plain",
                          "mode": "hosted",
                          "url_private_download": "https://files.slack.com/F1/brief.txt"
                        }]
                      }],
                      "response_metadata": {"next_cursor": ""}
                    }
                    """
                )
            case ("slack.com", "/api/conversations.mark"):
                return try composerResponse(for: request, json: #"{"ok":true}"#)
            default:
                throw ComposerUploadStubError.unexpectedRequest
            }
        }
        defer { ComposerUploadURLProtocol.unregister(token: token) }
        let store = AppStore(
            conversations: [conversation(id: "C1")],
            users: [
                WorkspaceUser(
                    id: "U1",
                    displayName: "Taylor",
                    status: "",
                    isActive: true
                )
            ],
            connectionState: .connected("Acme"),
            slackAPI: client,
            credentials: credentials(token: token)
        )
        store.select("C1")
        let draft = ComposerDraft(
            text: "For @Taylor",
            tags: [
                ComposerTag(
                    kind: .user,
                    entityID: "U1",
                    displayText: "@Taylor",
                    range: NSRange(location: 4, length: 7)
                )
            ]
        )
        store.composerDraft = draft
        store.addComposerAttachments([fileURL], to: "C1")

        await store.uploadPendingAttachments(
            for: "C1",
            initialComment: draft.slackText,
            draftToClear: draft
        )

        #expect(store.attachmentDraftState(for: "C1").isEmpty)
        #expect(store.composerDraft.isEmpty)
        #expect(store.selectedConversation?.messages.last?.files.first?.id == "F1")
        let requests = recorder.values
        #expect(requests.prefix(3).map(\.url?.path) == [
            "/api/files.getUploadURLExternal",
            "/\(token)",
            "/api/files.completeUploadExternal",
        ])
        let uploadRequestBody = try #require(requests[0].httpBody)
        let uploadRequest = try #require(
            JSONSerialization.jsonObject(with: uploadRequestBody)
                as? [String: String]
        )
        #expect(uploadRequest == [
            "filename": "brief.txt",
            "length": String(fileData.count),
        ])
        #expect(requests[1].httpBody == fileData)
        let completionBody = try #require(requests[2].httpBody)
        let completion = try #require(
            JSONSerialization.jsonObject(with: completionBody)
                as? [String: Any]
        )
        #expect(completion["channel_id"] as? String == "C1")
        #expect(completion["initial_comment"] as? String == "For <@U1>")
        let files = try #require(completion["files"] as? [[String: String]])
        #expect(files == [["id": "F1", "title": "brief"]])
        #expect(!requests.contains { $0.url?.path == "/api/chat.postMessage" })
    }

    @Test
    func failedUploadsRemainInTheDraftForRetry() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fileURL = temporaryDirectory.appending(path: "brief.txt")
        try Data("launch notes".utf8).write(to: fileURL)
        let token = "failed-\(UUID().uuidString)"
        let client = composerUploadClient(token: token) { request in
            switch (request.url?.host, request.url?.path) {
            case ("slack.com", "/api/files.getUploadURLExternal"):
                return try composerResponse(
                    for: request,
                    json: """
                    {
                      "ok": true,
                      "upload_url": "https://uploads.example.test/\(token)",
                      "file_id": "F1"
                    }
                    """
                )
            case ("uploads.example.test", _):
                return try composerResponse(for: request, json: "{}")
            case ("slack.com", "/api/files.completeUploadExternal"):
                return try composerResponse(
                    for: request,
                    json: #"{"ok":false,"error":"missing_scope"}"#
                )
            default:
                throw ComposerUploadStubError.unexpectedRequest
            }
        }
        defer { ComposerUploadURLProtocol.unregister(token: token) }
        let store = AppStore(
            conversations: [conversation(id: "C1")],
            connectionState: .connected("Acme"),
            slackAPI: client,
            credentials: credentials(token: token)
        )
        store.select("C1")
        let draft = ComposerDraft(text: "Keep this caption")
        store.composerDraft = draft
        store.addComposerAttachments([fileURL], to: "C1")

        await store.uploadPendingAttachments(
            for: "C1",
            initialComment: draft.slackText,
            draftToClear: draft
        )

        let state = store.attachmentDraftState(for: "C1")
        #expect(state.attachments.count == 1)
        #expect(state.errorMessage?.contains("missing_scope") == true)
        #expect(store.composerDraft == draft)
        guard case .failed = state.attachments[0].uploadState else {
            Issue.record("Expected the failed attachment to remain retryable")
            return
        }
    }

    private func conversation(id: String) -> Conversation {
        Conversation(
            id: id,
            title: id,
            kind: .channel,
            subtitle: nil,
            isFavorite: false,
            unreadCount: 0,
            mentionCount: 0,
            latestActivity: .now,
            messages: []
        )
    }

    private func credentials(token: String) -> SlackCredentials {
        SlackCredentials(
            accessToken: token,
            refreshToken: "refresh",
            expiresAt: .now.addingTimeInterval(3_600),
            teamID: "T1",
            teamName: "Acme",
            userID: "U1"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MiniSlackComposerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private var tinyPNG: Data {
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
    }
}

private typealias ComposerUploadHandler =
    @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

private enum ComposerUploadStubError: Error {
    case missingHandler
    case unexpectedRequest
}

private final class ComposerUploadRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: ComposerUploadHandler] = [:]

    func register(token: String, handler: @escaping ComposerUploadHandler) {
        lock.lock()
        handlers[token] = handler
        lock.unlock()
    }

    func unregister(token: String) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    func handler(for request: URLRequest) -> ComposerUploadHandler? {
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let token = authorization.hasPrefix("Bearer ")
            ? String(authorization.dropFirst(7))
            : request.url?.lastPathComponent ?? ""
        lock.lock()
        let handler = handlers[token]
        lock.unlock()
        return handler
    }
}

private final class ComposerUploadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = ComposerUploadRegistry()

    static func register(
        token: String,
        handler: @escaping ComposerUploadHandler
    ) {
        registry.register(token: token, handler: handler)
    }

    static func unregister(token: String) {
        registry.unregister(token: token)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "slack.com"
            || request.url?.host == "uploads.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.registry.handler(for: request) else {
            client?.urlProtocol(
                self,
                didFailWithError: ComposerUploadStubError.missingHandler
            )
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ComposerUploadRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var values: [URLRequest] {
        lock.lock()
        let values = requests
        lock.unlock()
        return values
    }

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}

private func composerUploadClient(
    token: String,
    handler: @escaping ComposerUploadHandler
) -> SlackAPIClient {
    ComposerUploadURLProtocol.register(token: token, handler: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ComposerUploadURLProtocol.self]
    return SlackAPIClient(urlSession: URLSession(configuration: configuration))
}

private func composerResponse(
    for request: URLRequest,
    statusCode: Int = 200,
    json: String
) throws -> (HTTPURLResponse, Data) {
    guard let url = request.url,
          let response = HTTPURLResponse(
              url: url,
              statusCode: statusCode,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/json"]
          )
    else {
        throw ComposerUploadStubError.unexpectedRequest
    }
    return (response, Data(json.utf8))
}

private func materializedRequest(_ request: URLRequest) throws -> URLRequest {
    guard request.httpBody == nil, let stream = request.httpBodyStream else {
        return request
    }
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else {
            throw ComposerUploadStubError.unexpectedRequest
        }
        guard count > 0 else {
            break
        }
        body.append(buffer, count: count)
    }
    var request = request
    request.httpBodyStream = nil
    request.httpBody = body
    return request
}
