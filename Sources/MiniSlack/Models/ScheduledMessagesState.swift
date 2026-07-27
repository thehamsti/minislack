import Foundation

struct ScheduledMessagesState: Equatable, Sendable {
    var messages: [SlackScheduledMessage] = []
    var isLoading = false
    var hasLoaded = false
    var errorMessage: String?
}

enum ScheduledMessageError: LocalizedError, Equatable {
    case emptyMessage
    case missingConversation
    case invalidDate
    case messageNotFound

    var errorDescription: String? {
        switch self {
        case .emptyMessage:
            "Write a message before scheduling it."
        case .missingConversation:
            "Choose a conversation before scheduling a message."
        case .invalidDate:
            "Choose a time between one minute and 120 days from now."
        case .messageNotFound:
            "That scheduled message is no longer available."
        }
    }
}

enum ScheduledMessagePreset: String, CaseIterable, Identifiable, Sendable {
    case laterToday
    case tomorrowMorning
    case nextMonday

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .laterToday:
            "Later today"
        case .tomorrowMorning:
            "Tomorrow morning"
        case .nextMonday:
            "Next Monday"
        }
    }

    var systemImage: String {
        switch self {
        case .laterToday:
            "sun.max"
        case .tomorrowMorning:
            "sunrise"
        case .nextMonday:
            "calendar"
        }
    }

    func date(
        relativeTo now: Date = .now,
        calendar: Calendar = .current
    ) -> Date {
        switch self {
        case .laterToday:
            let threePM = calendar.date(
                bySettingHour: 15,
                minute: 0,
                second: 0,
                of: now
            ) ?? now.addingTimeInterval(7_200)
            return threePM.timeIntervalSince(now) >= 60
                ? threePM
                : now.addingTimeInterval(7_200)
        case .tomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(
                bySettingHour: 9,
                minute: 0,
                second: 0,
                of: tomorrow
            ) ?? now.addingTimeInterval(86_400)
        case .nextMonday:
            var components = DateComponents()
            components.weekday = 2
            components.hour = 9
            return calendar.nextDate(
                after: now,
                matching: components,
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(604_800)
        }
    }
}
