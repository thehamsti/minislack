import Foundation

/// Modifier keys a binding can require, ordered for display as macOS does.
struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let control = KeyModifiers(rawValue: 1 << 0)
    static let option = KeyModifiers(rawValue: 1 << 1)
    static let shift = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)

    /// Shift alone only changes the typed character, so it cannot stand in for a
    /// command modifier.
    static let commandLike: KeyModifiers = [.control, .option, .command]

    var displayString: String {
        var symbols = ""
        if contains(.control) {
            symbols += "⌃"
        }
        if contains(.option) {
            symbols += "⌥"
        }
        if contains(.shift) {
            symbols += "⇧"
        }
        if contains(.command) {
            symbols += "⌘"
        }
        return symbols
    }
}

/// The non-modifier half of a binding.
enum KeyInput: Hashable, Sendable, RawRepresentable, Codable {
    case character(Character)
    case special(SpecialKey)

    enum SpecialKey: String, CaseIterable, Sendable {
        case upArrow
        case downArrow
        case leftArrow
        case rightArrow
        case space
        case tab
        case `return`
        case escape
        case delete
        case home
        case end
        case pageUp
        case pageDown

        var displayString: String {
            switch self {
            case .upArrow: "↑"
            case .downArrow: "↓"
            case .leftArrow: "←"
            case .rightArrow: "→"
            case .space: "␣"
            case .tab: "⇥"
            case .return: "↩"
            case .escape: "⎋"
            case .delete: "⌫"
            case .home: "↖"
            case .end: "↘"
            case .pageUp: "⇞"
            case .pageDown: "⇟"
            }
        }
    }

    var rawValue: String {
        switch self {
        case let .character(character):
            "char:\(character)"
        case let .special(key):
            "key:\(key.rawValue)"
        }
    }

    init?(rawValue: String) {
        if rawValue.hasPrefix("char:") {
            let value = String(rawValue.dropFirst("char:".count))
            guard value.count == 1, let character = value.first else {
                return nil
            }
            self = .character(character)
            return
        }
        if rawValue.hasPrefix("key:"),
           let key = SpecialKey(rawValue: String(rawValue.dropFirst("key:".count)))
        {
            self = .special(key)
            return
        }
        return nil
    }

    /// Characters are stored lowercase so ⇧ is recorded as a modifier rather
    /// than folded into the key.
    static func normalizedCharacter(_ character: Character) -> KeyInput? {
        let lowered = character.lowercased()
        guard lowered.count == 1,
              let normalized = lowered.first,
              !normalized.isWhitespace,
              !normalized.isNewline
        else {
            return nil
        }
        return .character(normalized)
    }

    var character: Character? {
        switch self {
        case let .character(character):
            character
        case .special:
            nil
        }
    }

    var displayString: String {
        switch self {
        case let .character(character):
            String(character).uppercased()
        case let .special(key):
            key.displayString
        }
    }
}

struct KeyBinding: Codable, Hashable, Sendable {
    var key: KeyInput
    var modifiers: KeyModifiers

    init(key: KeyInput, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    static func character(_ character: Character, _ modifiers: KeyModifiers = []) -> KeyBinding {
        KeyBinding(
            key: .normalizedCharacter(character) ?? .character(character),
            modifiers: modifiers
        )
    }

    static func special(
        _ key: KeyInput.SpecialKey,
        _ modifiers: KeyModifiers = []
    ) -> KeyBinding {
        KeyBinding(key: .special(key), modifiers: modifiers)
    }

    var displayString: String {
        modifiers.displayString + key.displayString
    }
}

/// Where a command is dispatched, which decides what a valid binding looks like.
enum KeyboardCommandSection: String, CaseIterable, Identifiable, Sendable {
    /// Menu-bar commands; they need a command-like modifier.
    case commands
    /// Single-key list navigation; typed without modifiers while not editing text.
    case navigation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commands:
            "Commands"
        case .navigation:
            "Navigation"
        }
    }

    var detail: String {
        switch self {
        case .commands:
            "Menu commands. Each needs at least one of ⌘, ⌃, or ⌥."
        case .navigation:
            "Single keys, active while you are not typing. Arrow keys, Return, and Esc always work too."
        }
    }
}

enum KeyboardCommand: String, CaseIterable, Identifiable, Codable, Sendable {
    case quickSwitcher
    case findInConversation
    case searchWorkspace
    case unreadInbox
    case unreadNotifications
    case nextUnread
    case previousUnread
    case markConversationRead
    case moveNext
    case movePrevious
    case openSelection
    case goBack
    case markSelectionRead
    case focusComposer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickSwitcher:
            "Quick switcher"
        case .findInConversation:
            "Find in conversation"
        case .searchWorkspace:
            "Search workspace"
        case .unreadInbox:
            "Unread inbox"
        case .unreadNotifications:
            "Unread notifications bell"
        case .nextUnread:
            "Next unread conversation"
        case .previousUnread:
            "Previous unread conversation"
        case .markConversationRead:
            "Mark conversation read"
        case .moveNext:
            "Move selection down"
        case .movePrevious:
            "Move selection up"
        case .openSelection:
            "Open selection"
        case .goBack:
            "Go back"
        case .markSelectionRead:
            "Mark selection read"
        case .focusComposer:
            "Focus message input"
        }
    }

    var section: KeyboardCommandSection {
        switch self {
        case .quickSwitcher, .findInConversation, .searchWorkspace, .unreadInbox,
             .unreadNotifications, .nextUnread, .previousUnread, .markConversationRead:
            .commands
        case .moveNext, .movePrevious, .openSelection, .goBack, .markSelectionRead,
             .focusComposer:
            .navigation
        }
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .quickSwitcher:
            .character("k", .command)
        case .findInConversation:
            .character("f", .command)
        case .searchWorkspace:
            .character("f", [.command, .shift])
        case .unreadInbox:
            .character("u", [.command, .shift])
        case .unreadNotifications:
            .character("n", [.command, .shift])
        case .nextUnread:
            .special(.downArrow, .control)
        case .previousUnread:
            .special(.upArrow, .control)
        case .markConversationRead:
            .character("r", [.command, .shift])
        case .moveNext:
            .character("j")
        case .movePrevious:
            .character("k")
        case .openSelection:
            .character("l")
        case .goBack:
            .character("h")
        case .markSelectionRead:
            .character("r")
        case .focusComposer:
            .character("/")
        }
    }

    /// Navigation action this command drives, when it drives one.
    var navigationAction: KeyboardNavigationAction? {
        switch self {
        case .moveNext:
            .next
        case .movePrevious:
            .previous
        case .openSelection:
            .open
        case .goBack:
            .back
        case .markSelectionRead:
            .markRead
        case .focusComposer:
            .focusComposer
        default:
            nil
        }
    }
}

enum KeyBindingRejection: Error, Equatable, Sendable {
    case missingModifier
    case unexpectedModifier
    case unsupportedKey

    var message: String {
        switch self {
        case .missingModifier:
            "Add ⌘, ⌃, or ⌥ to this shortcut."
        case .unexpectedModifier:
            "List navigation keys are typed without modifiers."
        case .unsupportedKey:
            "That key can’t be used for this shortcut."
        }
    }
}

/// Persisted keyboard bindings: every command resolves to its default until an
/// override or an explicit clear is stored.
struct KeyboardShortcutSettings: Codable, Equatable, Sendable {
    static let defaultsKey = "keyboardShortcuts"

    private var overrides: [KeyboardCommand: KeyBinding]
    private var clearedCommands: Set<KeyboardCommand>

    init(
        overrides: [KeyboardCommand: KeyBinding] = [:],
        clearedCommands: Set<KeyboardCommand> = []
    ) {
        self.overrides = overrides
        self.clearedCommands = clearedCommands
    }

    var isCustomized: Bool {
        !overrides.isEmpty || !clearedCommands.isEmpty
    }

    func binding(for command: KeyboardCommand) -> KeyBinding? {
        if clearedCommands.contains(command) {
            return nil
        }
        return overrides[command] ?? command.defaultBinding
    }

    func isCustomized(_ command: KeyboardCommand) -> Bool {
        overrides[command] != nil || clearedCommands.contains(command)
    }

    func reject(_ binding: KeyBinding, for command: KeyboardCommand) -> KeyBindingRejection? {
        switch command.section {
        case .commands:
            if binding.modifiers.isDisjoint(with: .commandLike) {
                return .missingModifier
            }
            return nil
        case .navigation:
            if !binding.modifiers.isEmpty {
                return .unexpectedModifier
            }
            if binding.key.character == nil {
                return .unsupportedKey
            }
            return nil
        }
    }

    /// Commands already using this binding, excluding `command` itself.
    func conflicts(with binding: KeyBinding, excluding command: KeyboardCommand) -> [KeyboardCommand] {
        KeyboardCommand.allCases.filter {
            $0 != command && self.binding(for: $0) == binding
        }
    }

    /// Assigns a binding, clearing any command that already used it so two
    /// commands never answer the same keystroke.
    @discardableResult
    mutating func assign(
        _ binding: KeyBinding,
        to command: KeyboardCommand
    ) -> Result<[KeyboardCommand], KeyBindingRejection> {
        if let rejection = reject(binding, for: command) {
            return .failure(rejection)
        }
        let displaced = conflicts(with: binding, excluding: command)
        for other in displaced {
            clear(other)
        }
        clearedCommands.remove(command)
        if binding == command.defaultBinding {
            overrides.removeValue(forKey: command)
        } else {
            overrides[command] = binding
        }
        return .success(displaced)
    }

    mutating func clear(_ command: KeyboardCommand) {
        overrides.removeValue(forKey: command)
        clearedCommands.insert(command)
    }

    mutating func resetToDefault(_ command: KeyboardCommand) {
        overrides.removeValue(forKey: command)
        clearedCommands.remove(command)
    }

    mutating func resetAllToDefaults() {
        self = KeyboardShortcutSettings()
    }

    /// Navigation action for a modifier-free keystroke, or nil when the key is
    /// unbound.
    func navigationAction(for key: KeyInput) -> KeyboardNavigationAction? {
        for command in KeyboardCommand.allCases {
            guard command.section == .navigation,
                  let action = command.navigationAction,
                  let binding = binding(for: command),
                  binding.modifiers.isEmpty,
                  binding.key == key
            else {
                continue
            }
            return action
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case overrides
        case clearedCommands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedOverrides = try container.decodeIfPresent(
            [String: KeyBinding].self,
            forKey: .overrides
        ) ?? [:]
        overrides = storedOverrides.reduce(into: [:]) { result, entry in
            if let command = KeyboardCommand(rawValue: entry.key) {
                result[command] = entry.value
            }
        }
        let storedCleared = try container.decodeIfPresent(
            [String].self,
            forKey: .clearedCommands
        ) ?? []
        clearedCommands = Set(storedCleared.compactMap(KeyboardCommand.init(rawValue:)))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }),
            forKey: .overrides
        )
        try container.encode(
            clearedCommands.map(\.rawValue).sorted(),
            forKey: .clearedCommands
        )
    }
}
