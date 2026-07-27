import AppKit
import Foundation
import UniformTypeIdentifiers

enum SlackAppManifest {
    static let contents = """
        display_information:
          name: Mini Slack
          description: A compact, keyboard-first Slack client for macOS
          background_color: "#D95F20"

        oauth_config:
          pkce_enabled: true
          redirect_urls:
            - minislack://oauth/slack
          scopes:
            user:
              - channels:history
              - channels:read
              - channels:write
              - chat:write
              - dnd:read
              - dnd:write
              - emoji:read
              - files:read
              - files:write
              - groups:history
              - groups:read
              - groups:write
              - im:history
              - im:read
              - im:write
              - mpim:history
              - mpim:read
              - mpim:write
              - reactions:read
              - reactions:write
              - pins:write
              - reminders:write
              - search:read
              - users:read
              - users:write
              - users.profile:write

        settings:
          event_subscriptions:
            user_events:
              - message.channels
              - message.groups
              - message.im
              - message.mpim
          org_deploy_enabled: false
          socket_mode_enabled: true
          token_rotation_enabled: true
        """

    @MainActor
    static func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contents, forType: .string)
    }

    @MainActor
    static func export() throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mini-slack-manifest.yml"
        panel.allowedContentTypes = [.yaml]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
