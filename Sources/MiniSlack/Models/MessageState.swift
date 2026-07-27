import Foundation

enum MessageDeliveryState: Codable, Hashable, Sendable {
    case received
    case sending
    case sent
    case failed(String)
}

struct MessageThreadMetadata: Codable, Hashable, Sendable {
    let rootTimestamp: String
    var replyCount: Int
    var replyUserIDs: [String]
    var latestReplyAt: Date?
    var isFollowing: Bool
}
