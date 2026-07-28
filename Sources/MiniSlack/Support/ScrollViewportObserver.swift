import AppKit
import SwiftUI

enum ScrollViewportPosition {
    static func isAtBottom(
        documentBounds: CGRect,
        visibleRect: CGRect,
        isFlipped: Bool,
        tolerance: CGFloat = 1
    ) -> Bool {
        guard documentBounds.height > visibleRect.height else {
            return true
        }
        if isFlipped {
            return visibleRect.maxY >= documentBounds.maxY - tolerance
        }
        return visibleRect.minY <= documentBounds.minY + tolerance
    }
}

struct ScrollViewportObserver: NSViewRepresentable {
    let bottomTolerance: CGFloat
    let onPositionChange: (Bool) -> Void

    init(
        bottomTolerance: CGFloat = 1,
        onPositionChange: @escaping (Bool) -> Void
    ) {
        self.bottomTolerance = bottomTolerance
        self.onPositionChange = onPositionChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            bottomTolerance: bottomTolerance,
            onPositionChange: onPositionChange
        )
    }

    func makeNSView(context: Context) -> ScrollViewportObserverView {
        let view = ScrollViewportObserverView()
        view.connect = context.coordinator.connect
        return view
    }

    func updateNSView(_ view: ScrollViewportObserverView, context: Context) {
        context.coordinator.bottomTolerance = bottomTolerance
        context.coordinator.onPositionChange = onPositionChange
        view.connect = context.coordinator.connect
        view.resolveScrollView()
    }

    static func dismantleNSView(
        _ view: ScrollViewportObserverView,
        coordinator: Coordinator
    ) {
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator: NSObject {
        var bottomTolerance: CGFloat
        var onPositionChange: (Bool) -> Void
        private weak var scrollView: NSScrollView?

        init(
            bottomTolerance: CGFloat,
            onPositionChange: @escaping (Bool) -> Void
        ) {
            self.bottomTolerance = bottomTolerance
            self.onPositionChange = onPositionChange
        }

        func connect(_ scrollView: NSScrollView?) {
            guard self.scrollView !== scrollView else {
                reportPosition()
                return
            }
            disconnect()
            guard let scrollView else {
                return
            }
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            reportPosition()
        }

        func disconnect() {
            NotificationCenter.default.removeObserver(self)
            scrollView = nil
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            reportPosition()
        }

        private func reportPosition() {
            guard let scrollView,
                  let documentView = scrollView.documentView
            else {
                return
            }
            onPositionChange(
                ScrollViewportPosition.isAtBottom(
                    documentBounds: documentView.bounds,
                    visibleRect: scrollView.contentView.documentVisibleRect,
                    isFlipped: documentView.isFlipped,
                    tolerance: bottomTolerance
                )
            )
        }
    }
}

final class ScrollViewportObserverView: NSView {
    var connect: ((NSScrollView?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveScrollView()
    }

    func resolveScrollView() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            connect?(enclosingScrollView)
        }
    }
}
