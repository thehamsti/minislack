import Foundation
import Testing
@testable import MiniSlack

struct KeyboardShortcutTests {
    @Test
    func defaultBindingsAreUniqueAndCoverEveryCommand() {
        var seen: [KeyBinding: KeyboardCommand] = [:]
        for command in KeyboardCommand.allCases {
            let binding = command.defaultBinding
            #expect(seen[binding] == nil, "\(command) collides with \(seen[binding]?.rawValue ?? "")")
            seen[binding] = command
        }
        #expect(seen.count == KeyboardCommand.allCases.count)
    }

    @Test
    func defaultsMatchEachSectionsRules() {
        let settings = KeyboardShortcutSettings()
        for command in KeyboardCommand.allCases {
            #expect(settings.reject(command.defaultBinding, for: command) == nil)
        }
    }

    @Test
    func unreadNotificationsCommandHasABindingAndMenuPlacement() {
        let settings = KeyboardShortcutSettings()

        #expect(KeyboardCommand.unreadNotifications.section == .commands)
        #expect(
            settings.binding(for: .unreadNotifications)
                == .character("n", [.command, .shift])
        )
        #expect(settings.binding(for: .unreadNotifications)?.displayString == "⇧⌘N")
    }

    @Test
    func assigningAnOverrideResolvesAndPersists() throws {
        var settings = KeyboardShortcutSettings()
        let binding = KeyBinding.character("i", [.command, .option])

        #expect(try settings.assign(binding, to: .unreadNotifications).get().isEmpty)
        #expect(settings.binding(for: .unreadNotifications) == binding)
        #expect(settings.isCustomized(.unreadNotifications))

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(KeyboardShortcutSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.binding(for: .unreadNotifications) == binding)
        #expect(decoded.binding(for: .quickSwitcher) == KeyboardCommand.quickSwitcher.defaultBinding)
    }

    @Test
    func assigningADefaultBindingBackStopsCountingAsCustomized() throws {
        var settings = KeyboardShortcutSettings()
        _ = settings.assign(.character("i", .command), to: .quickSwitcher)
        #expect(settings.isCustomized(.quickSwitcher))

        _ = settings.assign(KeyboardCommand.quickSwitcher.defaultBinding, to: .quickSwitcher)

        #expect(!settings.isCustomized(.quickSwitcher))
        #expect(!settings.isCustomized)
    }

    @Test
    func assigningATakenBindingClearsTheOtherCommand() throws {
        var settings = KeyboardShortcutSettings()
        let quickSwitcher = KeyboardCommand.quickSwitcher.defaultBinding

        let displaced = try settings.assign(quickSwitcher, to: .unreadNotifications).get()

        #expect(displaced == [.quickSwitcher])
        #expect(settings.binding(for: .unreadNotifications) == quickSwitcher)
        #expect(settings.binding(for: .quickSwitcher) == nil)
        #expect(settings.navigationAction(for: .character("j")) == .next)
    }

    @Test
    func menuCommandsRequireACommandLikeModifier() {
        let settings = KeyboardShortcutSettings()

        #expect(settings.reject(.character("n"), for: .unreadNotifications) == .missingModifier)
        #expect(
            settings.reject(.character("n", .shift), for: .unreadNotifications)
                == .missingModifier
        )
        #expect(settings.reject(.character("n", .control), for: .unreadNotifications) == nil)
        #expect(settings.reject(.character("n", .option), for: .unreadNotifications) == nil)
        #expect(settings.reject(.special(.downArrow, .command), for: .nextUnread) == nil)
    }

    @Test
    func navigationCommandsRejectModifiersAndSpecialKeys() {
        let settings = KeyboardShortcutSettings()

        #expect(settings.reject(.character("n", .command), for: .moveNext) == .unexpectedModifier)
        #expect(settings.reject(.special(.space), for: .moveNext) == .unsupportedKey)
        #expect(settings.reject(.character("n"), for: .moveNext) == nil)
    }

    @Test
    func rejectedAssignmentsLeaveSettingsUnchanged() {
        var settings = KeyboardShortcutSettings()
        let result = settings.assign(.character("z"), to: .unreadNotifications)

        #expect(result == .failure(.missingModifier))
        #expect(
            settings.binding(for: .unreadNotifications)
                == KeyboardCommand.unreadNotifications.defaultBinding
        )
        #expect(!settings.isCustomized)
    }

    @Test
    func navigationActionsFollowConfiguredKeys() throws {
        var settings = KeyboardShortcutSettings()

        #expect(settings.navigationAction(for: .character("j")) == .next)
        #expect(settings.navigationAction(for: .character("r")) == .markRead)
        #expect(settings.navigationAction(for: .character("z")) == nil)

        _ = try settings.assign(.character("z"), to: .moveNext).get()

        #expect(settings.navigationAction(for: .character("z")) == .next)
        #expect(settings.navigationAction(for: .character("j")) == nil)
    }

    @Test
    func clearingAndResettingACommand() {
        var settings = KeyboardShortcutSettings()

        settings.clear(.markSelectionRead)
        #expect(settings.binding(for: .markSelectionRead) == nil)
        #expect(settings.navigationAction(for: .character("r")) == nil)
        #expect(settings.isCustomized(.markSelectionRead))

        settings.resetToDefault(.markSelectionRead)
        #expect(settings.binding(for: .markSelectionRead) == .character("r"))
        #expect(!settings.isCustomized)
    }

    @Test
    func restoringDefaultsDropsEveryOverride() {
        var settings = KeyboardShortcutSettings()
        _ = settings.assign(.character("i", .command), to: .quickSwitcher)
        settings.clear(.moveNext)

        settings.resetAllToDefaults()

        #expect(settings == KeyboardShortcutSettings())
        #expect(!settings.isCustomized)
        #expect(settings.binding(for: .quickSwitcher) == .character("k", .command))
        #expect(settings.navigationAction(for: .character("j")) == .next)
    }

    @Test
    func displayStringsUseMacOSModifierOrder() {
        #expect(KeyBinding.character("n", [.command, .shift]).displayString == "⇧⌘N")
        #expect(
            KeyBinding.character("a", [.control, .option, .shift, .command]).displayString
                == "⌃⌥⇧⌘A"
        )
        #expect(KeyBinding.special(.downArrow, .control).displayString == "⌃↓")
        #expect(KeyBinding.special(.return).displayString == "↩")
    }

    @Test
    func keyInputRoundTripsThroughItsRawValue() throws {
        let inputs: [KeyInput] = [.character("j"), .special(.pageDown), .special(.escape)]
        for input in inputs {
            let restored = try #require(KeyInput(rawValue: input.rawValue))
            #expect(restored == input)
        }

        #expect(KeyInput(rawValue: "char:") == nil)
        #expect(KeyInput(rawValue: "char:ab") == nil)
        #expect(KeyInput(rawValue: "key:nope") == nil)
        #expect(KeyInput(rawValue: "j") == nil)
    }

    @Test
    func charactersNormalizeSoShiftStaysAModifier() {
        #expect(KeyInput.normalizedCharacter("J") == .character("j"))
        #expect(KeyBinding.character("N", .command) == .character("n", .command))
        #expect(KeyInput.normalizedCharacter(" ") == nil)
        #expect(KeyInput.normalizedCharacter("\n") == nil)
    }

    @Test
    func unknownStoredCommandsAndKeysAreDropped() throws {
        let json = """
        {
          "overrides": {
            "unreadNotifications": {"key": "char:i", "modifiers": 9},
            "someRemovedCommand": {"key": "char:x", "modifiers": 8}
          },
          "clearedCommands": ["moveNext", "anotherRemovedCommand"]
        }
        """
        let settings = try JSONDecoder().decode(
            KeyboardShortcutSettings.self,
            from: Data(json.utf8)
        )

        #expect(settings.binding(for: .unreadNotifications) == .character("i", [.command, .control]))
        #expect(settings.binding(for: .moveNext) == nil)
        #expect(settings.binding(for: .goBack) == .character("h"))
    }
}

@MainActor
struct KeyboardShortcutStoreTests {
    @Test
    func storePersistsAndReloadsBindings() throws {
        let defaults = try #require(UserDefaults(suiteName: "mini-slack-shortcut-tests"))
        defaults.removeObject(forKey: KeyboardShortcutSettings.defaultsKey)
        defer { defaults.removeObject(forKey: KeyboardShortcutSettings.defaultsKey) }

        let store = KeyboardShortcutStore(defaults: defaults)
        #expect(store.displayString(for: .unreadNotifications) == "⇧⌘N")

        let result = store.assign(.character("i", [.command, .option]), to: .unreadNotifications)
        #expect(try result.get().isEmpty)
        #expect(store.displayString(for: .unreadNotifications) == "⌥⌘I")

        let reloaded = KeyboardShortcutStore(defaults: defaults)
        #expect(reloaded.binding(for: .unreadNotifications) == .character("i", [.command, .option]))
        #expect(reloaded.isCustomized(.unreadNotifications))

        reloaded.resetAllToDefaults()
        #expect(KeyboardShortcutStore(defaults: defaults).displayString(for: .unreadNotifications) == "⇧⌘N")
    }

    @Test
    func rejectedAssignmentsDoNotPersist() throws {
        let defaults = try #require(UserDefaults(suiteName: "mini-slack-shortcut-rejection-tests"))
        defaults.removeObject(forKey: KeyboardShortcutSettings.defaultsKey)
        defer { defaults.removeObject(forKey: KeyboardShortcutSettings.defaultsKey) }

        let store = KeyboardShortcutStore(defaults: defaults)
        #expect(store.assign(.character("i"), to: .quickSwitcher) == .failure(.missingModifier))
        #expect(store.displayString(for: .quickSwitcher) == "⌘K")
        #expect(defaults.data(forKey: KeyboardShortcutSettings.defaultsKey) == nil)
    }

    @Test
    func togglingTheNotificationBellFlipsWindowState() {
        let windowState = WindowState()

        #expect(!windowState.isUnreadNotificationsPresented)

        windowState.toggleUnreadNotifications()
        #expect(windowState.isUnreadNotificationsPresented)

        windowState.toggleUnreadNotifications()
        #expect(!windowState.isUnreadNotificationsPresented)

        windowState.toggleUnreadNotifications()
        windowState.dismissUnreadNotifications()
        #expect(!windowState.isUnreadNotificationsPresented)
    }
}
