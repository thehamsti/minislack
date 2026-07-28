import SwiftUI

extension View {
    func conversationAttachmentDrop(store: AppStore) -> some View {
        modifier(ConversationAttachmentDropModifier(store: store))
    }
}

private struct ConversationAttachmentDropModifier: ViewModifier {
    let store: AppStore
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        let conversation = store.selectedConversation

        content
            .onDrop(
                of: ComposerDropReader.supportedContentTypes,
                isTargeted: $isTargeted
            ) { providers in
                guard let conversationID = conversation?.id else {
                    return false
                }
                Task { @MainActor in
                    let attachments = await ComposerDropReader.attachments(
                        from: providers
                    )
                    guard !attachments.isEmpty else {
                        return
                    }
                    store.addComposerPasteboardAttachments(
                        attachments,
                        to: conversationID
                    )
                }
                return true
            }
            .overlay {
                if isTargeted, let conversation {
                    ConversationDropIndicator(conversation: conversation)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}

private struct ConversationDropIndicator: View {
    let conversation: Conversation

    var body: some View {
        ZStack {
            Color.black.opacity(0.14)

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.orange)
                Text("Drop to attach")
                    .font(.headline)
                Text("Adds to your message in \(destinationTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.separator.opacity(0.7), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
            .padding(20)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop to attach files to \(destinationTitle)")
    }

    private var destinationTitle: String {
        let prefix = conversation.kind == .channel ? "#" : ""
        return "\(prefix)\(conversation.title)"
    }
}
