import Foundation

@MainActor
final class ProviderStore: ObservableObject {
    static let shared = ProviderStore()

    static let providersKey = "aiProviders"
    static let activeProviderKey = "activeProviderID"

    private let defaults: UserDefaults

    @Published private(set) var providers: [AIProviderConfiguration] {
        didSet { persistProviders() }
    }

    @Published var activeProviderID: UUID {
        didSet { defaults.set(activeProviderID.uuidString, forKey: Self.activeProviderKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let loaded = Self.loadProviders(from: defaults)
        let hasLegacyProvider = defaults.string(forKey: "geminiAPIKey") != nil || defaults.string(forKey: "geminiModel") != nil
        var resolved = loaded.isEmpty
            ? (hasLegacyProvider ? [Self.migratedProvider(from: defaults)] : [AIProviderPreset.granite.makeProvider()])
            : loaded
        if !resolved.contains(where: { $0.kind == .granite }) {
            resolved.append(AIProviderPreset.granite.makeProvider())
        }
        providers = resolved

        let storedID = defaults.string(forKey: Self.activeProviderKey).flatMap(
            UUID.init(uuidString:))
        activeProviderID = resolved.first(where: { $0.id == storedID })?.id ?? resolved[0].id

        persistProviders()
        if loaded.isEmpty {
            defaults.set(activeProviderID.uuidString, forKey: Self.activeProviderKey)
        }
    }

    var activeProvider: AIProviderConfiguration {
        providers.first(where: { $0.id == activeProviderID }) ?? providers[0]
    }

    func provider(id: UUID) -> AIProviderConfiguration? {
        providers.first(where: { $0.id == id })
    }

    @discardableResult
    func add(_ provider: AIProviderConfiguration, activate: Bool = true) -> AIProviderConfiguration
    {
        var provider = provider
        provider.name = uniquifiedName(provider.name)
        providers.append(provider)
        if activate {
            activeProviderID = provider.id
        }
        return provider
    }

    @discardableResult
    func add(preset: AIProviderPreset, activate: Bool = true) -> AIProviderConfiguration {
        add(preset.makeProvider(), activate: activate)
    }

    func update(_ provider: AIProviderConfiguration) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
    }

    func rename(id: UUID, to name: String) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = providers[index].matchingPreset?.name ?? providers[index].kind.displayName
        let resolved = uniquifiedName(trimmed.isEmpty ? fallback : trimmed, excluding: id)
        guard resolved != providers[index].name else { return }
        providers[index].name = resolved
    }

    func remove(id: UUID) {
        guard providers.count > 1,
            let index = providers.firstIndex(where: { $0.id == id })
        else {
            return
        }

        providers.remove(at: index)
        if activeProviderID == id {
            activeProviderID = providers[0].id
        }
    }

    func setActiveProvider(_ id: UUID) {
        guard providers.contains(where: { $0.id == id }) else { return }
        activeProviderID = id
    }

    private func persistProviders() {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        defaults.set(data, forKey: Self.providersKey)
    }

    private func uniquifiedName(_ name: String, excluding excludedID: UUID? = nil) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? AIProviderKind.openAICompatible.displayName : trimmed
        let others = providers.filter { $0.id != excludedID }
        guard others.contains(where: { $0.displayName == base }) else {
            return base
        }

        var suffix = 2
        while others.contains(where: { $0.displayName == "\(base) \(suffix)" }) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private static func loadProviders(from defaults: UserDefaults) -> [AIProviderConfiguration] {
        guard let data = defaults.data(forKey: providersKey),
            let decoded = try? JSONDecoder().decode([AIProviderConfiguration].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private static func migratedProvider(from defaults: UserDefaults) -> AIProviderConfiguration {
        AIProviderConfiguration(
            name: "Gemini",
            kind: .gemini,
            baseURL: Config.defaultGeminiBaseURL,
            apiKey: defaults.string(forKey: "geminiAPIKey") ?? "",
            model: defaults.string(forKey: "geminiModel") ?? "",
            presetID: "gemini"
        )
    }
}
