import Foundation

enum HistoryBackfillSpeed: String, CaseIterable, Identifiable, Sendable {
    case off
    case slow
    case balanced
    case fast

    static let defaultsKey = "historyBackfillSpeed"

    var id: Self { self }

    var title: String {
        switch self {
        case .off:
            "Off"
        case .slow:
            "Slow"
        case .balanced:
            "Balanced"
        case .fast:
            "Fast"
        }
    }

    var detail: String {
        switch self {
        case .off:
            "Only load history when you open or scroll a conversation."
        case .slow:
            "About 1 history request per minute."
        case .balanced:
            "About 6 history requests per minute."
        case .fast:
            "About 30 history requests per minute."
        }
    }

    var requestInterval: Duration? {
        switch self {
        case .off:
            nil
        case .slow:
            .seconds(60)
        case .balanced:
            .seconds(10)
        case .fast:
            .seconds(2)
        }
    }

    static var current: Self {
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey)
        return rawValue.flatMap(Self.init(rawValue:)) ?? .slow
    }
}
