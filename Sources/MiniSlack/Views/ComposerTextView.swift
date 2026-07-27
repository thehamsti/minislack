import AppKit
import SwiftUI

struct ComposerTextView: NSViewRepresentable {
    @Binding var draft: ComposerDraft
    @Binding var selection: NSRange
    @Binding var height: CGFloat
    let suggestionsVisible: Bool
    let accessibilityLabel: String
    let pasteAttachments: (([ComposerPasteboardAttachment]) -> Void)?
    let moveSuggestion: (Int) -> Void
    let acceptSuggestion: () -> Void
    let dismissSuggestions: () -> Void
    let format: (ComposerFormatting) -> Void
    let send: () -> Void
    let onEscape: (() -> Void)?
    let focusChanged: ((Bool) -> Void)?

    init(
        draft: Binding<ComposerDraft>,
        selection: Binding<NSRange>,
        height: Binding<CGFloat>,
        suggestionsVisible: Bool,
        accessibilityLabel: String,
        pasteAttachments: (([ComposerPasteboardAttachment]) -> Void)? = nil,
        moveSuggestion: @escaping (Int) -> Void,
        acceptSuggestion: @escaping () -> Void,
        dismissSuggestions: @escaping () -> Void,
        format: @escaping (ComposerFormatting) -> Void,
        send: @escaping () -> Void,
        onEscape: (() -> Void)? = nil,
        focusChanged: ((Bool) -> Void)? = nil
    ) {
        _draft = draft
        _selection = selection
        _height = height
        self.suggestionsVisible = suggestionsVisible
        self.accessibilityLabel = accessibilityLabel
        self.pasteAttachments = pasteAttachments
        self.moveSuggestion = moveSuggestion
        self.acceptSuggestion = acceptSuggestion
        self.dismissSuggestions = dismissSuggestions
        self.format = format
        self.send = send
        self.onEscape = onEscape
        self.focusChanged = focusChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.isRichText = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 24)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel(accessibilityLabel)
        scrollView.documentView = textView
        context.coordinator.configure(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else {
            return
        }
        context.coordinator.parent = self
        context.coordinator.configure(textView)
        context.coordinator.isApplyingUpdate = true
        if textView.string != draft.text {
            textView.string = draft.text
        }
        let textLength = (textView.string as NSString).length
        let clampedSelection = NSRange(
            location: min(selection.location, textLength),
            length: min(selection.length, max(0, textLength - selection.location))
        )
        if textView.selectedRange() != clampedSelection, !textView.hasMarkedText() {
            textView.setSelectedRange(clampedSelection)
        }
        context.coordinator.applyTagAttributes(to: textView)
        context.coordinator.isApplyingUpdate = false
        context.coordinator.updateHeight(for: textView, deferred: true)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private struct PendingEdit {
            let range: NSRange
            let originalLength: Int
        }

        var parent: ComposerTextView
        var isApplyingUpdate = false
        private var pendingEdit: PendingEdit?

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        fileprivate func configure(_ textView: ComposerNSTextView) {
            textView.suggestionsVisible = parent.suggestionsVisible
            textView.pasteAttachments = parent.pasteAttachments
            textView.moveSuggestion = parent.moveSuggestion
            textView.acceptSuggestion = parent.acceptSuggestion
            textView.dismissSuggestions = parent.dismissSuggestions
            textView.format = parent.format
            textView.send = parent.send
            textView.onEscape = parent.onEscape
            textView.setAccessibilityLabel(parent.accessibilityLabel)
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard !isApplyingUpdate else {
                return true
            }
            pendingEdit = PendingEdit(
                range: affectedCharRange,
                originalLength: (textView.string as NSString).length
            )
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingUpdate,
                  let textView = notification.object as? ComposerNSTextView
            else {
                return
            }
            var draft = parent.draft
            if let pendingEdit {
                let replacementLength =
                    (textView.string as NSString).length
                    - pendingEdit.originalLength
                    + pendingEdit.range.length
                draft.applyTextChange(
                    textView.string,
                    replacing: pendingEdit.range,
                    replacementLength: replacementLength
                )
            } else {
                draft = ComposerDraft(text: textView.string)
            }
            pendingEdit = nil
            parent.draft = draft
            parent.selection = textView.selectedRange()
            applyTagAttributes(to: textView)
            updateHeight(for: textView, deferred: false)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingUpdate,
                  let textView = notification.object as? ComposerNSTextView
            else {
                return
            }
            parent.selection = textView.selectedRange()
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.focusChanged?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.focusChanged?(false)
        }

        func applyTagAttributes(to textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else {
                return
            }
            let fullRange = NSRange(
                location: 0,
                length: (textView.string as NSString).length
            )
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
            for tag in parent.draft.tags
            where NSMaxRange(tag.range) <= fullRange.length
            {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: NSColor.controlAccentColor.withAlphaComponent(0.16),
                    forCharacterRange: tag.range
                )
                layoutManager.addTemporaryAttribute(
                    .foregroundColor,
                    value: NSColor.controlAccentColor,
                    forCharacterRange: tag.range
                )
            }
        }

        func updateHeight(for textView: NSTextView, deferred: Bool) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer
            else {
                return
            }
            layoutManager.ensureLayout(for: textContainer)
            let contentHeight = ceil(
                layoutManager.usedRect(for: textContainer).height
                    + textView.textContainerInset.height * 2
            )
            let nextHeight = min(max(contentHeight, 24), 96)
            textView.enclosingScrollView?.hasVerticalScroller = contentHeight > 96
            guard abs(parent.height - nextHeight) > 0.5 else {
                return
            }
            if deferred {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.height = nextHeight
                }
            } else {
                parent.height = nextHeight
            }
        }
    }
}

@MainActor
fileprivate final class ComposerNSTextView: NSTextView {
    var suggestionsVisible = false
    var pasteAttachments: (([ComposerPasteboardAttachment]) -> Void)?
    var moveSuggestion: ((Int) -> Void)?
    var acceptSuggestion: (() -> Void)?
    var dismissSuggestions: (() -> Void)?
    var format: ((ComposerFormatting) -> Void)?
    var send: (() -> Void)?
    var onEscape: (() -> Void)?

    override func paste(_ sender: Any?) {
        guard let pasteAttachments else {
            super.paste(sender)
            return
        }
        let attachments = ComposerPasteboardReader.attachments(
            from: .general
        )
        guard !attachments.isEmpty else {
            super.paste(sender)
            return
        }
        pasteAttachments(attachments)
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        let textNavigationModifiers = event.modifierFlags.intersection([
            .command, .control, .option, .shift,
        ])
        if event.modifierFlags.intersection([.command, .control, .option]) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b":
                format?(.bold)
                return
            case "i":
                format?(.italic)
                return
            default:
                break
            }
        }
        switch event.keyCode {
        case 125 where suggestionsVisible && textNavigationModifiers.isEmpty:
            moveSuggestion?(1)
        case 126 where suggestionsVisible && textNavigationModifiers.isEmpty:
            moveSuggestion?(-1)
        case 36, 76:
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)
            } else if suggestionsVisible {
                acceptSuggestion?()
            } else {
                send?()
            }
        case 48 where suggestionsVisible && textNavigationModifiers.isEmpty:
            acceptSuggestion?()
        case 53 where textNavigationModifiers.isEmpty:
            if suggestionsVisible {
                dismissSuggestions?()
            } else {
                onEscape?()
            }
        default:
            super.keyDown(with: event)
        }
    }
}
