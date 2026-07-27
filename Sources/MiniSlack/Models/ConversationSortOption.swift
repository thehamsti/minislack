import Foundation

enum ConversationSortOption: String, CaseIterable, Identifiable, Sendable {
    case activity
    case name
    case creation

    var id: Self { self }

    var title: String {
        switch self {
        case .activity:
            "Activity"
        case .name:
            "Name"
        case .creation:
            "Creation"
        }
    }

    var systemImage: String {
        switch self {
        case .activity:
            "clock"
        case .name:
            "textformat"
        case .creation:
            "calendar"
        }
    }
}
