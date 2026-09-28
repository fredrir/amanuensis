import Foundation

/// The wire protocol a provider speaks.
enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case granite
    case codex
    case geminiSubscription
    case anthropic
    case gemini
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .granite: return "Docling Granite"
        case .codex: return "ChatGPT / Codex"
        case .geminiSubscription: return "Gemini Subscription"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    /// Shown in the settings editor to explain what the selected type can talk to.
    var summary: String {
        switch self {
        case .granite: return "Local document extraction on Apple Silicon."
        case .codex: return "Sign in with your ChatGPT account."
        case .geminiSubscription: return "Sign in with your Google AI subscription account."
        case .anthropic: return "Claude with your Anthropic API key."
        case .gemini:
            return "Google's generateContent API."
        case .openAICompatible:
            return "Any endpoint exposing /chat/completions, such as OpenAI, OpenRouter, Groq, Ollama or LM Studio."
        }
    }

    /// Endpoint used when a provider of this kind has no base URL yet.
    var defaultBaseURL: String {
        switch self {
        case .granite, .codex, .geminiSubscription: return ""
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return Config.defaultGeminiBaseURL
        case .openAICompatible: return ""
        }
    }

    /// Local OpenAI-compatible servers usually accept requests without credentials.
    var requiresAPIKey: Bool {
        switch self {
        case .gemini, .anthropic: return true
        case .granite, .codex, .geminiSubscription, .openAICompatible: return false
        }
    }
}

/// A saved provider: protocol, endpoint, credentials and the model requests use.
struct AIProviderConfiguration: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var kind: AIProviderKind
    var baseURL: String
    var apiKey: String
    var model: String
    /// The preset this provider was created from, so renaming or re-pointing it never reclassifies it.
    var presetID: String

    init(
        id: UUID = UUID(),
        name: String,
        kind: AIProviderKind,
        baseURL: String,
        apiKey: String = "",
        model: String = "",
        presetID: String = AIProviderPreset.custom.id
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.presetID = presetID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(AIProviderKind.self, forKey: .kind)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        model = try container.decode(String.self, forKey: .model)
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID)
            ?? Self.legacyPresetID(name: name, kind: kind)
    }

    /// Providers saved before `presetID` existed counted as a preset only while they kept its name.
    private static func legacyPresetID(name: String, kind: AIProviderKind) -> String {
        let preset = AIProviderPreset.all.first { $0.name == name && $0.kind == kind && $0 != .custom }
        return preset?.id ?? AIProviderPreset.custom.id
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.displayName : trimmed
    }

    var resolvedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var resolvedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Key requests should use: the configured value, or the bundled secret for Gemini.
    @MainActor
    var effectiveAPIKey: String {
        if !resolvedAPIKey.isEmpty {
            return resolvedAPIKey
        }
        guard kind == .gemini else { return "" }
        return Config.geminiAPIKey()
    }

    var resolvedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether requests to this provider are expected to carry an API key.
    /// Cloud services and custom endpoints require one; local servers do not.
    var requiresAPIKey: Bool {
        if kind == .granite || isSubscription { return false }
        if kind == .gemini || kind == .anthropic { return true }
        if let preset = matchingPreset, preset.isLocal { return false }
        return true
    }

}

/// Template used by the settings UI to create a new provider entry.
struct AIProviderPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: AIProviderKind
    let baseURL: String

    func makeProvider() -> AIProviderConfiguration {
        AIProviderConfiguration(name: name, kind: kind, baseURL: baseURL, model: kind == .granite ? "ibm-granite/granite-docling-258M-mlx" : "", presetID: id)
    }

    var websiteURL: URL? {
        switch id {
        case "anthropic":
            return URL(string: "https://platform.claude.com/settings/keys")
        case "gemini":
            return URL(string: "https://aistudio.google.com/app/apikey")
        case "openai":
            return URL(string: "https://platform.openai.com/api-keys")
        case "openrouter":
            return URL(string: "https://openrouter.ai/keys")
        case "groq":
            return URL(string: "https://console.groq.com/keys")
        default:
            return nil
        }
    }

    var isLocal: Bool {
        id == "granite" || id == "ollama" || id == "lmstudio"
    }

    static let granite = AIProviderPreset(id: "granite", name: "Docling Granite", kind: .granite, baseURL: "")

    static let all: [AIProviderPreset] = [
        granite,
        AIProviderPreset(id: "codex", name: "ChatGPT / Codex", kind: .codex, baseURL: ""),
        AIProviderPreset(id: "geminiSubscription", name: "Gemini Subscription", kind: .geminiSubscription, baseURL: ""),
        AIProviderPreset(id: "anthropic", name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com"),
        AIProviderPreset(
            id: "gemini",
            name: "Gemini",
            kind: .gemini,
            baseURL: Config.defaultGeminiBaseURL
        ),
        AIProviderPreset(
            id: "openai",
            name: "OpenAI",
            kind: .openAICompatible,
            baseURL: "https://api.openai.com/v1"
        ),
        AIProviderPreset(
            id: "openrouter",
            name: "OpenRouter",
            kind: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1"
        ),
        AIProviderPreset(
            id: "groq",
            name: "Groq",
            kind: .openAICompatible,
            baseURL: "https://api.groq.com/openai/v1"
        ),
        AIProviderPreset(
            id: "ollama",
            name: "Ollama",
            kind: .openAICompatible,
            baseURL: "http://localhost:11434/v1"
        ),
        AIProviderPreset(
            id: "lmstudio",
            name: "LM Studio",
            kind: .openAICompatible,
            baseURL: "http://localhost:1234/v1"
        ),
        custom,
    ]

    static let custom = AIProviderPreset(
        id: "custom",
        name: "Custom Endpoint",
        kind: .openAICompatible,
        baseURL: ""
    )
}

extension AIProviderConfiguration {
    var isSubscription: Bool { kind == .codex || kind == .geminiSubscription }

    var matchingPreset: AIProviderPreset? {
        AIProviderPreset.all.first { $0.id == presetID }
    }

    var isLocal: Bool {
        matchingPreset?.isLocal ?? false
    }

    var isCustom: Bool {
        presetID == AIProviderPreset.custom.id
    }
}

