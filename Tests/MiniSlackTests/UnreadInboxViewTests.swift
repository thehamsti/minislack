import AppKit
import SwiftUI
import Testing
@testable import MiniSlack

@MainActor
struct UnreadInboxViewTests {
    @Test
    func emptyInboxFillsItsProposedPane() throws {
        let renderer = ImageRenderer(
            content: UnreadInboxView(
                store: AppStore(conversations: []),
                windowState: WindowState(),
                compact: true
            )
        )
        renderer.proposedSize = ProposedViewSize(width: 420, height: 500)
        renderer.scale = 1

        let image = try #require(renderer.nsImage)

        #expect(image.size == NSSize(width: 420, height: 500))
    }
}
