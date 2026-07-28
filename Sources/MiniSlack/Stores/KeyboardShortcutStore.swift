import Foundation
import Observation

/// Persists keyboard bindings in UserDefaults and publishes them to the menu
/// commands, the navigation monitor, and the settings editor.
@MainActor
@Observable
final class KeyboardShortcutStore {
    private(set) var settings: KeyboardShortcutSettings
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = Self.load(from: defaults)
    }

    func binding(for command: KeyboardCommand) -> KeyBinding? {
        settings.binding(for: command)
    }

    func displayString(for command: KeyboardCommand) -> String {
        settings.binding(for: command)?.displayString ?? "Not set"
    }

    func isCustomized(_ command: KeyboardCommand) -> Bool {
        settings.isCustomized(command)
    }

    /// Assigns a binding, returning the commands whose bindings it displaced.
    func assign(
        _ binding: KeyBinding,
        to command: KeyboardCommand
    ) -> Result<[KeyboardCommand], KeyBindingRejection> {
        var updated = settings
        let result = updated.assign(binding, to: command)
        if case .success = result {
            settings = updated
            persist()
        }
        return result
    }

    func clear(_ command: KeyboardCommand) {
        var updated = settings
        updated.clear(command)
        settings = updated
        persist()
    }

    func resetToDefault(_ command: KeyboardCommand) {
        var updated = settings
        updated.resetToDefault(command)
        settings = updated
        persist()
    }

    func resetAllToDefaults() {
        settings = KeyboardShortcutSettings()
        defaults.removeObject(forKey: KeyboardShortcutSettings.defaultsKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        defaults.set(data, forKey: KeyboardShortcutSettings.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> KeyboardShortcutSettings {
        guard let data = defaults.data(forKey: KeyboardShortcutSettings.defaultsKey),
              let settings = try? JSONDecoder().decode(
                  KeyboardShortcutSettings.self,
                  from: data
              )
        else {
            return KeyboardShortcutSettings()
        }
        return settings
    }
}
