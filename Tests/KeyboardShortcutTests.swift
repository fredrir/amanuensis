import AppKit
import Carbon

@main
struct KeyboardShortcutTests {
    @MainActor
    static func main() {
        typealias Shortcut = ShortcutMonitor.KeyboardShortcut
        func expect(_ condition: Bool, _ message: String) {
            if !condition { fatalError(message) }
        }
        let suite = "Amanuensis.ShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Shortcut(keyCode: kVK_ANSI_T, modifiers: .command)
        expect(ShortcutPreferences.load(forKey: "textShortcut", defaultKeyCode: kVK_ANSI_T, defaults: defaults) == original,
               "First launch receives the default binding")
        ShortcutPreferences.save(nil, forKey: "textShortcut", defaults: defaults)
        let reopened = UserDefaults(suiteName: suite)!
        expect(ShortcutPreferences.load(forKey: "textShortcut", defaultKeyCode: kVK_ANSI_T, defaults: reopened) == nil,
               "Clearing survives loading settings again")

        let custom = Shortcut(keyCode: kVK_ANSI_LeftBracket, modifiers: [.command, .option])
        ShortcutPreferences.save(custom, forKey: "defaultPromptShortcut", defaults: defaults)
        expect(ShortcutPreferences.load(forKey: "latexShortcut", defaultKeyCode: kVK_ANSI_L, legacyKey: "defaultPromptShortcut", defaults: defaults) == custom,
               "Legacy default-prompt shortcuts are migrated to the LaTeX binding")
        expect(defaults.object(forKey: "defaultPromptShortcut") == nil, "Legacy key is removed after saving its replacement")
        expect(ShortcutPreferences.load(forKey: "latexShortcut", defaultKeyCode: kVK_ANSI_L, defaults: reopened) == custom,
               "Migration is persisted")
        ShortcutPreferences.save(nil, forKey: "latexShortcut", defaults: defaults)
        ShortcutPreferences.save(custom, forKey: "defaultPromptShortcut", defaults: defaults)
        expect(ShortcutPreferences.load(forKey: "latexShortcut", defaultKeyCode: kVK_ANSI_L, legacyKey: "defaultPromptShortcut", defaults: defaults) == nil,
               "Legacy settings cannot resurrect a cleared binding")
        expect(ShortcutPreferences.load(forKey: "markdownShortcut", defaults: defaults) == nil,
               "Markdown starts unassigned")

        let noisy = Shortcut(keyCode: kVK_ANSI_A, modifiers: [.command, .capsLock, .numericPad, .function])
        expect(noisy == Shortcut(keyCode: kVK_ANSI_A, modifiers: .command), "Non-shortcut flags are normalized for conflict checks")
        let legacyData = Data("{\"keyCode\":0,\"modifiersRawValue\":1114112}".utf8)
        expect((try! JSONDecoder().decode(Shortcut.self, from: legacyData)).modifiers == .command,
               "Old shortcuts also normalize Caps Lock")
        expect(Shortcut(keyCode: kVK_ANSI_A, modifiers: []).validationError != nil, "Normal typing cannot become a global shortcut")
        expect(Shortcut(keyCode: kVK_F6, modifiers: []).validationError == nil, "Function keys work without modifiers")
        expect(Shortcut(keyCode: kVK_LeftArrow, modifiers: .control).keyEquivalentCharacter == "\u{F702}", "Menus use AppKit arrow-key equivalents")
        expect(Shortcut(keyCode: kVK_F6, modifiers: .command).description == "⌘F6", "Function keys have readable labels")
        expect((try? JSONDecoder().decode(Shortcut.self, from: Data("{\"keyCode\":-1,\"modifiersRawValue\":0}".utf8))) == nil,
               "Invalid stored key codes cannot reach Carbon")

        let sources = TISCreateInputSourceList([kTISPropertyInputSourceID: "com.apple.keylayout.Norwegian"] as CFDictionary, true).takeRetainedValue() as! [TISInputSource]
        expect(!sources.isEmpty, "Norwegian layout is available for testing")
        let letters = (0...127).map { Shortcut.character(for: $0, inputSource: sources[0]) }
        for letter in ["å", "æ", "ø"] {
            expect(letters.contains(letter), "Norwegian layout must resolve \(letter)")
            let code = letters.firstIndex(of: letter)!
            let binding = Shortcut(keyCode: code, modifiers: [.command, .shift])
            expect(try! JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(binding)) == binding,
                   "Norwegian physical key and modifiers survive persistence")
        }

        let monitor = ShortcutMonitor.shared
        let binding = Shortcut(keyCode: kVK_F19, modifiers: [.command, .control, .option, .shift])
        monitor.setShortcut(binding, for: .visionOCR)
        monitor.startMonitoring { _ in }
        expect(monitor.registrationErrors.isEmpty, "Test binding registers successfully")
        monitor.setShortcut(binding, for: .latex)
        expect(monitor.registrationErrors[.latex] != nil, "Duplicate Carbon registration is reported")
        monitor.setShortcut(nil, for: .visionOCR)
        expect(monitor.registrationErrors.isEmpty, "Clearing releases the binding for the other action")
        monitor.setShortcut(nil, for: .latex)
        monitor.setShortcut(binding, for: .markdown)
        expect(monitor.registrationErrors.isEmpty, "The Markdown shortcut registers once the binding is free")
        monitor.setShortcut(nil, for: .markdown)
        var probe: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x54455354, id: 88)
        expect(RegisterEventHotKey(UInt32(binding.keyCode), binding.carbonModifiers, id, GetApplicationEventTarget(), 0, &probe) == noErr,
               "Cleared shortcuts are unregistered globally")
        if let probe { UnregisterEventHotKey(probe) }
        monitor.setShortcut(binding, for: .visionOCR)
        monitor.suspendForRecording(true)
        probe = nil
        expect(RegisterEventHotKey(UInt32(binding.keyCode), binding.carbonModifiers, id, GetApplicationEventTarget(), 0, &probe) == noErr,
               "Recording releases existing hotkeys")
        if let probe { UnregisterEventHotKey(probe) }
        monitor.suspendForRecording(false)
        expect(monitor.registrationErrors.isEmpty, "Hotkeys resume after recording")
        monitor.stopMonitoring()
        print("KeyboardShortcutTests passed")
    }
}
