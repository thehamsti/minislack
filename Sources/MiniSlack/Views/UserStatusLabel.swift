import EmojiText
import Foundation
import SwiftUI

struct UserStatusLabel: View {
    let user: WorkspaceUser
    let customEmojiURLs: [String: URL]

    var body: some View {
        let now = Date.now
        let availability = user.availability
        let showsPresence = availability.presence != .notApplicable
        let showsDoNotDisturb = availability.isDoNotDisturbActive(at: now)
        let customStatus = availability.activeCustomStatus(at: now)
            .flatMap(customStatusText)

        HStack(spacing: 4) {
            if showsPresence {
                UserPresenceIndicator(presence: availability.presence, size: 7)
                Text(availability.presence.displayText)
            }

            if showsDoNotDisturb {
                if showsPresence {
                    separator
                }
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
                Text("DND")
            }

            if let customStatus {
                if showsPresence || showsDoNotDisturb {
                    separator
                }
                UserCustomStatusText(
                    text: customStatus,
                    customEmojiURLs: customEmojiURLs
                )
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(user.displayName), \(availability.accessibilityLabel(at: now))"
        )
        .help("\(user.displayName): \(availability.accessibilityLabel(at: now))")
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(.tertiary)
    }

    private func customStatusText(_ status: UserCustomStatus) -> String? {
        let text = status.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji = status.emoji?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let emoji, !emoji.isEmpty, !text.isEmpty {
            return "\(emoji) \(text)"
        }
        if let emoji, !emoji.isEmpty {
            return emoji
        }
        return text.isEmpty ? nil : text
    }
}

private struct UserCustomStatusText: View {
    let text: String
    let customEmojiURLs: [String: URL]

    var body: some View {
        let renderedText = SlackEmoji.replacingUnicodeShortcodes(in: text)
        let customEmoji = Set(SlackEmoji.shortcodeNames(in: renderedText)).compactMap { name in
            customEmojiURLs[name].map { RemoteEmoji(shortcode: name, url: $0) }
        }
        EmojiText(verbatim: renderedText, emojis: customEmoji)
    }
}
