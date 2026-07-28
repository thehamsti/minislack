import AppKit
import SwiftUI

extension KeyModifiers {
    init(eventFlags: NSEvent.ModifierFlags) {
        var modifiers = KeyModifiers()
        if eventFlags.contains(.command) {
            modifiers.insert(.command)
        }
        if eventFlags.contains(.control) {
            modifiers.insert(.control)
        }
        if eventFlags.contains(.option) {
            modifiers.insert(.option)
        }
        if eventFlags.contains(.shift) {
            modifiers.insert(.shift)
        }
        self = modifiers
    }

    var eventModifiers: EventModifiers {
        var modifiers = EventModifiers()
        if contains(.command) {
            modifiers.insert(.command)
        }
        if contains(.control) {
            modifiers.insert(.control)
        }
        if contains(.option) {
            modifiers.insert(.option)
        }
        if contains(.shift) {
            modifiers.insert(.shift)
        }
        return modifiers
    }
}

extension KeyInput.SpecialKey {
    /// AppKit key codes for the keys a recorder can capture.
    private static let keyCodes: [UInt16: KeyInput.SpecialKey] = [
        123: .leftArrow,
        124: .rightArrow,
        125: .downArrow,
        126: .upArrow,
        49: .space,
        48: .tab,
        36: .return,
        76: .return,
        53: .escape,
        51: .delete,
        115: .home,
        119: .end,
        116: .pageUp,
        121: .pageDown,
    ]

    init?(keyCode: UInt16) {
        guard let key = Self.keyCodes[keyCode] else {
            return nil
        }
        self = key
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        case .space: .space
        case .tab: .tab
        case .return: .return
        case .escape: .escape
        case .delete: .delete
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        }
    }
}

extension KeyInput {
    /// Special keys win over their typed characters so Space and Return are not
    /// stored as literal characters.
    init?(event: NSEvent) {
        if let special = SpecialKey(keyCode: event.keyCode) {
            self = .special(special)
            return
        }
        guard let character = event.charactersIgnoringModifiers?.first,
              let normalized = Self.normalizedCharacter(character)
        else {
            return nil
        }
        self = normalized
    }

    var keyEquivalent: KeyEquivalent? {
        switch self {
        case let .character(character):
            KeyEquivalent(character)
        case let .special(key):
            key.keyEquivalent
        }
    }
}

extension KeyBinding {
    init?(event: NSEvent) {
        guard let key = KeyInput(event: event) else {
            return nil
        }
        self.init(
            key: key,
            modifiers: KeyModifiers(eventFlags: event.modifierFlags)
        )
    }

    var keyboardShortcut: KeyboardShortcut? {
        guard let keyEquivalent = key.keyEquivalent else {
            return nil
        }
        return KeyboardShortcut(keyEquivalent, modifiers: modifiers.eventModifiers)
    }
}

extension View {
    /// Applies a command's configured shortcut, leaving the control unbound when
    /// the user cleared it.
    @ViewBuilder
    func keyboardShortcut(_ binding: KeyBinding?) -> some View {
        if let shortcut = binding?.keyboardShortcut {
            keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}
