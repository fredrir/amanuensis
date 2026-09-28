import Foundation

/// Manages loading and accessing configuration values from Secrets.plist

struct ConfigurationManager {
    @MainActor
    static let shared = ConfigurationManager()
    
    private let secrets: [String: String]
    
    private init() {
        if let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path) as? [String: String] {
            self.secrets = dict
        } else {
            self.secrets = [:]
        }
    }
    
    func getValue(for key: String) -> String? {
        return secrets[key]
    }
    
    func value(for key: String) -> String? {
        return getValue(for: key)
    }
}

/// Central configuration access point for the application
enum Config {
    /// API root used for the Gemini provider unless it is overridden in the provider settings.
    static let defaultGeminiBaseURL = "https://generativelanguage.googleapis.com"

    /// The Gemini API key loaded from UserDefaults or Secrets.plist
    @MainActor
    static func geminiAPIKey(defaults: UserDefaults = .standard) -> String {
        if let key = defaults.string(forKey: "geminiAPIKey"), !key.isEmpty {
            return key
        }
        return ConfigurationManager.shared.value(for: "GEMINI_API_KEY") ?? ""
    }
    
}
