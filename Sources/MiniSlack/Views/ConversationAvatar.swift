import SwiftUI

struct ConversationAvatar: View {
    let conversation: Conversation
    var size: CGFloat

    var body: some View {
        Group {
            if conversation.kind == .groupDirectMessage {
                groupAvatar
            } else if let participant = conversation.participants.first {
                UserAvatar(
                    imageURL: participant.avatarURL,
                    initials: participant.initials,
                    accessibilityName: participant.displayName,
                    size: size
                )
            } else {
                UserAvatar(
                    imageURL: conversation.avatarURL,
                    initials: conversation.initials,
                    accessibilityName: conversation.title,
                    size: size
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Conversation with \(conversation.title)")
    }

    @ViewBuilder
    private var groupAvatar: some View {
        let members = Array(conversation.participants.prefix(2))
        if members.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24)
                    .fill(Color.accentColor.opacity(0.18).gradient)
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
        } else {
            HStack(spacing: -(size * 0.34)) {
                ForEach(members) { member in
                    UserAvatar(
                        imageURL: member.avatarURL,
                        initials: member.initials,
                        accessibilityName: member.displayName,
                        size: size * 0.72
                    )
                }
            }
            .frame(width: size, height: size)
        }
    }
}
