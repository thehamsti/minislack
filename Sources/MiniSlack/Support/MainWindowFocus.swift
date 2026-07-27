import AppKit
import SwiftUI

enum MainWindowFocus {
    static let identifier = NSUserInterfaceItemIdentifier("MiniSlackMainWindow")

    @MainActor
    static var isFocused: Bool {
        NSApp.isActive && NSApp.keyWindow?.identifier == identifier
    }
}

struct MainWindowIdentityView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MainWindowIdentityNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class MainWindowIdentityNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = MainWindowFocus.identifier
    }
}
