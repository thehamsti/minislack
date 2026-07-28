import Foundation
import Testing

struct QuickSwitcherViewTests {
    @Test
    func pointerHoverDoesNotDriveSelectionOrScrolling() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appending(path: "Sources/MiniSlack/Views/QuickSwitcherView.swift"),
            encoding: .utf8
        )

        #expect(!source.contains(".onHover"))
        #expect(source.contains(".scrollIndicators(.visible)"))
    }
}
