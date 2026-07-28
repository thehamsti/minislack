import SwiftUI

struct ActivityInboxView: View {
    let store: AppStore
    let windowState: WindowState
    let compact: Bool
    @State private var filter: ActivityKind?

    var body: some View {
        let items = filter.map { selected in
            store.activityItems.filter { $0.kind == selected }
        } ?? store.activityItems

        VStack(spacing: 0) {
            header
            filterBar
            if items.isEmpty {
                ContentUnavailableView(
                    filter == nil ? "No activity yet" : "No \(filter?.title.lowercased() ?? "activity")",
                    systemImage: filter?.systemImage ?? "bell",
                    description: Text(
                        "Mentions, reactions on your messages, and followed thread replies appear here."
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            Button {
                                store.openActivity(item, windowState: windowState)
                            } label: {
                                ActivityRow(store: store, item: item)
                            }
                            .buttonStyle(.plain)
                            Divider()
                                .padding(.leading, 50)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            store.markActivityRead()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            if compact {
                Button(action: store.showUnreadInbox) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)

                CompactSidebarButton(windowState: windowState)
            }
            Image(systemName: "bell.fill")
                .foregroundStyle(.orange)
            Text("Activity")
                .font(.headline)
            Spacer()
            Text(store.activityItems.count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, compact ? 12 : 16)
        .frame(height: 50)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                filterButton("All", kind: nil)
                ForEach(ActivityKind.allCases) { kind in
                    filterButton(kind.title, kind: kind)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func filterButton(_ title: String, kind: ActivityKind?) -> some View {
        Button(title) {
            filter = kind
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(filter == kind ? .orange : .secondary)
    }
}

private struct ActivityRow: View {
    let store: AppStore
    let item: ActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let userID = item.actorUserIDs.first,
               let user = store.user(withID: userID)
            {
                UserAvatar(
                    imageURL: user.avatarURL,
                    initials: user.initials,
                    accessibilityName: user.displayName,
                    size: 28,
                    availability: user.availability
                )
            } else {
                Image(systemName: item.kind.systemImage)
                    .foregroundStyle(.orange)
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(item.date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                SlackEmojiText(
                    text: item.detail,
                    customEmojiURLs: store.customEmojiURLs
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                Text("#\(item.conversationTitle)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}
