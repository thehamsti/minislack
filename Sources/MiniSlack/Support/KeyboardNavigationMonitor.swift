import AppKit
import SwiftUI

struct KeyboardNavigationMonitor: NSViewRepresentable {
    let onAction: (KeyboardNavigationAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAction: onAction)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onAction = onAction
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var onAction: (KeyboardNavigationAction) -> Void
        private var monitor: Any?

        init(onAction: @escaping (KeyboardNavigationAction) -> Void) {
            self.onAction = onAction
        }

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      !Self.isEditingText(in: event.window),
                      let action = Self.action(for: event)
                else {
                    return event
                }

                onAction(action)
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private static func isEditingText(in window: NSWindow?) -> Bool {
            guard let textView = window?.firstResponder as? NSTextView else {
                return false
            }
            return textView.isEditable
        }

        private static func action(for event: NSEvent) -> KeyboardNavigationAction? {
            let ignoredModifiers: NSEvent.ModifierFlags = [.capsLock, .numericPad, .function]
            let activeModifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(ignoredModifiers)
            guard activeModifiers.isEmpty else {
                return nil
            }

            switch event.keyCode {
            case 123, 53:
                return .back
            case 124, 36, 76:
                return .open
            case 125:
                return .next
            case 126:
                return .previous
            default:
                break
            }

            return switch event.charactersIgnoringModifiers?.lowercased() {
            case "h":
                .back
            case "j":
                .next
            case "k":
                .previous
            case "l":
                .open
            default:
                nil
            }
        }
    }
}
