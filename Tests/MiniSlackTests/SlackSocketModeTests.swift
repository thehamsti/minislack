import Foundation
import Testing
@testable import MiniSlack

struct SlackSocketModeTests {
    @Test
    func recognizesSocketHello() throws {
        let envelope = try decode(
            """
            {
              "type": "hello",
              "connection_info": { "app_id": "A1" }
            }
            """
        )

        #expect(envelope.type == "hello")
        #expect(envelope.event == nil)
    }

    @Test
    func decodesNewMessageEnvelope() throws {
        let envelope = try decode(
            """
            {
              "type": "events_api",
              "envelope_id": "env-1",
              "payload": {
                "team_id": "T1",
                "event": {
                  "type": "message",
                  "channel": "C1",
                  "user": "U2",
                  "text": "hello",
                  "ts": "123.456"
                }
              }
            }
            """
        )

        guard case let .message(teamID, channelID, message) = envelope.event else {
            Issue.record("Expected a message event")
            return
        }
        #expect(envelope.envelopeID == "env-1")
        #expect(teamID == "T1")
        #expect(channelID == "C1")
        #expect(message.timestamp == "123.456")
        #expect(message.text == "hello")
    }

    @Test
    func decodesChangedMessageFromNestedPayload() throws {
        let envelope = try decode(
            """
            {
              "type": "events_api",
              "envelope_id": "env-2",
              "payload": {
                "team_id": "T1",
                "event": {
                  "type": "message",
                  "subtype": "message_changed",
                  "channel": "C1",
                  "message": {
                    "type": "message",
                    "user": "U2",
                    "text": "edited",
                    "ts": "123.456"
                  }
                }
              }
            }
            """
        )

        guard case let .message(_, _, message) = envelope.event else {
            Issue.record("Expected a message event")
            return
        }
        #expect(message.timestamp == "123.456")
        #expect(message.text == "edited")
    }

    @Test
    func decodesDeletedMessageTimestamp() throws {
        let envelope = try decode(
            """
            {
              "type": "events_api",
              "envelope_id": "env-3",
              "payload": {
                "team_id": "T1",
                "event": {
                  "type": "message",
                  "subtype": "message_deleted",
                  "channel": "C1",
                  "deleted_ts": "123.456",
                  "ts": "124.000"
                }
              }
            }
            """
        )

        guard case let .messageDeleted(teamID, channelID, timestamp) = envelope.event else {
            Issue.record("Expected a message deletion")
            return
        }
        #expect(teamID == "T1")
        #expect(channelID == "C1")
        #expect(timestamp == "123.456")
    }

    @Test
    func manifestEnablesSocketModeAndAllMessageSurfaces() {
        #expect(SlackAppManifest.contents.contains("socket_mode_enabled: true"))
        #expect(SlackAppManifest.contents.contains("message.channels"))
        #expect(SlackAppManifest.contents.contains("message.groups"))
        #expect(SlackAppManifest.contents.contains("message.im"))
        #expect(SlackAppManifest.contents.contains("message.mpim"))
    }

    private func decode(_ json: String) throws -> SlackSocketModeEnvelope {
        try JSONDecoder().decode(
            SlackSocketModeEnvelope.self,
            from: Data(json.utf8)
        )
    }
}
