import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ProviderStoreTests {
    @MainActor
    static func main() {
        let suiteName = "ScreenScribeProviderStoreTests"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fputs("FAIL: Could not create an isolated defaults suite\n", stderr)
            exit(1)
        }
        defaults.removePersistentDomain(forName: suiteName)

        let fresh = ProviderStore(defaults: defaults)
        expect(fresh.activeProvider.kind == .granite, "Fresh installs should default to offline Granite")
        defaults.removePersistentDomain(forName: suiteName)
        checkMigration(defaults: defaults)
        checkCRUD(defaults: defaults)

        defaults.removePersistentDomain(forName: suiteName)
        checkRenaming(defaults: defaults)

        defaults.removePersistentDomain(forName: suiteName)
        checkLegacyPresets(defaults: defaults)
        print("ProviderStoreTests passed")
    }

    /// Settings saved by the Gemini-only release should become the first provider.
    @MainActor
    private static func checkMigration(defaults: UserDefaults) {
        defaults.set("legacy-key", forKey: "geminiAPIKey")
        defaults.set("gemini-3.5-flash", forKey: "geminiModel")

        let store = ProviderStore(defaults: defaults)
        expect(store.providers.count == 2, "Migration should retain Gemini and add Granite")

        let migrated = store.activeProvider
        expect(migrated.name == "Gemini", "The migrated provider should be named after the preset")
        expect(migrated.kind == .gemini, "The migrated provider should speak the Gemini protocol")
        expect(migrated.baseURL == Config.defaultGeminiBaseURL,
               "The migrated provider should use the default Gemini endpoint")
        expect(migrated.apiKey == "legacy-key", "The stored API key should be carried over")
        expect(migrated.model == "gemini-3.5-flash", "The stored model should be carried over as-is")

        expect(defaults.data(forKey: ProviderStore.providersKey) != nil,
               "The migrated provider should be persisted")
        expect(defaults.string(forKey: ProviderStore.activeProviderKey) == migrated.id.uuidString,
               "The active provider should be persisted")

        let reloaded = ProviderStore(defaults: defaults)
        expect(reloaded.providers.count == 2, "Migration should only run once")
        expect(reloaded.providers[0].id == migrated.id, "The reloaded provider should be the same one")

        print("  migration ok")
    }

    @MainActor
    private static func checkCRUD(defaults: UserDefaults) {
        let store = ProviderStore(defaults: defaults)
        let gemini = store.activeProvider

        let duplicate = store.add(preset: AIProviderPreset.all.first(where: { $0.id == "gemini" })!)
        expect(store.providers.count == 3, "Adding a provider should append it")
        expect(duplicate.name == "Gemini 2", "Duplicate names should be made unique")
        expect(store.activeProviderID == duplicate.id, "Added providers should become active")

        let openAI = store.add(preset: AIProviderPreset.all.first(where: { $0.id == "openai" })!)
        expect(openAI.kind == .openAICompatible, "The OpenAI preset should be an OpenAI-compatible provider")
        expect(openAI.baseURL == "https://api.openai.com/v1", "The preset should prefill the base URL")

        var edited = openAI
        edited.name = "Work"
        edited.model = "gpt-4o-mini"
        edited.apiKey = "sk-work"
        store.update(edited)
        expect(store.provider(id: openAI.id)?.name == "Work", "Updates should be stored")
        expect(store.provider(id: openAI.id)?.model == "gpt-4o-mini", "Model updates should be stored")
        expect(store.activeProvider.name == "Work", "The active provider should reflect updates")

        store.setActiveProvider(gemini.id)
        expect(store.activeProviderID == gemini.id, "The active provider should be switchable")

        store.setActiveProvider(UUID())
        expect(store.activeProviderID == gemini.id, "Unknown providers should not be activated")

        store.remove(id: duplicate.id)
        expect(store.providers.count == 3, "Providers should be removable")
        expect(store.activeProviderID == gemini.id, "Removing another provider should keep the selection")

        store.remove(id: gemini.id)
        expect(store.providers.count == 2, "Removing the active provider should fall back to the first")
        expect(store.activeProvider.kind == .granite, "Granite should become active")
        store.setActiveProvider(openAI.id)
        store.remove(id: store.providers.first(where: { $0.kind == .granite })!.id)

        store.remove(id: openAI.id)
        expect(store.providers.count == 1, "The last provider should never be removed")

        let reloaded = ProviderStore(defaults: defaults)
        expect(reloaded.providers.count == 2, "Reload should restore the built-in Granite provider")
        expect(reloaded.activeProvider.id == openAI.id, "The active selection should survive a reload")
        expect(reloaded.activeProvider.name == "Work", "Provider edits should survive a reload")
        expect(reloaded.activeProvider.apiKey == "sk-work", "Credentials should survive a reload")

        print("  CRUD ok")
    }

    @MainActor
    private static func checkRenaming(defaults: UserDefaults) {
        let store = ProviderStore(defaults: defaults)
        let custom = store.add(preset: .custom)
        expect(custom.name == "Custom Endpoint", "New custom endpoints should get the default name")
        expect(custom.isCustom, "Custom endpoints should remember their preset")

        store.rename(id: custom.id, to: "  My LLM  ")
        expect(store.provider(id: custom.id)?.name == "My LLM", "Names should be trimmed")

        store.rename(id: custom.id, to: "My LLM")
        expect(store.provider(id: custom.id)?.name == "My LLM",
               "Keeping the current name should not add a suffix")

        store.rename(id: custom.id, to: "Ollama")
        let renamed = store.provider(id: custom.id)
        expect(renamed?.isCustom == true, "A preset name should not turn an endpoint into that preset")
        expect(renamed?.isLocal == false, "A preset name should not change the API key rules")

        let second = store.add(preset: .custom)
        store.rename(id: second.id, to: "Ollama")
        expect(store.provider(id: second.id)?.name == "Ollama 2", "Renames should keep names unique")

        store.rename(id: second.id, to: "   ")
        expect(store.provider(id: second.id)?.name == "Custom Endpoint",
               "Empty names should fall back to the preset name")

        let port = store.add(preset: .custom)
        var pointed = port
        pointed.baseURL = "http://gpu-box:12345/v1"
        store.update(pointed)
        expect(store.provider(id: port.id)?.isCustom == true,
               "The base URL should not turn an endpoint into a preset")

        store.rename(id: UUID(), to: "Ghost")
        expect(!store.providers.contains(where: { $0.name == "Ghost" }), "Unknown providers should be ignored")

        let reloaded = ProviderStore(defaults: defaults)
        expect(reloaded.provider(id: custom.id)?.name == "Ollama", "Renames should survive a reload")
        expect(reloaded.provider(id: custom.id)?.isCustom == true, "Presets should survive a reload")

        print("  renaming ok")
    }

    /// Providers saved before presets were stored should keep the classification the picker showed.
    @MainActor
    private static func checkLegacyPresets(defaults: UserDefaults) {
        let legacy: [[String: String]] = [
            ["name": "Gemini", "kind": "gemini", "baseURL": Config.defaultGeminiBaseURL],
            ["name": "Gemini 2", "kind": "gemini", "baseURL": Config.defaultGeminiBaseURL],
            ["name": "Ollama", "kind": "openAICompatible", "baseURL": "http://gpu-box.lan/v1"],
            ["name": "Custom Endpoint", "kind": "openAICompatible", "baseURL": "http://localhost:1234/v1"],
        ]
        let json = legacy.map { fields in
            fields.merging(["id": UUID().uuidString, "apiKey": "", "model": "m"]) { current, _ in current }
        }
        defaults.set(try! JSONSerialization.data(withJSONObject: json), forKey: ProviderStore.providersKey)

        let store = ProviderStore(defaults: defaults)
        expect(store.providers.map(\.presetID) == ["gemini", "custom", "ollama", "custom", "granite"],
               "Legacy providers should count as a preset only while they keep its name")

        let stored = defaults.data(forKey: ProviderStore.providersKey)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        expect(stored.compactMap { $0["presetID"] as? String } == ["gemini", "custom", "ollama", "custom", "granite"],
               "Inferred presets should be written back on load")

        print("  legacy presets ok")
    }
}
