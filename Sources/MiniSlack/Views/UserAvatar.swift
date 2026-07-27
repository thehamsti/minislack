import SwiftUI

struct UserAvatar: View {
    let imageURL: URL?
    let initials: String
    let accessibilityName: String
    var size: CGFloat = 34
    var isActive: Bool? = nil
    var isCurrentUser = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
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

            if let isActive {
                Circle()
                    .fill(isActive ? .green : .secondary)
                    .frame(width: max(7, size * 0.28), height: max(7, size * 0.28))
                    .overlay {
                        Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Profile picture for \(accessibilityName)")
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
}
