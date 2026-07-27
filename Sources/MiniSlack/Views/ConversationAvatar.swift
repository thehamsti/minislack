import SwiftUI

struct ConversationAvatar: View {
    let store: AppStore
    let conversation: Conversation
    var size: CGFloat

    var body: some View {
        Group {
            if conversation.kind == .groupDirectMessage {
                groupAvatar
            } else if let participant = directParticipant {
                UserAvatar(
                    imageURL: participant.avatarURL,
                    initials: participant.initials,
                    accessibilityName: participant.displayName,
                    size: size,
                    availability: participant.availability
                )
            } else {
                UserAvatar(
                    imageURL: conversation.avatarURL,
                    initials: conversation.initials,
                    accessibilityName: conversation.title,
                    size: size,
                    availability: UserAvailability()
                )
            }
        }
        .accessibilityElement(children: .contain)
        .help(availabilityHelp)
    }

    @ViewBuilder
    private var groupAvatar: some View {
        let members = Array(resolvedParticipants.prefix(2))
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
                        size: size * 0.72,
                        availability: member.availability
                    )
                }
            }
            .frame(width: size, height: size)
        }
    }

    private var directParticipant: WorkspaceUser? {
        if let userID = conversation.participantUserID,
           let user = store.user(withID: userID)
        {
            return user
        }
        guard let participant = conversation.participants.first else {
            return nil
        }
        return store.user(withID: participant.id) ?? participant
    }

    private var resolvedParticipants: [WorkspaceUser] {
        conversation.participants.map {
            store.user(withID: $0.id) ?? $0
        }
    }

    private var availabilityHelp: String {
        let now = Date.now
        let participants = conversation.kind == .groupDirectMessage
            ? resolvedParticipants
            : directParticipant.map { [$0] } ?? []
        guard !participants.isEmpty else {
            return conversation.title
        }
        return participants
            .map {
                "\($0.displayName): \($0.availability.accessibilityLabel(at: now))"
            }
            .joined(separator: "\n")
    }
}
