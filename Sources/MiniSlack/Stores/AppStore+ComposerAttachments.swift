import Foundation

extension AppStore {
    static let maximumComposerAttachmentCount = 10

    var composerAttachmentDraftState: ComposerAttachmentDraftState {
        guard case let .conversation(conversationID) = destination else {
            return ComposerAttachmentDraftState()
        }
        return attachmentDraftState(for: conversationID)
    }

    func attachmentDraftState(
        for conversationID: String
    ) -> ComposerAttachmentDraftState {
        attachmentDraftsByConversationID[conversationID]
            ?? ComposerAttachmentDraftState()
    }

    func addComposerAttachments(
        _ fileURLs: [URL],
        to conversationID: String
    ) {
        addComposerAttachments(
            fileURLs.map { ($0, $0.lastPathComponent, false) },
            to: conversationID
        )
    }

    func addComposerPasteboardAttachments(
        _ attachments: [ComposerPasteboardAttachment],
        to conversationID: String
    ) {
        for attachment in attachments {
            switch attachment {
            case let .fileURLs(urls):
                addComposerAttachments(urls, to: conversationID)
            case let .image(data, suggestedFilename):
                Task { @MainActor in
                    do {
                        let url = try await ComposerAttachmentFileService.shared
                            .storePastedImage(data)
                        addComposerAttachments(
                            [(url, suggestedFilename, true)],
                            to: conversationID
                        )
                    } catch {
                        setComposerAttachmentError(
                            error.localizedDescription,
                            for: conversationID
                        )
                    }
                }
            }
        }
    }

    func removeComposerAttachment(
        _ attachmentID: UUID,
        from conversationID: String
    ) {
        guard var state = attachmentDraftsByConversationID[conversationID],
              let attachment = state.attachments.first(where: {
                  $0.id == attachmentID
              }),
              attachment.uploadState != .uploading
        else {
            return
        }
        state.attachments.removeAll { $0.id == attachmentID }
        state.errorMessage = nil
        setAttachmentDraftState(state, for: conversationID)
        if attachment.isTemporary {
            Task {
                await ComposerAttachmentFileService.shared
                    .removeTemporaryFile(at: attachment.fileURL)
            }
        }
    }

    func dismissComposerAttachmentError(for conversationID: String) {
        guard var state = attachmentDraftsByConversationID[conversationID] else {
            return
        }
        state.errorMessage = nil
        setAttachmentDraftState(state, for: conversationID)
    }

    func sendComposerDraft() {
        guard case let .conversation(conversationID) = destination else {
            return
        }
        let activeDraft = composerDraft
        let hasText = !activeDraft.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let state = attachmentDraftState(for: conversationID)
        guard hasText || !state.attachments.isEmpty,
              !state.isUploading
        else {
            return
        }

        guard !state.attachments.isEmpty else {
            sendDraft()
            return
        }
        guard slackAPI != nil else {
            sendPreviewComposerDraft(
                activeDraft,
                attachments: state.attachments,
                conversationID: conversationID
            )
            return
        }

        let attachments = prepareAttachmentsForUpload(
            conversationID: conversationID
        )
        let initialComment = hasText
            ? activeDraft.slackText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        startWorkspaceOperation { [weak self] session in
            await self?.uploadPreparedAttachments(
                attachments,
                conversationID: conversationID,
                initialComment: initialComment,
                draftToClear: hasText ? activeDraft : nil,
                session: session
            )
        }
    }

    func uploadPendingAttachments(
        for conversationID: String,
        initialComment: String? = nil,
        draftToClear: ComposerDraft? = nil
    ) async {
        guard let session = try? captureWorkspaceSession() else {
            return
        }
        let attachments = prepareAttachmentsForUpload(
            conversationID: conversationID
        )
        await uploadPreparedAttachments(
            attachments,
            conversationID: conversationID,
            initialComment: initialComment,
            draftToClear: draftToClear,
            session: session
        )
    }

    private func addComposerAttachments(
        _ values: [(url: URL, filename: String, isTemporary: Bool)],
        to conversationID: String
    ) {
        guard conversations.contains(where: { $0.id == conversationID }) else {
            setComposerAttachmentError(
                ComposerAttachmentError.noConversation.localizedDescription,
                for: conversationID
            )
            return
        }
        var state = attachmentDraftState(for: conversationID)
        state.errorMessage = nil
        let existingURLs = Set(state.attachments.map(\.fileURL))
        let uniqueValues = values.filter {
            !existingURLs.contains($0.url.standardizedFileURL)
        }
        let remainingCount = max(
            0,
            Self.maximumComposerAttachmentCount - state.attachments.count
        )

        for value in uniqueValues.prefix(remainingCount) {
            do {
                state.attachments.append(
                    try ComposerPendingAttachment(
                        fileURL: value.url,
                        filename: value.filename,
                        isTemporary: value.isTemporary
                    )
                )
            } catch {
                state.errorMessage = error.localizedDescription
                if value.isTemporary {
                    Task {
                        await ComposerAttachmentFileService.shared
                            .removeTemporaryFile(at: value.url)
                    }
                }
            }
        }
        if uniqueValues.count > remainingCount {
            for value in uniqueValues.dropFirst(remainingCount)
            where value.isTemporary {
                Task {
                    await ComposerAttachmentFileService.shared
                        .removeTemporaryFile(at: value.url)
                }
            }
            state.errorMessage = ComposerAttachmentError.tooManyAttachments(
                maximum: Self.maximumComposerAttachmentCount
            ).localizedDescription
        }
        setAttachmentDraftState(state, for: conversationID)
    }

    private func prepareAttachmentsForUpload(
        conversationID: String
    ) -> [ComposerPendingAttachment] {
        var state = attachmentDraftState(for: conversationID)
        guard !state.attachments.isEmpty, !state.isUploading else {
            return []
        }
        state.errorMessage = nil
        state.attachments = state.attachments.map { attachment in
            var attachment = attachment
            attachment.uploadState = .uploading
            return attachment
        }
        let attachments = state.attachments
        state.progress = ComposerAttachmentUploadProgress(
            completedCount: 0,
            totalCount: attachments.count,
            filename: attachments[0].filename
        )
        attachmentDraftsByConversationID[conversationID] = state
        return attachments
    }

    private func uploadPreparedAttachments(
        _ attachments: [ComposerPendingAttachment],
        conversationID: String,
        initialComment: String?,
        draftToClear: ComposerDraft?,
        session: WorkspaceSession
    ) async {
        guard !attachments.isEmpty,
              isCurrentWorkspaceSession(session),
              let slackAPI
        else {
            return
        }

        let credentials: SlackCredentials
        do {
            credentials = try await activeCredentials(for: session)
        } catch {
            guard isCurrentWorkspaceSession(session) else {
                return
            }
            failComposerAttachments(
                attachments,
                error: error,
                conversationID: conversationID
            )
            return
        }

        var didUpload = false
        for (index, attachment) in attachments.enumerated() {
            guard isCurrentWorkspaceSession(session), !Task.isCancelled else {
                return
            }
            updateComposerUploadProgress(
                index: index,
                attachment: attachment,
                totalCount: attachments.count,
                conversationID: conversationID
            )
            do {
                _ = try await slackAPI.uploadFile(
                    fileURL: attachment.fileURL,
                    filename: attachment.filename,
                    title: URL(fileURLWithPath: attachment.filename)
                        .deletingPathExtension()
                        .lastPathComponent,
                    channelID: conversationID,
                    initialComment: index == 0 ? initialComment : nil,
                    accessToken: credentials.accessToken
                )
                try requireCurrentWorkspaceSession(session)
                if index == 0, let draftToClear {
                    clearComposerDraft(
                        draftToClear,
                        for: conversationID
                    )
                }
                didUpload = true
                removeUploadedAttachment(
                    attachment,
                    conversationID: conversationID
                )
                if attachment.isTemporary {
                    await ComposerAttachmentFileService.shared
                        .removeTemporaryFile(at: attachment.fileURL)
                    try requireCurrentWorkspaceSession(session)
                }
            } catch {
                guard isCurrentWorkspaceSession(session) else {
                    return
                }
                markComposerAttachmentFailed(
                    attachment.id,
                    error: error,
                    conversationID: conversationID
                )
            }
        }

        guard isCurrentWorkspaceSession(session) else {
            return
        }
        if var state = attachmentDraftsByConversationID[conversationID] {
            state.progress = nil
            setAttachmentDraftState(state, for: conversationID)
        }
        if didUpload {
            await loadInitialHistory(for: conversationID)
        }
    }

    private func sendPreviewComposerDraft(
        _ draft: ComposerDraft,
        attachments: [ComposerPendingAttachment],
        conversationID: String
    ) {
        guard let index = conversations.firstIndex(where: {
            $0.id == conversationID
        }) else {
            return
        }
        let displayText = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingText = draft.slackText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let author = currentUser
        let message = Message(
            author: author?.displayName ?? "You",
            authorUserID: author?.id,
            body: outgoingText,
            timestamp: .now,
            authorAvatarURL: author?.avatarURL,
            isCurrentUser: true,
            displayBody: SlackEmoji.replacingUnicodeShortcodes(in: displayText),
            files: attachments.map(\.previewMessageFile),
            deliveryState: .sent
        )
        conversations[index].messages.append(message)
        conversations[index].latestActivity = message.timestamp
        workspaceSearchIndex.merge(
            messages: [message],
            conversation: conversations[index]
        )
        composerDraft = ComposerDraft()
        attachmentDraftsByConversationID[conversationID] = nil
    }

    private func updateComposerUploadProgress(
        index: Int,
        attachment: ComposerPendingAttachment,
        totalCount: Int,
        conversationID: String
    ) {
        guard var state = attachmentDraftsByConversationID[conversationID] else {
            return
        }
        state.progress = ComposerAttachmentUploadProgress(
            completedCount: index,
            totalCount: totalCount,
            filename: attachment.filename
        )
        attachmentDraftsByConversationID[conversationID] = state
    }

    private func removeUploadedAttachment(
        _ attachment: ComposerPendingAttachment,
        conversationID: String
    ) {
        guard var state = attachmentDraftsByConversationID[conversationID] else {
            return
        }
        state.attachments.removeAll { $0.id == attachment.id }
        attachmentDraftsByConversationID[conversationID] = state
    }

    private func markComposerAttachmentFailed(
        _ attachmentID: UUID,
        error: Error,
        conversationID: String
    ) {
        guard var state = attachmentDraftsByConversationID[conversationID],
              let index = state.attachments.firstIndex(where: {
                  $0.id == attachmentID
              })
        else {
            return
        }
        state.attachments[index].uploadState = .failed(
            error.localizedDescription
        )
        state.errorMessage =
            "\(state.attachments[index].filename): \(error.localizedDescription)"
        attachmentDraftsByConversationID[conversationID] = state
    }

    private func failComposerAttachments(
        _ attachments: [ComposerPendingAttachment],
        error: Error,
        conversationID: String
    ) {
        var state = attachmentDraftState(for: conversationID)
        let attachmentIDs = Set(attachments.map(\.id))
        state.attachments = state.attachments.map { attachment in
            guard attachmentIDs.contains(attachment.id) else {
                return attachment
            }
            var attachment = attachment
            attachment.uploadState = .failed(error.localizedDescription)
            return attachment
        }
        state.progress = nil
        state.errorMessage = error.localizedDescription
        setAttachmentDraftState(state, for: conversationID)
    }

    private func setComposerAttachmentError(
        _ message: String,
        for conversationID: String
    ) {
        var state = attachmentDraftState(for: conversationID)
        state.errorMessage = message
        attachmentDraftsByConversationID[conversationID] = state
    }

    private func setAttachmentDraftState(
        _ state: ComposerAttachmentDraftState,
        for conversationID: String
    ) {
        if state.isEmpty {
            attachmentDraftsByConversationID[conversationID] = nil
        } else {
            attachmentDraftsByConversationID[conversationID] = state
        }
    }
}

private extension ComposerPendingAttachment {
    var previewMessageFile: MessageFile {
        let source = MessageMediaSource(
            url: fileURL,
            requiresSlackAuthorization: false
        )
        return MessageFile(
            id: "preview-\(id.uuidString)",
            name: filename,
            title: filename,
            mimeType: mimeType,
            prettyType: nil,
            size: byteCount.flatMap(Int.init(exactly:)),
            mode: "local",
            contentSource: source,
            thumbnailSource: kind == .image ? source : nil,
            permalink: nil,
            previewText: nil,
            altText: kind == .image ? filename : nil,
            originalWidth: nil,
            originalHeight: nil
        )
    }
}
