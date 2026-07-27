import Foundation

struct SavedMessage: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let conversationID: String
    let conversationTitle: String
    var message: Message
    let savedAt: Date

    init(
        conversationID: String,
        conversationTitle: String,
        message: Message,
        savedAt: Date = .now
    ) {
        id = Self.identifier(conversationID: conversationID, message: message)
        self.conversationID = conversationID
        self.conversationTitle = conversationTitle
        self.message = message
        self.savedAt = savedAt
    }

    static func identifier(conversationID: String, message: Message) -> String {
        let messageID = message.remoteID ?? message.id.uuidString
        return "\(conversationID):\(messageID)"
    }

    func matches(conversationID: String, message: Message) -> Bool {
        guard self.conversationID == conversationID else {
            return false
        }
        if self.message.id == message.id {
            return true
        }
        return self.message.remoteID != nil
            && self.message.remoteID == message.remoteID
    }

    func replacingMessage(_ message: Message) -> SavedMessage {
        SavedMessage(
            conversationID: conversationID,
            conversationTitle: conversationTitle,
            message: message,
            savedAt: savedAt
        )
    }
}
