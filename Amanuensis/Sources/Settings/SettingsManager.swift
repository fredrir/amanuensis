import Carbon
import Foundation
import SwiftUI

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var textShortcut: ShortcutMonitor.KeyboardShortcut? {
        didSet {
            ShortcutPreferences.save(textShortcut, forKey: "textShortcut", defaults: .standard)
            ShortcutMonitor.shared.setShortcut(textShortcut, for: .visionOCR)
        }
    }

    @Published var latexShortcut: ShortcutMonitor.KeyboardShortcut? {
        didSet {
            ShortcutPreferences.save(latexShortcut, forKey: "latexShortcut", defaults: .standard)
            ShortcutMonitor.shared.setShortcut(latexShortcut, for: .latex)
        }
    }

    @Published var markdownShortcut: ShortcutMonitor.KeyboardShortcut? {
        didSet {
            ShortcutPreferences.save(markdownShortcut, forKey: "markdownShortcut", defaults: .standard)
            ShortcutMonitor.shared.setShortcut(markdownShortcut, for: .markdown)
        }
    }

    private init() {

        textShortcut = ShortcutPreferences.load(forKey: "textShortcut", defaultKeyCode: kVK_ANSI_T)
        latexShortcut = ShortcutPreferences.load(
            forKey: "latexShortcut", defaultKeyCode: kVK_ANSI_L, legacyKey: "defaultPromptShortcut")
        markdownShortcut = ShortcutPreferences.load(forKey: "markdownShortcut")

        ShortcutMonitor.shared.setShortcut(textShortcut, for: .visionOCR)
        ShortcutMonitor.shared.setShortcut(latexShortcut, for: .latex)
        ShortcutMonitor.shared.setShortcut(markdownShortcut, for: .markdown)
    }

}

// A stored JSON null means deliberately unassigned; a missing key means first launch.
struct ShortcutPreferences {
    static func save(
        _ shortcut: ShortcutMonitor.KeyboardShortcut?, forKey key: String, defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(
        forKey key: String, defaultKeyCode: Int? = nil, legacyKey: String? = nil,
        defaults: UserDefaults = .standard
    ) -> ShortcutMonitor.KeyboardShortcut? {
        if let data = defaults.data(forKey: key) {
            do {
                return try JSONDecoder().decode(ShortcutMonitor.KeyboardShortcut?.self, from: data)
            } catch {
                // Recover malformed preferences with the default below.
            }
        }
        if defaults.object(forKey: key) == nil, let legacyKey,
            let data = defaults.data(forKey: legacyKey),
            let legacy = try? JSONDecoder().decode(
                ShortcutMonitor.KeyboardShortcut?.self, from: data)
        {
            save(legacy, forKey: key, defaults: defaults)
            defaults.removeObject(forKey: legacyKey)
            return legacy
        }
        guard let defaultKeyCode else { return nil }
        return ShortcutMonitor.KeyboardShortcut(keyCode: defaultKeyCode, modifiers: .command)
    }
}
