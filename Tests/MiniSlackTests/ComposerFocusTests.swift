import AppKit
import Testing
@testable import MiniSlack

@MainActor
struct ComposerFocusTests {
    @Test
    func pendingFocusRequestAppliesWhenComposerJoinsAWindow() {
        let textView = ComposerNSTextView()
        textView.requestFocus()

        let window = NSWindow()
        window.contentView = textView

        #expect(window.firstResponder === textView)
    }
}
