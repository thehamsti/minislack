import Foundation
import SwiftUI

struct UserAvatar: View {
    let imageURL: URL?
    let initials: String
    let accessibilityName: String
    let size: CGFloat
    let availability: UserAvailability?
    let isCurrentUser: Bool

    init(
        imageURL: URL?,
        initials: String,
        accessibilityName: String,
        size: CGFloat = 34,
        availability: UserAvailability? = nil,
        isCurrentUser: Bool = false
    ) {
        self.imageURL = imageURL
        self.initials = initials
        self.accessibilityName = accessibilityName
        self.size = size
        self.availability = availability
        self.isCurrentUser = isCurrentUser
    }

    init(
        imageURL: URL?,
        initials: String,
        accessibilityName: String,
        size: CGFloat = 34,
        isActive: Bool?,
        isCurrentUser: Bool = false
    ) {
        self.init(
            imageURL: imageURL,
            initials: initials,
            accessibilityName: accessibilityName,
            size: size,
            availability: isActive.map {
                UserAvailability(presence: $0 ? .active : .away)
            },
            isCurrentUser: isCurrentUser
        )
    }

    var body: some View {
        let now = Date.now

        AsyncImage(url: imageURL, transaction: Transaction(animation: .easeOut(duration: 0.15))) { phase in
            if case let .success(image) = phase {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
        .overlay(alignment: .bottomTrailing) {
            if let availability, availability.presence != .notApplicable {
                let badgeSize = max(7, size * 0.28)
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: badgeSize, height: badgeSize)
                    .overlay {
                        UserPresenceIndicator(
                            presence: availability.presence,
                            size: badgeSize - 2.5
                        )
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if availability?.isDoNotDisturbActive(at: now) == true {
                UserDoNotDisturbIndicator(size: max(7, size * 0.28))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(at: now))
        .help(helpText(at: now))
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(isCurrentUser ? Color.orange.gradient : Color.accentColor.opacity(0.18).gradient)
            Text(initials)
                .font(.system(size: max(8, size * 0.32), weight: .bold))
                .foregroundStyle(isCurrentUser ? .white : .primary)
        }
    }

    private func accessibilityText(at date: Date) -> String {
        let profile = "Profile picture for \(accessibilityName)"
        guard let availability else {
            return profile
        }
        return "\(profile), \(availability.accessibilityLabel(at: date))"
    }

    private func helpText(at date: Date) -> String {
        guard let availability else {
            return accessibilityName
        }
        return "\(accessibilityName): \(availability.accessibilityLabel(at: date))"
    }
}

struct UserPresenceIndicator: View {
    let presence: UserPresence
    var size: CGFloat = 8

    @ViewBuilder
    var body: some View {
        switch presence {
        case .active:
            Circle()
                .fill(.green)
                .frame(width: size, height: size)
        case .away:
            Circle()
                .stroke(.orange, lineWidth: max(1.25, size * 0.18))
                .frame(width: size, height: size)
        case .offline:
            Circle()
                .fill(.secondary)
                .frame(width: size, height: size)
        case .unknown:
            Circle()
                .stroke(.secondary, lineWidth: max(1, size * 0.14))
                .frame(width: size, height: size)
        case .notApplicable:
            EmptyView()
        }
    }
}

struct UserDoNotDisturbIndicator: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Color(nsColor: .controlBackgroundColor))
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .fill(.red)
                    .padding(1.25)
            }
            .overlay {
                Capsule()
                    .fill(Color(nsColor: .alternateSelectedControlTextColor))
                    .frame(width: size * 0.42, height: max(1, size * 0.11))
            }
            .accessibilityHidden(true)
    }
}
